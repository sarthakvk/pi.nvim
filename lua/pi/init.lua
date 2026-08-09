-- Public entry point for pi.nvim: setup/config plus the function behind every
-- :Pi* command. It owns the flow a user sees — capture context, choose or start
-- a Pi target, send, and work with the findings that come back — and delegates
-- the details to pi.context (capture), pi.draft (collection and bundling),
-- pi.session (which Pi to talk to), pi.findings (annotations), and pi.ui.
--
-- Two rules shape most of what follows: only saved source is ever sent, and Pi
-- is never started or steered without an explicit user action.

local project = require("pi.project")
local context = require("pi.context")
local draft = require("pi.draft")
local session = require("pi.session")
local findings = require("pi.findings")
local ui = require("pi.ui")

local M = {}
-- The companion extension ships inside this repository, so its default path is
-- derived from this file's location rather than asked of the user.
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":h:h:h")

M.config = {
  fallback = "ask", resume_headless = true, max_context_bytes = 256 * 1024,
  pi_executable = "pi", extension_path = plugin_root .. "/pi-extension/index.ts",
  diagnostics = { signs = true, underline = true, virtual_text = false },
}

local function current_root()
  -- Draft and findings listings are scratch buffers with no real path, so they
  -- carry the root they were opened for; fall back to the file or the cwd.
  local stored = vim.b.pi_root
  if type(stored) == "string" and stored ~= "" then return stored end
  local name = vim.api.nvim_buf_get_name(0)
  return project.root(name ~= "" and name or vim.fn.getcwd())
end

-- Pi edits the working tree directly, so buffers can go out of date. Reloading
-- is limited to buffers with nothing to lose; anything modified is only
-- reported, because the user's unsaved work outranks Pi's edit.
local function report_known_changes(root, changed_paths)
  if #changed_paths == 0 then return end
  ui.notify("Pi changed: " .. table.concat(changed_paths, ", ") .. ". Checking clean buffers.")
  for _, path in ipairs(changed_paths) do
    local absolute = path:sub(1, 1) == "/" and path or root .. "/" .. path
    local bufnr = vim.fn.bufnr(absolute, false)
    if bufnr > 0 and not vim.bo[bufnr].modified then vim.cmd("checktime " .. vim.fn.fnameescape(absolute))
    elseif bufnr > 0 then ui.notify("Pi changed " .. path .. "; buffer has unsaved changes", vim.log.levels.WARN) end
  end
end

-- Installs this module's reactions onto the session state for `root`. Called
-- before every attach or start, since pi.session keeps the handlers on state
-- that outlives any single transport.
local function install_session_handlers(root)
  local current_session = session.get(root)
  -- Findings are tagged with the session that produced them so :PiReply can go
  -- back to the conversation holding the surrounding reasoning.
  local function origin_or_current(metadata)
    return metadata or { origin_session_id = current_session.session_id, origin_session_file = current_session.session_file }
  end
  current_session.on_findings = function(items, metadata) findings.publish(root, items, origin_or_current(metadata)) end
  current_session.on_findings_snapshot = function(items, metadata) findings.replace(root, items, origin_or_current(metadata)) end
  current_session.on_known_changes = function(paths) report_known_changes(root, paths) end
  current_session.on_settled = function(worker)
    report_known_changes(root, vim.tbl_keys(worker.changed_paths or {}))
    findings.revalidate(root)
    ui.notify("Pi settled")
  end
  current_session.on_exit = function(code, stderr)
    if code ~= 0 then ui.notify("Pi worker exited (" .. code .. "): " .. stderr, vim.log.levels.ERROR) end
  end
  current_session.on_status = function(key, text)
    current_session.status = current_session.status or {}
    current_session.status[key] = text
  end
  current_session.on_widget = function(key, lines, placement)
    current_session.widgets = current_session.widgets or {}
    current_session.widgets[key] = lines and { lines = lines, placement = placement } or nil
  end
  current_session.on_title = function(title)
    if type(title) == "string" then vim.o.title, vim.o.titlestring = true, title end
  end
  current_session.on_editor_text = function(text)
    ui.open_editor_prefill(text or "")
  end
end

-- Resolves the Pi to send to, attaching or starting one if needed. An attached
-- terminal session always wins; only when none exists does `fallback` decide
-- whether to start headless Pi, ask first, or refuse. Nothing here runs without
-- a user-initiated send, which is why Pi never starts at Neovim startup.
local function ensure_target(root, callback)
  install_session_handlers(root)
  local current_session = session.get(root)
  if current_session.transport and not current_session.transport.closed then
    if current_session.stopping then return callback(nil, "the existing Pi worker is still stopping") end
    return callback(current_session)
  end
  local descriptors = session.discover(root)
  if #descriptors == 1 then return session.attach(root, descriptors[1], callback) end
  if #descriptors > 1 then return session.choose_and_attach(root, callback) end
  if M.config.fallback == "none" then return callback(nil, "no Pi target is attached") end
  if M.config.fallback == "headless" then return session.start_headless(root, M.config, callback) end
  ui.select({ "Start headless Pi", "Cancel" }, "No terminal Pi session is attached", tostring, function(choice)
    if choice == "Start headless Pi" then session.start_headless(root, M.config, callback)
    else callback(nil, "headless Pi was not started") end
  end)
end

local function deliver(root, request, on_sent)
  ensure_target(root, function(target, err)
    if not target then return ui.notify(err, vim.log.levels.WARN) end
    local function send(delivery)
      target.transport:send(draft.envelope(request), delivery, function(_, send_err)
        if send_err then return ui.notify("Pi did not accept context: " .. send_err, vim.log.levels.ERROR) end
        on_sent()
        ui.notify("Context sent to Pi")
      end)
    end
    -- Interrupting a working Pi is the user's call, not ours: an idle target (or
    -- a headless one that has not begun) is sent to directly, and anything else
    -- asks whether to steer the current turn or queue behind it.
    if target.activity == "idle" or target.mode == "headless" and target.activity ~= "working" then return send(nil) end
    ui.select({ "Steer current work", "Queue follow-up", "Cancel" }, "Pi is working", tostring, function(choice)
      if choice == "Steer current work" then send("steer")
      elseif choice == "Queue follow-up" then send("followUp") end
    end)
  end)
end

-- With a command range, capture exactly it; otherwise the whole file.
local function capture(opts)
  local bufnr = vim.api.nvim_get_current_buf()
  if opts and opts.range and opts.range > 0 then return context.range(bufnr, opts.line1, opts.line2) end
  return context.file(bufnr)
end

function M.context_add(opts)
  local note = opts.args ~= "" and opts.args or nil
  local function add_with_note(note_text)
    local captured, err = capture(opts)
    if not captured then return ui.notify("Cannot add Pi context: " .. err, vim.log.levels.WARN) end
    draft.add(captured, note_text or "")
    ui.notify("Added " .. captured.relative_path .. ":" .. captured.start_line .. "-" .. captured.end_line)
  end
  if note then add_with_note(note) else ui.input("Context note (optional): ", add_with_note) end
end

function M.context_show()
  local root = current_root()
  ui.open_draft(root, draft.items(root))
end

-- The draft listing is edited by putting the cursor on an item, so the item's
-- index is the cursor line minus the two header lines ui.open_draft writes.
local function draft_index()
  local line = vim.api.nvim_win_get_cursor(0)[1] - 2
  return line > 0 and line or nil
end

function M.context_remove()
  local root, index = current_root(), draft_index()
  if not index or not draft.remove(root, index) then return ui.notify("Place the cursor on a draft item", vim.log.levels.WARN) end
  ui.notify("Removed Pi context item")
end

function M.context_refresh()
  local root, index = current_root(), draft_index()
  if not index then return ui.notify("Place the cursor on a draft item", vim.log.levels.WARN) end
  local _, err = draft.refresh(root, index)
  if err then ui.notify("Cannot refresh context: " .. err, vim.log.levels.WARN) else ui.notify("Refreshed Pi context item") end
end

function M.context_clear()
  draft.clear(current_root())
  ui.notify("Cleared Pi context draft")
end

function M.context_move(opts)
  local root, from = current_root(), draft_index()
  local to = tonumber(opts.args)
  if not from or not to or not draft.move(root, from, to) then
    return ui.notify("Place the cursor on a draft item and provide a valid destination index", vim.log.levels.WARN)
  end
  ui.notify("Moved Pi context item to position " .. to)
  M.context_show()
end

function M.context_send()
  local root = current_root()
  ui.input("Instruction for Pi: ", function(note)
    if note == nil then return end
    local request, err = draft.bundle(root, note, M.config.max_context_bytes)
    if not request then return ui.notify("Cannot send Pi context: " .. err, vim.log.levels.WARN) end
    -- The draft is only emptied once Pi has accepted the bundle, so a rejected
    -- send leaves the user's collection intact.
    deliver(root, request, function() draft.clear(root) end)
  end)
end

-- :PiSend — a one-shot bundle built from the current file or range that never
-- touches the draft, for when collecting context first would be ceremony.
function M.send_current(opts)
  ui.input("Instruction for Pi: ", function(note)
    if note == nil then return end
    local captured, err = capture(opts)
    if not captured then return ui.notify("Cannot send Pi context: " .. err, vim.log.levels.WARN) end
    local item = { id = vim.fn.sha256(tostring(vim.loop.hrtime())):sub(1, 16), kind = captured.kind or "range", path = captured.relative_path,
      start_line = captured.start_line, end_line = captured.end_line, text = captured.text, hash = captured.hash,
      original_hash = captured.hash, changed_since_added = false, note = opts.args or "" }
    local request = { id = vim.fn.sha256(tostring(vim.loop.hrtime())):sub(1, 16), root = captured.root, note = note, contexts = { item } }
    if #vim.json.encode(request) > M.config.max_context_bytes then return ui.notify("Context exceeds configured size limit", vim.log.levels.WARN) end
    deliver(captured.root, request, function() end)
  end)
end

function M.attach()
  local root = current_root()
  install_session_handlers(root)
  session.choose_and_attach(root, function(_, err)
    if err then ui.notify(err, vim.log.levels.WARN) else ui.notify("Attached Pi terminal session") end
  end)
end

function M.sessions()
  local root, current_session = current_root(), session.get(current_root())
  local choices = session.discover(root)
  if current_session.transport then table.insert(choices, 1, { display_name = "attached " .. (current_session.session_id or "Pi"), attached = true }) end
  if #choices == 0 then return ui.notify("No Pi sessions available") end
  ui.select(choices, "Pi sessions", function(item) return item.display_name or item.session_id end, function() end)
end

function M.findings()
  local root = current_root()
  findings.revalidate(root)
  ui.open_findings(root, findings.list(root))
end

function M.reply()
  local root, finding = current_root(), findings.at_cursor(current_root())
  if not finding then return ui.notify("No Pi finding at cursor", vim.log.levels.WARN) end
  ui.input("Reply to finding: ", function(reply)
    if not reply or reply == "" then return end
    local function send(target)
      -- The reply names the finding and whether it still matches the source, so
      -- Pi can tell an answer about live code from one about a stale range.
      local message = ("Reply to Pi finding %s (request %s, %s):\n%s"):format(finding.id, finding.request_id or "unknown", finding.stale and "stale" or "current", reply)
      target.transport:send(message, target.activity == "working" and "followUp" or nil, function(_, send_err)
        if send_err then ui.notify(send_err, vim.log.levels.ERROR) else ui.notify("Reply sent to Pi") end
      end)
    end
    -- A reply belongs in the conversation that raised the finding; only if that
    -- session is gone does the user get to pick a different one.
    local current_session = session.get(root)
    if finding.origin_session_id and current_session.session_id ~= finding.origin_session_id then
      return session.attach_origin(root, finding.origin_session_id, function(target, err)
        if target then return send(target) end
        ui.select({ "Choose another attached session", "Cancel" }, err, tostring, function(choice)
          if choice == "Choose another attached session" then
            session.choose_and_attach(root, function(selected, select_err)
              if selected then send(selected) else ui.notify(select_err, vim.log.levels.WARN) end
            end)
          end
        end)
      end)
    end
    ensure_target(root, function(target, err)
      if target then send(target) else ui.notify(err, vim.log.levels.WARN) end
    end)
  end)
end

-- Clears the finding under the cursor, or all of them. The local state is
-- cleared first and unconditionally: telling Pi is best effort, and the user
-- asked for the annotation to go away either way.
function M.clear()
  local root, finding = current_root(), findings.at_cursor(current_root())
  local id = finding and finding.id or nil
  findings.clear(root, id)
  local current_session = session.get(root)
  -- Each transport has its own way to record the clear in Pi's session: the
  -- bridge socket has a request for it, the RPC worker only has slash commands.
  if current_session.mode == "interactive" and current_session.transport then
    current_session.transport:clear_findings(id, function(_, err)
      if err then ui.notify("Finding was cleared locally only: " .. err, vim.log.levels.WARN) end
    end)
  elseif current_session.mode == "headless" and current_session.transport then
    current_session.transport:extension_command("nvim-bridge clear" .. (id and " " .. id or ""), function(_, err)
      if err then ui.notify("Finding was cleared locally only: " .. err, vim.log.levels.WARN) end
    end)
  end
  ui.notify(finding and "Cleared Pi finding" or "Cleared Pi findings")
end

-- Headless Pi has no terminal of its own, so its last reply is only visible here.
function M.response()
  local current_session = session.get(current_root())
  if not current_session.transport or current_session.mode ~= "headless" then return ui.notify("No headless Pi response is available", vim.log.levels.WARN) end
  ui.open_text("pi://response", current_session.transport.latest_response or "No completed assistant response yet.")
end

function M.status()
  local current_session = session.get(current_root())
  ui.notify(("mode: %s, activity: %s, session: %s"):format(current_session.mode or "none", current_session.activity or "idle", current_session.session_id or "none"))
end

function M.stop()
  local stopped, err = session.stop(current_root())
  if not stopped then return ui.notify(err, vim.log.levels.WARN) end
  -- The session reference is the only way back into this conversation once the
  -- worker is gone, so hand the user the exact command to resume it.
  ui.notify("Pi stop requested. Resume after it exits with: " .. M.config.pi_executable .. " --session " .. (stopped.session_file or stopped.session_id))
end

function M.setup(options)
  M.config = vim.tbl_deep_extend("force", M.config, options or {})
  vim.diagnostic.config(M.config.diagnostics, findings.namespace)
  local group = vim.api.nvim_create_augroup("pi.nvim", { clear = true })
  -- Findings anchor to exact text, so any edit or buffer switch is a chance for
  -- one to become stale; re-checking here keeps the [stale] marker honest.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufEnter", "BufWritePost" }, { group = group, callback = function(args)
    local name = vim.api.nvim_buf_get_name(args.buf)
    if name ~= "" then findings.revalidate(project.root(name)) end
  end })
  -- Headless workers are ours, so they leave with Neovim. Attached terminal
  -- sessions belong to the user and are left running.
  vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    for root, current_session in pairs(session.state) do if current_session.mode == "headless" then session.stop(root) end end
  end })
end

return M
