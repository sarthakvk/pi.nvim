-- Which Pi is this project talking to, and how. pi.nvim can reach Pi two ways:
-- by attaching over a unix socket to an interactive terminal session that opted
-- in with /nvim-bridge enable, or by spawning its own headless `pi --mode rpc`
-- worker. This module owns the choice between them and the per-root state
-- (transport, mode, activity, session ids) that the rest of the plugin reads.
--
-- Discovery is deliberately opt-in: a Pi process is only reachable if it wrote a
-- descriptor into the user-private runtime directory. Sharing a working
-- directory with Pi is never enough to be attached to.

local project = require("pi.project")
local socket = require("pi.transport.socket")
local rpc = require("pi.transport.rpc")
local ui = require("pi.ui")

---@class pi.session
---@field state table<string, pi.SessionState> Per project root; outlives any single transport.
local M = { state = {} }

-- Where opted-in Pi sessions advertise themselves. Resolution lives here alone
-- so `:checkhealth` reports the directory discovery reads, down to treating an
-- empty XDG_RUNTIME_DIR as unset.
---@return string directory Absolute; not created, see runtime_dir.
function M.runtime_dir_path()
	local base = vim.env.XDG_RUNTIME_DIR
	if not base or base == "" then
		base = vim.fn.stdpath("state") .. "/run"
	end
	return base .. "/pi.nvim"
end

---@return string
local function runtime_dir()
	local directory = M.runtime_dir_path()
	-- 0700: descriptors name a socket that can drive someone's agent session, so
	-- they must not be readable by other users on the machine.
	vim.fn.mkdir(directory, "p", "0700")
	return directory
end

---@param path string
---@return table? value Nil when the file is absent or not valid JSON.
local function read_json(path)
	local lines = vim.fn.readfile(path)
	local ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
	return ok and value or nil
end

-- Every opted-in Pi session for this project, garbage collecting descriptors
-- whose process or socket is gone.
---@param root string
---@return pi.Descriptor[]
function M.discover(root)
	local descriptors = {}
	for _, path in ipairs(vim.fn.globpath(runtime_dir(), "*.json", false, true)) do
		local descriptor = read_json(path)
		if
			descriptor
			and descriptor.version == 1
			and descriptor.root == root
			and type(descriptor.socket_path) == "string"
		then
			local alive = descriptor.pid and vim.uv.kill(descriptor.pid, 0)
			-- Nothing removes descriptors when Pi is killed, so a descriptor whose
			-- process or socket is gone is garbage collected here.
			if alive and vim.uv.fs_stat(descriptor.socket_path) then
				table.insert(descriptors, descriptor)
			else
				pcall(vim.fn.delete, path)
			end
		end
	end
	return descriptors
end

---@param root string
---@return pi.SessionState
local function state_for(root)
	M.state[root] = M.state[root] or { root = root, mode = nil, activity = "idle" }
	return M.state[root]
end

---@param root string
---@return pi.SessionState state Created on first use; the caller installs its on_* handlers.
function M.get(root)
	return state_for(root)
end

-- Connects to an opted-in terminal session, replacing whatever was attached for
-- this root.
---@param root string
---@param descriptor pi.Descriptor
---@param callback fun(state: pi.SessionState?, err: string?)
function M.attach(root, descriptor, callback)
	socket.connect(descriptor, root, {
		on_event = function(event)
			local current = state_for(root)
			if event.type == "activity" then
				current.activity = event.state
				-- Edited paths are reported as they happen but only acted on once Pi
				-- goes idle, so a buffer is not reloaded in the middle of a tool run.
				if event.state == "idle" and current.known_changes then
					local paths = vim.tbl_keys(current.known_changes)
					current.known_changes = {}
					if current.on_known_changes then
						current.on_known_changes(paths)
					end
				end
			elseif event.type == "findings" and current.on_findings_snapshot then
				current.on_findings_snapshot(event.findings, {
					origin_session_id = event.session_id or current.session_id,
					origin_session_file = event.session_file or current.session_file,
				})
			elseif event.type == "tool_activity" then
				current.known_changes = current.known_changes or {}
				for _, path in ipairs(event.paths or {}) do
					current.known_changes[path] = true
				end
			end
		end,
	}, function(transport, err)
		if not transport then
			return callback(nil, err)
		end
		local current = state_for(root)
		-- One transport per root: drop whatever was attached before rather than
		-- leaving a second connection delivering events for the same project.
		if current.transport then
			current.transport:close()
		end
		current.transport, current.mode, current.descriptor = transport, "interactive", descriptor
		current.session_id, current.session_file = transport.state.session_id, transport.state.session_file
		current.activity = transport.state.activity or "idle"
		callback(current)
	end)
end

-- Reattaches to the specific session that produced a finding, so a reply lands
-- in the conversation that has the surrounding reasoning.
---@param root string
---@param session_id string
---@param callback fun(state: pi.SessionState?, err: string?)
function M.attach_origin(root, session_id, callback)
	for _, descriptor in ipairs(M.discover(root)) do
		if descriptor.session_id == session_id then
			return M.attach(root, descriptor, callback)
		end
	end
	callback(nil, "the Pi session that created this finding is not attached")
end

-- Attaches the only opted-in session, or prompts when there is more than one.
---@param root string
---@param callback fun(state: pi.SessionState?, err: string?)
function M.choose_and_attach(root, callback)
	local descriptors = M.discover(root)
	if #descriptors == 0 then
		return callback(nil, "no opted-in Pi terminal session found")
	end
	if #descriptors == 1 then
		return M.attach(root, descriptors[1], callback)
	end
	ui.select(descriptors, "Choose Pi session", function(item)
		return (item.display_name or item.session_id) .. " (pid " .. item.pid .. ")"
	end, function(choice)
		if choice then
			M.attach(root, choice, callback)
		else
			callback(nil, "session selection cancelled")
		end
	end)
end

---@param root string
---@return pi.SavedSession? record
local function saved_session(root)
	local file = project.state_file(root)
	if vim.fn.filereadable(file) == 0 then
		return nil
	end
	return read_json(file)
end

---@param root string
---@param record pi.SavedSession
local function save_session(root, record)
	vim.fn.writefile({ vim.json.encode(record) }, project.state_file(root), "b")
end

-- Starts a headless worker for this root, or returns the running one. The
-- handlers installed here only forward to whatever pi.init put on the state
-- table, which is why each re-reads it rather than capturing it.
---@param root string
---@param config pi.Config
---@param callback fun(state: pi.SessionState?, err: string?)
function M.start_headless(root, config, callback)
	local current = state_for(root)
	if current.mode == "headless" and current.transport and not current.transport.closed then
		if current.stopping then
			return callback(nil, "the existing Pi worker is still stopping")
		end
		return callback(current)
	end
	rpc.start(config, root, config.resume_headless and saved_session(root) or nil, {
		on_event = function(event, worker)
			local current = state_for(root)
			if event.type == "agent_start" then
				current.activity = "working"
			elseif event.type == "agent_settled" then
				current.activity = "idle"
				if current.on_settled then
					current.on_settled(worker)
				end
			elseif event.type == "tool_execution_start" then
				current.activity = "working"
			end
		end,
		-- The handlers below only forward to whatever pi.init wired onto the state
		-- table; they are re-read per call because attaching happens later.
		on_findings = function(items, origin)
			local current = state_for(root)
			if current.on_findings then
				current.on_findings(items, origin)
			end
		end,
		on_findings_snapshot = function(items, origin)
			local current = state_for(root)
			if current.on_findings_snapshot then
				current.on_findings_snapshot(items, origin)
			end
		end,
		on_status = function(key, text)
			local current = state_for(root)
			if current.on_status then
				current.on_status(key, text)
			end
		end,
		on_widget = function(key, lines, placement)
			local current = state_for(root)
			if current.on_widget then
				current.on_widget(key, lines, placement)
			end
		end,
		on_title = function(title)
			local current = state_for(root)
			if current.on_title then
				current.on_title(title)
			end
		end,
		on_editor_text = function(text)
			local current = state_for(root)
			if current.on_editor_text then
				current.on_editor_text(text)
			end
		end,
		on_exit = function(code, _, stderr, worker)
			local current = state_for(root)
			-- A worker that already lost its slot to a newer one must not tear down
			-- the state that replaced it.
			if current.transport == worker then
				current.transport, current.mode, current.stopping, current.activity = nil, nil, nil, "stopped"
			end
			if current.on_exit then
				current.on_exit(code, stderr)
			end
		end,
	}, function(worker, err)
		if not worker then
			return callback(nil, err)
		end
		local current = state_for(root)
		if current.transport then
			current.transport:close()
		end
		current.transport, current.mode = worker, "headless"
		current.session_id, current.session_file = worker.state.sessionId, worker.state.sessionFile
		-- Persisted so the next headless start can resume this conversation instead
		-- of opening a fresh one.
		save_session(root, { session_id = current.session_id, session_file = current.session_file })
		callback(current)
	end)
end

-- Returns the stopped worker's session reference so the caller can tell the user
-- how to resume it; the worker exits asynchronously via on_exit.
---@param root string
---@return pi.SavedSession? stopped, string? err
function M.stop(root)
	local current = state_for(root)
	if current.mode ~= "headless" or not current.transport then
		return nil, "no headless Pi worker is running"
	end
	if current.stopping then
		return nil, "the headless Pi worker is already stopping"
	end
	local stopped = { session_id = current.session_id, session_file = current.session_file }
	current.stopping, current.activity = true, "stopping"
	current.transport:stop()
	return stopped
end

return M
