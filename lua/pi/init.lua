-- Public entry point for pi.nvim: setup/config plus the function behind every
-- :Pi* command. It owns the flow a user sees — capture context, choose or start
-- a Pi target, and send — and delegates the details to pi.context (capture),
-- pi.draft (collection and bundling),
-- pi.session (which Pi to talk to), and pi.ui.
--
-- Two rules shape most of what follows: only saved source is ever sent, and Pi
-- is never started or steered without an explicit user action.

local project = require("pi.project")
local context = require("pi.context")
local draft = require("pi.draft")
local session = require("pi.session")
local ui = require("pi.ui")
local keymaps = require("pi.keymaps")

---@class pi
---@field config pi.Config
local M = {}
-- The companion extension ships inside this repository, so its default path is
-- derived from this file's location rather than asked of the user.
local this_file = debug.getinfo(1, "S").source:sub(2)
local plugin_root = vim.fn.fnamemodify(this_file, ":h:h:h")

M.config = {
	fallback = "ask",
	resume_headless = true,
	max_context_bytes = 256 * 1024,
	pi_executable = "pi",
	extension_path = plugin_root .. "/pi-extension/index.ts",
	keymaps = keymaps.defaults,
	which_key = keymaps.which_key_defaults,
}

---@return string
local function current_root()
	-- Draft listings are scratch buffers with no real path, so they carry the
	-- root they were opened for; fall back to the file or the cwd.
	local stored = vim.b.pi_root
	if type(stored) == "string" and stored ~= "" then
		return stored
	end
	-- Only a normal buffer sitting in a real directory says anything about where
	-- the user is. A plugin's buffer name (`oil://…`) or a :help page's runtime
	-- path would otherwise become a project root of its own, and every request
	-- made from one would go looking for a Pi that cannot exist there.
	local name = vim.api.nvim_buf_get_name(0)
	local named = name ~= ""
		and vim.bo.buftype == ""
		and vim.fn.isdirectory(vim.fn.fnamemodify(name, ":h")) == 1
	return project.root(named and name or vim.fn.getcwd())
end

-- Pi edits the working tree directly, so buffers can go out of date. Reloading
-- is limited to buffers with nothing to lose; anything modified is only
-- reported, because the user's unsaved work outranks Pi's edit.
---@param root string
---@param changed_paths string[] Project-relative or absolute.
local function report_known_changes(root, changed_paths)
	if #changed_paths == 0 then
		return
	end
	ui.notify("Pi changed: " .. table.concat(changed_paths, ", ") .. ". Checking clean buffers.")
	for _, path in ipairs(changed_paths) do
		local absolute = path:sub(1, 1) == "/" and path or root .. "/" .. path
		local bufnr = vim.fn.bufnr(absolute, false)
		if bufnr > 0 and not vim.bo[bufnr].modified then
			vim.cmd("checktime " .. vim.fn.fnameescape(absolute))
		elseif bufnr > 0 then
			ui.notify("Pi changed " .. path .. "; buffer has unsaved changes", vim.log.levels.WARN)
		end
	end
end

-- Installs this module's reactions onto the session state for `root`. Called
-- before every attach or start, since pi.session keeps the handlers on state
-- that outlives any single transport.
---@param root string
local function install_session_handlers(root)
	local current_session = session.get(root)
	current_session.on_known_changes = function(paths)
		report_known_changes(root, paths)
	end
	current_session.on_settled = function(worker)
		report_known_changes(root, vim.tbl_keys(worker.changed_paths or {}))
		ui.notify("Pi settled")
	end
	current_session.on_exit = function(code, stderr)
		if code ~= 0 then
			ui.notify("Pi worker exited (" .. code .. "): " .. stderr, vim.log.levels.ERROR)
		end
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
		if type(title) == "string" then
			vim.o.title, vim.o.titlestring = true, title
		end
	end
	current_session.on_editor_text = function(text)
		ui.open_editor_prefill(text or "")
	end
end

-- Resolves the Pi to send to, attaching or starting one if needed. An attached
-- terminal session always wins; only when none exists does `fallback` decide
-- whether to start headless Pi, ask first, or refuse. Nothing here runs without
-- a user-initiated send, which is why Pi never starts at Neovim startup.
---@param root string
---@param callback fun(target: pi.SessionState?, err: string?)
local function ensure_target(root, callback)
	install_session_handlers(root)
	local current_session = session.get(root)
	if current_session.transport and not current_session.transport.closed then
		if current_session.stopping then
			return callback(nil, "the existing Pi worker is still stopping")
		end
		if current_session.replacing then
			return callback(nil, "a new Pi session is still starting")
		end
		return callback(current_session)
	end
	local descriptors = session.discover(root)
	if #descriptors == 1 then
		return session.attach(root, descriptors[1], callback)
	end
	if #descriptors > 1 then
		return session.choose_and_attach(root, callback)
	end
	if current_session.replacing then
		return callback(nil, "a new Pi session is still starting")
	end
	if M.config.fallback == "none" then
		return callback(nil, "no Pi target is attached")
	end
	if M.config.fallback == "headless" then
		return session.start_headless(root, M.config, callback)
	end
	ui.select({ "Start headless Pi", "Cancel" }, "No terminal Pi session is attached", tostring, function(choice)
		if choice == "Start headless Pi" then
			session.start_headless(root, M.config, callback)
		else
			callback(nil, "headless Pi was not started")
		end
	end)
end

-- Sends one already-encoded message to whichever Pi ensure_target resolves,
-- asking how to deliver it when Pi is mid-turn. Encoding belongs to the caller,
-- which knows whether it is sending a draft bundle, a pointer, or an instruction
-- with no context at all; all three reach Pi through this one policy.
---@param root string
---@param message string A context envelope from pi.draft.
---@param on_sent fun()? Runs only once Pi has accepted the message.
local function deliver(root, message, on_sent)
	ensure_target(root, function(target, err)
		if not target then
			return ui.notify(err, vim.log.levels.WARN)
		end
		local function send(delivery)
			target.transport:send(message, delivery, function(_, send_err)
				if send_err then
					return ui.notify("Pi did not accept context: " .. send_err, vim.log.levels.ERROR)
				end
				if on_sent then
					on_sent()
				end
				ui.notify("Sent to Pi")
			end)
		end
		-- Interrupting a working Pi is the user's call, not ours: an idle target (or
		-- a headless one that has not begun) is sent to directly, and anything else
		-- asks whether to steer the current turn or queue behind it.
		if target.activity == "idle" or target.mode == "headless" and target.activity ~= "working" then
			return send(nil)
		end
		ui.select({ "Steer current work", "Queue follow-up", "Cancel" }, "Pi is working", tostring, function(choice)
			if choice == "Steer current work" then
				send("steer")
			elseif choice == "Queue follow-up" then
				send("followUp")
			end
		end)
	end)
end

-- Starts a fresh conversation and sends one already-encoded message into it.
-- Unlike deliver(), this deliberately ignores the old conversation's activity:
-- replacing that conversation is the user's explicit choice.
---@param root string
---@param message string A context envelope from pi.draft.
local function deliver_new(root, message)
	ensure_target(root, function(target, err)
		if not target then
			return ui.notify(err, vim.log.levels.WARN)
		end
		session.new_conversation(root, message, function(_, new_err)
			if new_err then
				return ui.notify("Pi did not start a new session: " .. new_err, vim.log.levels.ERROR)
			end
			ui.notify(target.mode == "interactive" and "Starting a new Pi session and sending context"
				or "Started a new Pi session and sent context")
		end)
	end)
end

-- With a command range, capture exactly it; otherwise the whole file.
---@param opts vim.api.keyset.create_user_command.command_args?
---@return pi.Capture? captured, string? err
local function capture(opts)
	local bufnr = vim.api.nvim_get_current_buf()
	if opts and opts.range and opts.range > 0 then
		return context.range(bufnr, opts.line1, opts.line2)
	end
	return context.file(bufnr)
end

-- :PiContextAdd — capture the range or file and append it to the draft.
---@param opts vim.api.keyset.create_user_command.command_args
function M.context_add(opts)
	local note = opts.args ~= "" and opts.args or nil
	local function add_with_note(note_text)
		local captured, err = capture(opts)
		if not captured then
			return ui.notify("Cannot add Pi context: " .. err, vim.log.levels.WARN)
		end
		draft.add(captured, note_text or "")
		ui.notify("Added " .. captured.relative_path .. ":" .. captured.start_line .. "-" .. captured.end_line)
	end
	if note then
		add_with_note(note)
	else
		ui.input("Context note (optional): ", function(entered)
			-- nil is a cancelled prompt, which abandons the add; an empty string is an
			-- answered prompt with no note.
			if entered ~= nil then
				add_with_note(entered)
			end
		end)
	end
end

-- :PiContextShow
function M.context_show()
	local root = current_root()
	ui.open_draft(root, draft.items(root))
end

-- The draft listing is edited by putting the cursor on an item, so the item's
-- index is the cursor line minus the two header lines ui.open_draft writes.
---@return integer? index One-based, or nil when the cursor is on a header line.
local function draft_index()
	local line = vim.api.nvim_win_get_cursor(0)[1] - 2
	return line > 0 and line or nil
end

-- :PiContextRemove — acts on the draft item under the cursor.
function M.context_remove()
	local root, index = current_root(), draft_index()
	if not index or not draft.remove(root, index) then
		return ui.notify("Place the cursor on a draft item", vim.log.levels.WARN)
	end
	ui.notify("Removed Pi context item")
end

-- :PiContextRefresh — re-reads the item under the cursor from disk.
function M.context_refresh()
	local root, index = current_root(), draft_index()
	if not index then
		return ui.notify("Place the cursor on a draft item", vim.log.levels.WARN)
	end
	local _, err = draft.refresh(root, index)
	if err then
		ui.notify("Cannot refresh context: " .. err, vim.log.levels.WARN)
	else
		ui.notify("Refreshed Pi context item")
	end
end

-- :PiContextClear
function M.context_clear()
	draft.clear(current_root())
	ui.notify("Cleared Pi context draft")
end

-- :PiContextMove — moves the item under the cursor to the given position.
---@param opts vim.api.keyset.create_user_command.command_args
function M.context_move(opts)
	local root, from = current_root(), draft_index()
	local to = tonumber(opts.args)
	if not from or not to or not draft.move(root, from, to) then
		return ui.notify("Place the cursor on a draft item and provide a valid destination index", vim.log.levels.WARN)
	end
	ui.notify("Moved Pi context item to position " .. to)
	M.context_show()
end

-- :PiContextSend — bundles the whole draft and sends it, clearing it on success.
function M.context_send()
	local root = current_root()
	ui.input("Instruction for Pi: ", function(note)
		if note == nil then
			return
		end
		local request, err = draft.bundle(root, note, M.config.max_context_bytes)
		if not request then
			return ui.notify("Cannot send Pi context: " .. err, vim.log.levels.WARN)
		end
		-- The draft is only emptied once Pi has accepted the bundle, so a rejected
		-- send leaves the user's collection intact.
		deliver(root, draft.envelope(request), function()
			draft.clear(root)
		end)
	end)
end

-- :PiSend and :PiNew build a one-shot send that tells Pi where the user is instead of quoting
-- what is there. The pointer carries no source, so Pi reads the file itself,
-- and that is what lets this work everywhere an excerpt cannot: an empty file,
-- one that has never been written, one with unsaved changes, or no file at all,
-- which sends the instruction on its own.
---@param opts vim.api.keyset.create_user_command.command_args
---@param send fun(root: string, message: string)
local function send_current_with(opts, send)
	local ranged = opts and opts.range and opts.range > 0
	-- Resolved before the prompt: vim.ui.input can move the cursor, and the
	-- selection is gone by the time the user has finished typing.
	local pointer, reason = context.pointer(
		vim.api.nvim_get_current_buf(),
		ranged and opts.line1 or nil,
		ranged and opts.line2 or nil
	)
	local root = pointer and pointer.root or current_root()
	ui.input("Instruction for Pi: ", function(note)
		if note == nil then
			return
		end
		if not pointer then
			-- With no file there is nothing to point at and the instruction is the
			-- whole message. It still travels as an envelope with no contexts rather
			-- than as bare text, because Pi reads a prompt beginning with "/" as a
			-- slash command and would run it instead of answering it.
			if note == "" then
				return ui.notify("Nothing to send: " .. reason, vim.log.levels.WARN)
			end
			ui.notify("Sending without a file: " .. reason, vim.log.levels.WARN)
			return send(root, draft.envelope({ id = draft.new_id(), root = root, note = note, contexts = {} }))
		end
		-- Pi resolves the pointer by reading the file, so anything that makes disk
		-- and buffer disagree is worth saying out loud rather than letting Pi
		-- silently answer about source the user is not looking at. A file that is
		-- not there yet is reported ahead of the unsaved changes that are the reason
		-- it is not there, because it is the more specific problem: Pi will find
		-- nothing at all to read.
		if not pointer.exists then
			ui.notify(pointer.relative_path .. " is not on disk yet; Pi cannot read it", vim.log.levels.WARN)
		elseif pointer.modified then
			ui.notify("Buffer has unsaved changes; Pi will read the saved file", vim.log.levels.WARN)
		end
		-- Use the same unique request and context ids as draft sends.
		local request = {
			id = draft.new_id(),
			root = pointer.root,
			note = note,
			contexts = {
				{
					id = draft.new_id(),
					path = pointer.relative_path,
					start_line = pointer.start_line,
					end_line = pointer.end_line,
					cursor_line = pointer.cursor_line,
					note = opts and opts.args or "",
				},
			},
		}
		send(root, draft.envelope(request))
	end)
end

-- :PiSend — send a pointer request into the current conversation.
---@param opts vim.api.keyset.create_user_command.command_args
function M.send_current(opts)
	send_current_with(opts, deliver)
end

-- :PiNew — start a fresh conversation, then send the same pointer request as
-- :PiSend. The request is fully captured before replacing the session.
---@param opts vim.api.keyset.create_user_command.command_args
function M.new(opts)
	send_current_with(opts, deliver_new)
end

-- :PiAttach
function M.attach()
	local root = current_root()
	install_session_handlers(root)
	session.choose_and_attach(root, function(_, err)
		if err then
			ui.notify(err, vim.log.levels.WARN)
		else
			ui.notify("Attached Pi terminal session")
		end
	end)
end

-- :PiSessions — lists what this project could talk to and attaches to the one
-- the user picks. The attached session is listed for orientation only: it
-- carries no descriptor, so choosing it is a no-op.
function M.sessions()
	local root = current_root()
	local current_session = session.get(root)
	local attached_id = current_session.transport and current_session.session_id or nil
	---@type { label: string, descriptor: pi.Descriptor? }[]
	local choices = {}
	for _, descriptor in ipairs(session.discover(root)) do
		local attached = attached_id ~= nil and descriptor.session_id == attached_id
		table.insert(choices, {
			label = (descriptor.display_name or descriptor.session_id)
				.. " (pid "
				.. descriptor.pid
				.. (attached and ", attached)" or ")"),
			descriptor = not attached and descriptor or nil,
		})
	end
	-- A headless worker publishes no descriptor, so discovery cannot see it; the
	-- local state is the only place it is known.
	if current_session.transport and current_session.mode == "headless" then
		table.insert(choices, 1, { label = "headless " .. (current_session.session_id or "Pi") .. " (attached)" })
	end
	if #choices == 0 then
		return ui.notify("No Pi sessions available")
	end
	ui.select(choices, "Pi sessions", function(item)
		return item.label
	end, function(choice)
		if not choice or not choice.descriptor then
			return
		end
		install_session_handlers(root)
		session.attach(root, choice.descriptor, function(_, err)
			if err then
				ui.notify(err, vim.log.levels.WARN)
			else
				ui.notify("Attached Pi terminal session")
			end
		end)
	end)
end

-- Headless Pi has no terminal of its own, so its last reply is only visible here.
-- :PiResponse
function M.response()
	local current_session = session.get(current_root())
	if not current_session.transport or current_session.mode ~= "headless" then
		return ui.notify("No headless Pi response is available", vim.log.levels.WARN)
	end
	ui.open_text("pi://response", current_session.transport.latest_response or "No completed assistant response yet.")
end

-- :PiStatus
function M.status()
	local current_session = session.get(current_root())
	ui.notify(
		("mode: %s, activity: %s, session: %s"):format(
			current_session.mode or "none",
			current_session.activity or "idle",
			current_session.session_id or "none"
		)
	)
end

-- :PiStop — asks the headless worker to exit; it goes away asynchronously.
function M.stop()
	local stopped, err = session.stop(current_root())
	if not stopped then
		-- session.stop always pairs a nil result with a reason; the fallback only
		-- exists because that pairing is not expressible in the annotation.
		return ui.notify(err or "cannot stop Pi", vim.log.levels.WARN)
	end
	-- The session reference is the only way back into this conversation once the
	-- worker is gone, so hand the user the exact command to resume it.
	ui.notify(
		"Pi stop requested. Resume after it exits with: "
			.. M.config.pi_executable
			.. " --session "
			.. (stopped.session_file or stopped.session_id)
	)
end

-- Merges user options over the defaults and installs the plugin's autocommands.
---@param options table? Partial pi.Config.
function M.setup(options)
	M.config = vim.tbl_deep_extend("force", M.config, options or {})
	local group = vim.api.nvim_create_augroup("pi.nvim", { clear = true })
	keymaps.setup(M.config.keymaps, M.config.which_key, group)
	-- Headless workers are ours, so they leave with Neovim. Attached terminal
	-- sessions belong to the user and are left running.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for root, current_session in pairs(session.state) do
				if current_session.mode == "headless" then
					session.stop(root)
				end
			end
		end,
	})
end

return M
