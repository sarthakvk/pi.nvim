local project = require("pi.project")
local ui = require("pi.ui")

local M = {}
M.__index = M

local function request_id()
  return vim.fn.sha256(tostring(vim.loop.hrtime()) .. tostring(math.random())):sub(1, 16)
end

function M.start(config, root, saved, handlers, callback)
  local self = setmetatable({ config = config, root = root, handlers = handlers or {}, pending = {}, stderr = "", changed_paths = {} }, M)
  self.stdin, self.stdout, self.stderr_pipe = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
  local args = { "--mode", "rpc", "--extension", config.extension_path }
  if saved and saved.session_file and vim.fn.filereadable(saved.session_file) == 1 then
    table.insert(args, "--session")
    table.insert(args, saved.session_file)
  end
  self.handle, self.pid = vim.uv.spawn(config.pi_executable, { args = args, cwd = root, stdio = { self.stdin, self.stdout, self.stderr_pipe } }, function(code, signal)
    vim.schedule(function()
      self.exited = true
      if self.handlers.on_exit then self.handlers.on_exit(code, signal, self.stderr, self) end
      self:close()
    end)
  end)
  if not self.handle then
    return callback(nil, "cannot start Pi: " .. tostring(self.pid))
  end
  self.stdout:read_start(function(err, data)
    vim.schedule(function()
      if err then return self:close(err) end
      if data then self:feed(data) end
    end)
  end)
  self.stderr_pipe:read_start(function(_, data)
    if data then vim.schedule(function() self.stderr = self.stderr .. data end) end
  end)
  self:request({ type = "get_state" }, function(state, err)
    if err then self:stop(); return callback(nil, err) end
    self.state = state
    self:request({ type = "get_tree" }, function(tree, tree_err)
      if not tree_err and self.handlers.on_findings_snapshot then
        local active, by_id = {}, {}
        local function visit(node, path)
          local next_path = vim.list_extend(vim.deepcopy(path), { node.entry })
          by_id[node.entry.id] = next_path
          for _, child in ipairs(node.children or {}) do visit(child, next_path) end
        end
        for _, node in ipairs(tree.tree or {}) do visit(node, {}) end
        local branch = by_id[tree.leafId] or {}
        for _, entry in ipairs(branch) do
          if entry.type == "message" and entry.message.role == "toolResult" and entry.message.toolName == "nvim_publish_findings" then
            for _, finding in ipairs((entry.message.details or {}).findings or {}) do active[finding.id] = finding end
          elseif entry.type == "custom" and entry.customType == "pi.nvim/findings-clear" then
            local id = entry.data and entry.data.id
            if id then active[id] = nil else active = {} end
          end
        end
        self.handlers.on_findings_snapshot(vim.tbl_values(active), { origin_session_id = self.state.sessionId, origin_session_file = self.state.sessionFile })
      end
      callback(self)
    end)
  end)
end

function M:feed(data)
  self.buffer = (self.buffer or "") .. data
  while true do
    local nl = self.buffer:find("\n", 1, true)
    if not nl then break end
    local line = self.buffer:sub(1, nl - 1)
    self.buffer = self.buffer:sub(nl + 1)
    if line:sub(-1) == "\r" then line = line:sub(1, -2) end
    if line ~= "" then
      local ok, event = pcall(vim.json.decode, line)
      if ok then self:receive(event) else ui.notify("invalid JSON from Pi RPC", vim.log.levels.ERROR) end
    end
  end
end

function M:receive(event)
  if event.type == "response" and event.id and self.pending[event.id] then
    local callback = self.pending[event.id]
    self.pending[event.id] = nil
    if event.success then callback(event.data, nil) else callback(event.data, event.error or "Pi rejected request") end
    return
  end
  if event.type == "message_end" and event.message and event.message.role == "assistant" then
    local text = {}
    for _, content in ipairs(event.message.content or {}) do if content.type == "text" then table.insert(text, content.text) end end
    self.latest_response = table.concat(text)
  elseif event.type == "tool_execution_start" and (event.toolName == "edit" or event.toolName == "write") then
    local path = event.args and event.args.path
    if type(path) == "string" then self.changed_paths[path] = true end
  elseif event.type == "tool_execution_end" and event.toolName == "nvim_publish_findings" then
    local published = event.result and event.result.details and event.result.details.findings
    if type(published) == "table" and self.handlers.on_findings then
      self.handlers.on_findings(published, { origin_session_id = self.state and self.state.sessionId, origin_session_file = self.state and self.state.sessionFile })
    end
  elseif event.type == "extension_ui_request" then
    return self:ui_request(event)
  end
  if self.handlers.on_event then self.handlers.on_event(event, self) end
end

function M:ui_request(event)
  local function respond(payload)
    payload.type, payload.id = "extension_ui_response", event.id
    self:command(payload)
  end
  if event.method == "select" then
    vim.ui.select(event.options or {}, { prompt = event.title }, function(value) respond(value and { value = value } or { cancelled = true }) end)
  elseif event.method == "confirm" then
    vim.ui.select({ "Yes", "No" }, { prompt = (event.title or "Confirm") .. ": " .. (event.message or "") }, function(value)
      respond({ confirmed = value == "Yes", cancelled = value == nil })
    end)
  elseif event.method == "input" then
    vim.ui.input({ prompt = event.title, default = event.prefill }, function(value)
      respond(value and { value = value } or { cancelled = true })
    end)
  elseif event.method == "editor" then
    ui.editor(event.title or "Pi input", event.prefill or "", function(value)
      respond(value and { value = value } or { cancelled = true })
    end)
  elseif event.method == "notify" then
    ui.notify(event.message, event.notifyType == "error" and vim.log.levels.ERROR or event.notifyType == "warning" and vim.log.levels.WARN)
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

function M:command(command)
  if self.closed then return end
  self.stdin:write(vim.json.encode(command) .. "\n")
end

function M:request(command, callback)
  command.id = request_id()
  self.pending[command.id] = callback
  self:command(command)
end

function M:send(message, delivery, callback)
  local command = { type = "prompt", message = message }
  if delivery then command.streamingBehavior = delivery end
  self:request(command, callback)
end

-- Pi's RPC protocol dispatches extension slash commands immediately without an LLM turn.
function M:extension_command(command, callback)
  self:request({ type = "prompt", message = "/" .. command }, callback)
end

function M:stop()
  if self.closed then return end
  self:command({ type = "abort" })
  if self.handle then self.handle:kill("sigterm") end
end

function M:close(reason)
  if self.closed then return end
  self.closed = true
  for _, pipe in ipairs({ self.stdin, self.stdout, self.stderr_pipe }) do
    if pipe and not pipe:is_closing() then pipe:close() end
  end
  if self.handle and not self.handle:is_closing() then self.handle:close() end
  for _, callback in pairs(self.pending) do callback(nil, reason or "Pi RPC worker stopped") end
  self.pending = {}
end

return M
