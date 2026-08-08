local project = require("pi.project")
local socket = require("pi.transport.socket")
local rpc = require("pi.transport.rpc")
local ui = require("pi.ui")

local M = { state = {} }

local function runtime_dir()
  local base = vim.env.XDG_RUNTIME_DIR
  if not base or base == "" then base = vim.fn.stdpath("state") .. "/run" end
  local directory = base .. "/pi.nvim"
  vim.fn.mkdir(directory, "p", "0700")
  return directory
end

local function read_json(path)
  local lines = vim.fn.readfile(path)
  local ok, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok and value or nil
end

function M.discover(root)
  local found = {}
  for _, path in ipairs(vim.fn.globpath(runtime_dir(), "*.json", false, true)) do
    local descriptor = read_json(path)
    if descriptor and descriptor.version == 1 and descriptor.root == root and type(descriptor.socket_path) == "string" then
      local alive = descriptor.pid and vim.uv.kill(descriptor.pid, 0)
      if alive and vim.uv.fs_stat(descriptor.socket_path) then table.insert(found, descriptor) else pcall(vim.fn.delete, path) end
    end
  end
  return found
end

local function state(root)
  M.state[root] = M.state[root] or { root = root, mode = nil, activity = "idle" }
  return M.state[root]
end

function M.get(root) return state(root) end

function M.attach(root, descriptor, callback)
  socket.connect(descriptor, root, {
    on_event = function(event)
      local current = state(root)
      if event.type == "activity" then
        current.activity = event.state
        if event.state == "idle" and current.known_changes then
          local paths = vim.tbl_keys(current.known_changes)
          current.known_changes = {}
          if current.on_known_changes then current.on_known_changes(paths) end
        end
      elseif event.type == "findings" and current.on_findings_snapshot then
        current.on_findings_snapshot(event.findings, { origin_session_id = event.session_id or current.session_id, origin_session_file = event.session_file or current.session_file })
      elseif event.type == "tool_activity" then
        current.known_changes = current.known_changes or {}
        for _, path in ipairs(event.paths or {}) do current.known_changes[path] = true end
      end
    end,
  }, function(transport, err)
    if not transport then return callback(nil, err) end
    local current = state(root)
    if current.transport then current.transport:close() end
    current.transport, current.mode, current.descriptor = transport, "interactive", descriptor
    current.session_id, current.session_file = transport.state.session_id, transport.state.session_file
    current.activity = transport.state.activity or "idle"
    callback(current)
  end)
end

function M.attach_origin(root, session_id, callback)
  for _, descriptor in ipairs(M.discover(root)) do
    if descriptor.session_id == session_id then return M.attach(root, descriptor, callback) end
  end
  callback(nil, "the Pi session that created this finding is not attached")
end

function M.choose_and_attach(root, callback)
  local descriptors = M.discover(root)
  if #descriptors == 0 then return callback(nil, "no opted-in Pi terminal session found") end
  if #descriptors == 1 then return M.attach(root, descriptors[1], callback) end
  ui.select(descriptors, "Choose Pi session", function(item)
    return (item.display_name or item.session_id) .. " (pid " .. item.pid .. ")"
  end, function(choice)
    if choice then M.attach(root, choice, callback) else callback(nil, "session selection cancelled") end
  end)
end

local function saved_session(root)
  local file = project.state_file(root)
  if vim.fn.filereadable(file) == 0 then return nil end
  return read_json(file)
end

local function save_session(root, value)
  vim.fn.writefile({ vim.json.encode(value) }, project.state_file(root), "b")
end

function M.start_headless(root, config, callback)
  local current = state(root)
  if current.mode == "headless" and current.transport and not current.transport.closed then
    if current.stopping then return callback(nil, "the existing Pi worker is still stopping") end
    return callback(current)
  end
  rpc.start(config, root, config.resume_headless and saved_session(root) or nil, {
    on_event = function(event, worker)
      local session = state(root)
      if event.type == "agent_start" then session.activity = "working"
      elseif event.type == "agent_settled" then session.activity = "idle"; if session.on_settled then session.on_settled(worker) end
      elseif event.type == "tool_execution_start" then session.activity = "working" end
    end,
    on_findings = function(items, origin)
      local active = state(root)
      if active.on_findings then active.on_findings(items, origin) end
    end,
    on_findings_snapshot = function(items, origin)
      local active = state(root)
      if active.on_findings_snapshot then active.on_findings_snapshot(items, origin) end
    end,
    on_status = function(key, text)
      local active = state(root)
      if active.on_status then active.on_status(key, text) end
    end,
    on_widget = function(key, lines, placement)
      local active = state(root)
      if active.on_widget then active.on_widget(key, lines, placement) end
    end,
    on_title = function(title)
      local active = state(root)
      if active.on_title then active.on_title(title) end
    end,
    on_editor_text = function(text)
      local active = state(root)
      if active.on_editor_text then active.on_editor_text(text) end
    end,
    on_exit = function(code, _, stderr, worker)
      local session = state(root)
      if session.transport == worker then
        session.transport, session.mode, session.stopping, session.activity = nil, nil, nil, "stopped"
      end
      if session.on_exit then session.on_exit(code, stderr) end
    end,
  }, function(worker, err)
    if not worker then return callback(nil, err) end
    local session = state(root)
    if current.transport then current.transport:close() end
    session.transport, session.mode = worker, "headless"
    session.session_id, session.session_file = worker.state.sessionId, worker.state.sessionFile
    save_session(root, { session_id = session.session_id, session_file = session.session_file })
    callback(session)
  end)
end

function M.stop(root)
  local current = state(root)
  if current.mode ~= "headless" or not current.transport then return nil, "no headless Pi worker is running" end
  if current.stopping then return nil, "the headless Pi worker is already stopping" end
  local result = { session_id = current.session_id, session_file = current.session_file }
  current.stopping, current.activity = true, "stopping"
  current.transport:stop()
  return result
end

return M
