-- Client for a headless Pi worker: spawns `pi --mode rpc` with the companion
-- extension and speaks newline-delimited JSON over its stdio. Requests carry an
-- id and are answered by a `response`; everything else is a stream event
-- (message deltas, tool execution, extension UI requests) that this module
-- either handles itself or forwards to the caller's handlers.
--
-- Unlike the socket transport, this worker is ours: it is started on demand,
-- resumed from the project's saved session when possible, and stopped with
-- Neovim. libuv callbacks arrive off the main loop, so each one re-enters
-- through vim.schedule before touching Neovim state.

local ui = require("pi.ui")

-- Every field the worker accumulates, declared up front: they are assigned
-- across the constructor and the libuv callbacks it installs, which gives
-- lua-language-server nothing to infer from at the point of use.
---@class pi.Rpc
---@field config pi.Config
---@field root string
---@field handlers pi.RpcHandlers
---@field pending table<string, fun(data: table?, err: string?)> In-flight requests by id.
---@field stderr string Accumulated; reported in one piece if the worker dies.
---@field changed_paths table<string, boolean>
---@field stdin uv.uv_pipe_t
---@field stdout uv.uv_pipe_t
---@field stderr_pipe uv.uv_pipe_t
---@field handle uv.uv_process_t? Nil when the spawn failed.
---@field pid integer|string The libuv error message when the spawn failed.
---@field state pi.RpcState? Set once get_state is answered.
---@field buffer string? Partial tail of the last read.
---@field latest_response string? Last full assistant reply, for :PiResponse.
---@field exited boolean?
---@field closed boolean?
local M = {}
M.__index = M

---@return string
local function request_id()
	return vim.fn.sha256(tostring(vim.loop.hrtime()) .. tostring(math.random())):sub(1, 16)
end

-- Spawns the worker and calls back once it has answered get_state, so the caller
-- never receives a transport that cannot yet be addressed.
---@param config pi.Config
---@param root string
---@param saved_session pi.SavedSession? Resumed when its session file still exists.
---@param handlers pi.RpcHandlers?
---@param callback fun(worker: pi.Rpc?, err: string?)
function M.start(config, root, saved_session, handlers, callback)
	-- Cast rather than annotate: the remaining fields are filled in below and by
	-- the libuv callbacks, so the literal is deliberately partial here.
	local self = setmetatable(
		{ config = config, root = root, handlers = handlers or {}, pending = {}, stderr = "", changed_paths = {} },
		M
	) --[[@as pi.Rpc]]
	-- new_pipe returns nil when the process is out of file descriptors. Report that
	-- through the same path as a failed spawn instead of indexing nil below.
	local stdin, stdout, stderr_pipe = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
	if not (stdin and stdout and stderr_pipe) then
		if stdin then
			stdin:close()
		end
		if stdout then
			stdout:close()
		end
		if stderr_pipe then
			stderr_pipe:close()
		end
		return callback(nil, "cannot start Pi: cannot allocate stdio pipes")
	end
	self.stdin, self.stdout, self.stderr_pipe = stdin, stdout, stderr_pipe
	local args = { "--mode", "rpc", "--extension", config.extension_path }
	-- Resuming keeps one conversation per project across restarts; a session file
	-- that has since been deleted is skipped rather than failing the spawn.
	if saved_session and saved_session.session_file and vim.fn.filereadable(saved_session.session_file) == 1 then
		table.insert(args, "--session")
		table.insert(args, saved_session.session_file)
	end
	self.handle, self.pid = vim.uv.spawn(
		config.pi_executable,
		{ args = args, cwd = root, stdio = { self.stdin, self.stdout, self.stderr_pipe } },
		function(code, signal)
			vim.schedule(function()
				self.exited = true
				if self.handlers.on_exit then
					self.handlers.on_exit(code, signal, self.stderr, self)
				end
				self:close()
			end)
		end
	)
	if not self.handle then
		-- On a failed spawn libuv returns the error message where the pid would be.
		-- The pipes are allocated before the spawn, so they are this function's to
		-- release.
		self:close()
		return callback(nil, "cannot start Pi: " .. tostring(self.pid))
	end
	self.stdout:read_start(function(err, data)
		vim.schedule(function()
			if err then
				return self:close(err)
			end
			if data then
				self:feed(data)
			end
		end)
	end)
	-- stderr is only accumulated; it is reported in one piece if the worker dies.
	self.stderr_pipe:read_start(function(_, data)
		if data then
			vim.schedule(function()
				self.stderr = self.stderr .. data
			end)
		end
	end)
	self:request({ type = "get_state" }, function(state, err)
		if err then
			self:stop()
			return callback(nil, err)
		end
		self.state = state
		-- A resumed session may already contain findings published before Neovim
		-- attached. Replaying the conversation's active branch rebuilds them so the
		-- editor shows the same set Pi believes is current.
		self:request({ type = "get_tree" }, function(tree, tree_err)
			if not tree_err and self.handlers.on_findings_snapshot then
				local active_findings, branch_by_id = {}, {}
				local function visit(node, ancestors)
					local chain = vim.list_extend(vim.deepcopy(ancestors), { node.entry })
					branch_by_id[node.entry.id] = chain
					for _, child in ipairs(node.children or {}) do
						visit(child, chain)
					end
				end
				for _, node in ipairs(tree.tree or {}) do
					visit(node, {})
				end
				-- Only the branch ending at the active leaf counts; abandoned branches
				-- describe findings that were undone by a rewind.
				local branch = branch_by_id[tree.leafId] or {}
				for _, entry in ipairs(branch) do
					if
						entry.type == "message"
						and entry.message.role == "toolResult"
						and entry.message.toolName == "nvim_publish_findings"
					then
						for _, finding in ipairs((entry.message.details or {}).findings or {}) do
							active_findings[finding.id] = finding
						end
					elseif entry.type == "custom" and entry.customType == "pi.nvim/findings-clear" then
						local id = entry.data and entry.data.id
						if id then
							active_findings[id] = nil
						else
							active_findings = {}
						end
					end
				end
				self.handlers.on_findings_snapshot(
					vim.tbl_values(active_findings),
					{ origin_session_id = self.state.sessionId, origin_session_file = self.state.sessionFile }
				)
			end
			callback(self)
		end)
	end)
end

-- Reads arrive in arbitrary chunks, so complete lines are cut out of a running
-- buffer and any partial tail is kept for the next read.
---@param data string
function M:feed(data)
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
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if ok then
				self:receive(event)
			else
				ui.notify("invalid JSON from Pi RPC", vim.log.levels.ERROR)
			end
		end
	end
end

---@param event table One decoded RPC frame: a response, a stream event, or a UI request.
function M:receive(event)
	if event.type == "response" and event.id and self.pending[event.id] then
		local callback = self.pending[event.id]
		self.pending[event.id] = nil
		if event.success then
			callback(event.data, nil)
		else
			callback(event.data, event.error or "Pi rejected request")
		end
		return
	end
	if event.type == "message_end" and event.message and event.message.role == "assistant" then
		-- Headless Pi has no terminal of its own, so the last full reply is kept for
		-- :PiResponse to show.
		local text_parts = {}
		for _, content in ipairs(event.message.content or {}) do
			if content.type == "text" then
				table.insert(text_parts, content.text)
			end
		end
		self.latest_response = table.concat(text_parts)
	elseif event.type == "tool_execution_start" and (event.toolName == "edit" or event.toolName == "write") then
		-- Only edits this transport can identify are tracked; shell and third-party
		-- tools change files without announcing a path, so this is a hint for
		-- :checktime, never a complete audit trail.
		local path = event.args and event.args.path
		if type(path) == "string" then
			self.changed_paths[path] = true
		end
	elseif event.type == "tool_execution_end" and event.toolName == "nvim_publish_findings" and not event.isError then
		-- The tool validates and rejects a batch whole, so only a successful call
		-- carries findings the editor can trust.
		local published = event.result and event.result.details and event.result.details.findings
		if type(published) == "table" and self.handlers.on_findings then
			self.handlers.on_findings(published, {
				origin_session_id = self.state and self.state.sessionId,
				origin_session_file = self.state and self.state.sessionFile,
			})
		end
	elseif event.type == "extension_ui_request" then
		-- Answered here and not forwarded: Pi is blocked waiting for the reply.
		return self:ui_request(event)
	end
	if self.handlers.on_event then
		self.handlers.on_event(event, self)
	end
end

-- Serves the UI primitives an extension running inside headless Pi would
-- normally get from Pi's own terminal, mapping each to its Neovim equivalent.
---@param event table
function M:ui_request(event)
	local function respond(payload)
		payload.type, payload.id = "extension_ui_response", event.id
		self:command(payload)
	end
	if event.method == "select" then
		vim.ui.select(event.options or {}, { prompt = event.title }, function(value)
			respond(value and { value = value } or { cancelled = true })
		end)
	elseif event.method == "confirm" then
		vim.ui.select(
			{ "Yes", "No" },
			{ prompt = (event.title or "Confirm") .. ": " .. (event.message or "") },
			function(value)
				respond({ confirmed = value == "Yes", cancelled = value == nil })
			end
		)
	elseif event.method == "input" then
		vim.ui.input({ prompt = event.title, default = event.prefill }, function(value)
			respond(value and { value = value } or { cancelled = true })
		end)
	elseif event.method == "editor" then
		ui.editor(event.title or "Pi input", event.prefill or "", function(value)
			respond(value and { value = value } or { cancelled = true })
		end)
	elseif event.method == "notify" then
		-- Trailing `or nil` so an unrecognised notifyType yields nil rather than
		-- false, and ui.notify's own default applies.
		ui.notify(
			event.message,
			event.notifyType == "error" and vim.log.levels.ERROR
				or event.notifyType == "warning" and vim.log.levels.WARN
				or nil
		)
	elseif event.method == "setStatus" and self.handlers.on_status then
		self.handlers.on_status(event.statusKey, event.statusText)
	elseif event.method == "setWidget" and self.handlers.on_widget then
		self.handlers.on_widget(event.widgetKey, event.widgetLines, event.widgetPlacement)
	elseif event.method == "setTitle" and self.handlers.on_title then
		self.handlers.on_title(event.title)
	elseif event.method == "set_editor_text" and self.handlers.on_editor_text then
		self.handlers.on_editor_text(event.text)
	end
end

-- Fire-and-forget; a closed worker silently drops the write rather than raising
-- on a dead pipe.
---@param command table
function M:command(command)
	if self.closed then
		return
	end
	self.stdin:write(vim.json.encode(command) .. "\n")
end

---@param command table Gains an `id` field, which the reply is matched on.
---@param callback fun(data: table?, err: string?)
function M:request(command, callback)
	command.id = request_id()
	self.pending[command.id] = callback
	self:command(command)
end

---@param message string
---@param delivery "steer"|"followUp"|nil
---@param callback fun(data: table?, err: string?)
function M:send(message, delivery, callback)
	local command = { type = "prompt", message = message }
	if delivery then
		command.streamingBehavior = delivery
	end
	self:request(command, callback)
end

-- Pi exposes session replacement as a dedicated RPC operation rather than a
-- slash-command prompt. Refresh state only after that operation answers so a
-- caller cannot send into the old conversation or persist its identifiers.
---@param callback fun(data: table?, err: string?)
function M:new_session(callback)
	self:request({ type = "new_session" }, function(data, err)
		if err then
			return callback(nil, err)
		end
		if data and data.cancelled then
			return callback(nil, "Pi cancelled the new session")
		end
		self:request({ type = "get_state" }, function(state, state_err)
			if state_err then
				self.state = nil
				return callback({ replaced = true }, state_err)
			end
			self.state = state
			self.latest_response = nil
			self.changed_paths = {}
			if self.handlers.on_findings_snapshot then
				self.handlers.on_findings_snapshot(
					{},
					{ origin_session_id = state.sessionId, origin_session_file = state.sessionFile }
				)
			end
			callback(data)
		end)
	end)
end

-- Pi's RPC protocol dispatches extension slash commands immediately without an LLM turn.
---@param command string Slash command without its leading slash.
---@param callback fun(data: table?, err: string?)
function M:extension_command(command, callback)
	self:request({ type = "prompt", message = "/" .. command }, callback)
end

-- Abort first so an in-flight turn is cancelled cleanly, then signal the process;
-- the state teardown happens in the spawn exit handler.
function M:stop()
	if self.closed then
		return
	end
	self:command({ type = "abort" })
	if self.handle then
		self.handle:kill("sigterm")
	end
end

---@param reason string? Error reported to every in-flight request.
function M:close(reason)
	if self.closed then
		return
	end
	self.closed = true
	for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr_pipe }) do
		if pipe and not pipe:is_closing() then
			pipe:close()
		end
	end
	if self.handle and not self.handle:is_closing() then
		self.handle:close()
	end
	-- Fail every in-flight request; none of them can be answered now.
	for _, callback in pairs(self.pending) do
		callback(nil, reason or "Pi RPC worker stopped")
	end
	self.pending = {}
end

return M
