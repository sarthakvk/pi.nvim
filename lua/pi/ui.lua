-- Every piece of Neovim UI pi.nvim puts on screen. Prompts and pickers go
-- through vim.ui.* so a user's picker plugin is respected, and all listings are
-- throwaway scratch buffers rather than a permanent window, which keeps the
-- editor quiet when the bridge is not in use. Nothing here talks to Pi; callers
-- own the transport and pass in plain text.

local M = {}

function M.notify(message, level)
	vim.notify(message, level or vim.log.levels.INFO, { title = "pi.nvim" })
end

function M.input(prompt, callback, default)
	vim.ui.input({ prompt = prompt, default = default }, callback)
end

function M.select(items, prompt, format, callback)
	vim.ui.select(items, { prompt = prompt, format_item = format }, callback)
end

function M.open_text(name, text)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, name)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].modifiable = false
	vim.cmd("botright new")
	vim.api.nvim_win_set_buf(0, bufnr)
	return bufnr
end

-- Buffer-backed prompt for Pi's `editor` UI request, which asks for text too
-- long for a one-line vim.ui.input. The callback receives nil on cancel so the
-- caller can tell an empty answer apart from a refused one.
function M.editor(title, prefill, callback)
	local bufnr = vim.api.nvim_create_buf(false, true)
	-- Buffer names must be unique; a short digest of the clock keeps concurrent
	-- prompts from colliding.
	vim.api.nvim_buf_set_name(bufnr, "pi://editor/" .. vim.fn.sha256(tostring(vim.loop.hrtime())):sub(1, 8))
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(prefill, "\n", { plain = true }))
	vim.bo[bufnr].buftype, vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = "nofile", "wipe", false
	vim.cmd("botright new")
	local win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(win, bufnr)
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<C-CR>", "", {
		callback = function()
			local value = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			callback(value)
		end,
		noremap = true,
		silent = true,
	})
	vim.api.nvim_buf_set_keymap(bufnr, "n", "<Esc>", "", {
		callback = function()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			callback(nil)
		end,
		noremap = true,
		silent = true,
	})
	-- The mappings are the only affordance this buffer has, so announce them.
	vim.notify(title .. " — <C-Enter> submits, <Esc> cancels", vim.log.levels.INFO, { title = "pi.nvim" })
	vim.bo[bufnr].modified = false
end

-- Shows text Pi wants staged in the editor. Unlike M.editor this is one-way:
-- there is no callback, so the user keeps or discards the buffer themselves.
function M.open_editor_prefill(text)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(bufnr, "pi://prefill/" .. vim.fn.sha256(tostring(vim.loop.hrtime())):sub(1, 8))
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(text or "", "\n", { plain = true }))
	vim.bo[bufnr].buftype, vim.bo[bufnr].bufhidden, vim.bo[bufnr].swapfile = "nofile", "wipe", false
	vim.cmd("botright new")
	vim.api.nvim_win_set_buf(0, bufnr)
	return bufnr
end

-- The two header lines are load-bearing: pi.init derives the draft index from
-- the cursor line, so item N must stay on line N + 2.
function M.open_draft(root, items)
	local lines = { "Pi context draft — use :PiContextRemove, :PiContextRefresh, or :PiContextClear", "" }
	for index, item in ipairs(items) do
		table.insert(
			lines,
			("%d. %s:%d-%d%s"):format(
				index,
				item.relative_path,
				item.start_line,
				item.end_line,
				item.note ~= "" and " — " .. item.note or ""
			)
		)
	end
	local bufnr = M.open_text("pi://draft/" .. vim.fn.sha256(root):sub(1, 8), table.concat(lines, "\n"))
	-- The draft listing is not a project file, so stamp the root on it; pi.init
	-- reads this back instead of deriving a root from the scratch buffer's name.
	vim.b[bufnr].pi_root = root
	return bufnr
end

function M.open_findings(root, findings)
	local lines, ids_by_line = { "Pi findings", "" }, {}
	for _, finding in ipairs(findings) do
		table.insert(
			lines,
			("%s:%d-%d [%s]%s %s — %s"):format(
				finding.path,
				finding.start_line,
				finding.end_line,
				finding.severity,
				finding.stale and " stale" or "",
				finding.title,
				finding.message
			)
		)
		ids_by_line[#lines] = finding.id
	end
	local bufnr = M.open_text("pi://findings/" .. vim.fn.sha256(root):sub(1, 8), table.concat(lines, "\n"))
	-- pi.findings.at_cursor uses this map so :PiReply works from the listing as
	-- well as from the annotated source line.
	vim.b[bufnr].pi_root, vim.b[bufnr].pi_finding_ids = root, ids_by_line
	return bufnr
end

return M
