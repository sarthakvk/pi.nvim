-- Client for the unix socket an opted-in Pi terminal session exposes via
-- /nvim-bridge enable. The wire format is newline-delimited JSON in both
-- directions: requests carry an id and are answered by a matching `response`,
-- and anything unmatched is an unsolicited event (activity, findings, tool
-- activity) handed to the caller's on_event handler.
--
-- libuv delivers reads off the main loop, where the Neovim API is unsafe, so
-- everything below re-enters through vim.schedule before touching state or
-- calling a handler.

---@class pi.Socket
---@field descriptor pi.Descriptor
---@field root string
---@field handlers pi.SocketHandlers
---@field pending table<string, fun(data: table?, err: string?)> In-flight requests by id.
---@field pipe uv.uv_pipe_t
---@field state pi.Descriptor? The peer's handshake reply; set once connected.
---@field buffer string? Partial tail of the last read.
---@field closed boolean?
local M = {}
M.__index = M

---@param message table
---@return string
local function encode(message)
	return vim.json.encode(message) .. "\n"
end

-- Connects and completes the handshake before calling back, so the caller never
-- receives a transport that has not yet proven it speaks this protocol for this
-- project.
---@param descriptor pi.Descriptor
---@param root string
---@param handlers pi.SocketHandlers?
---@param callback fun(transport: pi.Socket?, err: string?)
function M.connect(descriptor, root, handlers, callback)
	-- Cast rather than annotate: pipe, state, and buffer are filled in below.
	local self = setmetatable({ descriptor = descriptor, root = root, handlers = handlers or {}, pending = {} }, M) --[[@as pi.Socket]]
	-- new_pipe returns nil when the process is out of file descriptors.
	local pipe = vim.uv.new_pipe(false)
	if not pipe then
		return callback(nil, "cannot connect to Pi bridge: cannot allocate a pipe")
	end
	self.pipe = pipe
	self.pipe:connect(descriptor.socket_path, function(err)
		vim.schedule(function()
			if err then
				self:close()
				return callback(nil, "cannot connect to Pi bridge: " .. err)
			end
			self.pipe:read_start(function(read_err, data)
				vim.schedule(function()
					if read_err then
						return self:close(read_err)
					end
					if not data then
						return self:close()
					end
					-- Reads arrive in arbitrary chunks, so complete lines are cut out of a
					-- running buffer and any partial tail is kept for the next read.
					self.buffer = (self.buffer or "") .. data
					while true do
						local newline = self.buffer:find("\n", 1, true)
						if not newline then
							break
						end
						local line = self.buffer:sub(1, newline - 1)
						self.buffer = self.buffer:sub(newline + 1)
						if line:sub(-1) == "\r" then
							line = line:sub(1, -2)
						end
						local ok, message = pcall(vim.json.decode, line)
						if ok then
							self:receive(message)
						end
					end
				end)
			end)
			-- The handshake doubles as a guard: a socket that answers with a different
			-- protocol version or project root is not a bridge we may drive.
			self:request({ type = "hello", version = 1, root = root }, function(response, request_err)
				if request_err then
					self:close()
					return callback(nil, request_err)
				end
				if response.root ~= root or response.version ~= 1 then
					self:close()
					return callback(nil, "Pi bridge protocol or project root mismatch")
				end
				self.state = response
				callback(self)
			end)
		end)
	end)
end

---@param message table One decoded frame: a response, or an unsolicited event.
function M:receive(message)
	if message.type == "response" and message.id and self.pending[message.id] then
		local callback = self.pending[message.id]
		self.pending[message.id] = nil
		callback(message.data, message.error)
	elseif self.handlers.on_event then
		self.handlers.on_event(message)
	end
end

---@param message table Gains an `id` field, which the reply is matched on.
---@param callback fun(data: table?, err: string?)
function M:request(message, callback)
	if not self.pipe or self.closed then
		return callback(nil, "Pi bridge is disconnected")
	end
	message.id = vim.fn.sha256(tostring(vim.loop.hrtime()) .. tostring(math.random())):sub(1, 16)
	self.pending[message.id] = callback
	self.pipe:write(encode(message), function(err)
		-- A failed write never gets a response, so retire the callback here instead
		-- of leaving the caller waiting forever.
		if err and self.pending[message.id] then
			local pending_callback = self.pending[message.id]
			self.pending[message.id] = nil
			pending_callback(nil, err)
		end
	end)
end

---@param message string
---@param delivery "steer"|"followUp"|nil Required when Pi is busy; a plain send is refused.
---@param callback fun(data: table?, err: string?)
function M:send(message, delivery, callback)
	self:request({ type = "send", message = message, delivery = delivery }, callback)
end

-- The peer replaces its session and sends the message atomically. A plain
-- reset followed by another socket request cannot work because /new closes the
-- socket as part of replacing the extension runtime.
---@param message string
---@param callback fun(data: table?, err: string?)
function M:new_session(message, callback)
	self:request({ type = "new_session", message = message }, callback)
end

---@param id string? A single finding to drop, or nil to clear them all.
---@param callback fun(data: table?, err: string?)
function M:clear_findings(id, callback)
	self:request({ type = "clear_findings", id_to_clear = id }, callback)
end

---@param reason string? Error reported to every in-flight request.
function M:close(reason)
	if self.closed then
		return
	end
	self.closed = true
	if self.pipe then
		self.pipe:read_stop()
		self.pipe:close()
	end
	-- Fail every in-flight request; none of them can be answered now.
	for _, callback in pairs(self.pending) do
		callback(nil, reason or "Pi bridge disconnected")
	end
	self.pending = {}
end

return M
