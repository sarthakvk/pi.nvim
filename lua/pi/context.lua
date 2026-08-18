-- Source capture for pi.nvim, in two forms. An excerpt (M.range, M.file) quotes
-- the source into the record pi.draft collects; it always comes from disk and a
-- buffer only qualifies while it is saved and inside the project root, so Pi
-- sees what is really on the filesystem. A pointer (M.pointer) quotes nothing
-- and only says where the user is, which is why it still works for the buffers
-- an excerpt has to refuse.

local project = require("pi.project")

local M = {}

---@param path string
---@return string? text, string? err
local function read_file(path)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, err
	end
	local text = file:read("*a")
	file:close()
	-- io.open succeeds on a directory but reading one yields nil with no error, so
	-- supply the reason here; every caller concatenates it into a message.
	if not text then
		return nil, path .. " is not a readable file"
	end
	return text
end

---@param text string
---@return string[]
local function split_lines(text)
	local lines = vim.split(text, "\n", { plain = true })
	-- A trailing newline splits into a phantom empty last line; dropping it keeps
	-- indices in step with the line numbers Neovim reports for the same file.
	if #lines > 0 and lines[#lines] == "" then
		table.remove(lines)
	end
	return lines
end

-- Returns true plus the file's path, or false plus the reason the buffer cannot
-- be captured. A buffer only qualifies while what is on disk is byte-identical
-- to what the user is looking at.
---@param bufnr integer
---@return boolean saved
---@return string path_or_reason The file's path when saved, otherwise why not.
function M.buffer_is_saved(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "buffer is no longer valid"
	end
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false, "buffer has no file"
	end
	if vim.bo[bufnr].modified then
		return false, "buffer has unsaved changes"
	end
	local disk_text, err = read_file(path)
	if not disk_text then
		return false, "cannot read saved file: " .. err
	end
	local buffer_text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	-- Buffer lines carry no trailing newline and no carriage returns, so restore
	-- the newline and strip CRLF from disk before comparing; otherwise every
	-- newline-terminated or DOS-line-ending file would look externally modified.
	if disk_text:sub(-1) == "\n" then
		buffer_text = buffer_text .. "\n"
	end
	if buffer_text ~= disk_text:gsub("\r\n", "\n") then
		return false, "file changed externally; reload it before sending"
	end
	return true, path
end

-- Captures a line range from a saved buffer, reading the text from disk.
---@param bufnr integer
---@param first_line integer? One-based, inclusive; defaults to the first line.
---@param last_line integer? One-based, inclusive; defaults to the last line.
---@return pi.Capture? captured, string? err
function M.range(bufnr, first_line, last_line)
	local ok, path_or_reason = M.buffer_is_saved(bufnr)
	if not ok then
		return nil, path_or_reason
	end
	local path = vim.uv.fs_realpath(path_or_reason) or path_or_reason
	local root = project.root(path)
	local relative = project.relative(root, path)
	if not relative then
		return nil, "file is outside the project root"
	end
	local disk_text, err = read_file(path)
	if not disk_text then
		return nil, err
	end
	local lines = split_lines(disk_text)
	first_line, last_line = first_line or 1, last_line or #lines
	if first_line < 1 or last_line < first_line or last_line > #lines then
		return nil, "invalid source range"
	end
	return {
		root = root,
		path = path,
		relative_path = relative,
		start_line = first_line,
		end_line = last_line,
		text = table.concat(vim.list_slice(lines, first_line, last_line), "\n"),
		bufnr = bufnr,
	}
end

-- A pointer names where the user is without carrying any source: it is a path,
-- plus the range they selected or the line they are on, and Pi reads the file
-- itself. Nothing is read from disk or compared against it here, which is what
-- lets a pointer describe the buffers M.range must refuse -- empty, never
-- written, or modified -- where there is no trustworthy excerpt but the location
-- still matters. The buffer's state is reported rather than judged, so the
-- caller can warn that Pi will see the saved file.
---@param bufnr integer
---@param first_line integer? One-based, inclusive; with last_line, a selection.
---@param last_line integer? One-based, inclusive.
---@return pi.Pointer? pointer
---@return string? reason Why there is no pointer, for the caller to report.
function M.pointer(bufnr, first_line, last_line)
	-- Every Neovim buffer API takes 0 for the current buffer, so callers pass it;
	-- resolve it up front because the cursor lookup below compares handles.
	if bufnr == 0 then
		bufnr = vim.api.nvim_get_current_buf()
	end
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "buffer is no longer valid"
	end
	-- Anything but a normal buffer is some plugin's rendering -- a file listing, a
	-- Git view, a URI -- whose name is not a path Pi could open.
	if vim.bo[bufnr].buftype ~= "" then
		return nil, "buffer is not a file"
	end
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" then
		return nil, "buffer has no file"
	end
	local path = vim.uv.fs_realpath(name) or name
	local stat = vim.uv.fs_stat(path)
	if stat and stat.type ~= "file" then
		return nil, "buffer is a " .. stat.type .. ", not a file"
	end
	-- A file the user has not written yet has nothing to stat, so the directory
	-- that would hold it has to be real. Excerpts get this check for free by
	-- reading the file; a pointer reads nothing, and without it a made-up buffer
	-- name would become a made-up project root.
	if not stat and vim.fn.isdirectory(vim.fn.fnamemodify(path, ":h")) == 0 then
		return nil, "buffer does not name a file on disk"
	end
	local root = project.root(path)
	local relative = project.relative(root, path)
	if not relative then
		return nil, "file is outside the project root"
	end
	local pointer = {
		root = root,
		path = path,
		relative_path = relative,
		modified = vim.bo[bufnr].modified,
		exists = stat ~= nil,
	}
	if first_line and last_line then
		pointer.start_line, pointer.end_line = first_line, last_line
	elseif bufnr == vim.api.nvim_get_current_buf() then
		-- Only the current buffer has an unambiguous cursor; for any other the
		-- pointer is the file alone.
		pointer.cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	end
	return pointer
end

---@param bufnr integer
---@return pi.Capture? captured, string? err
function M.file(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local captured, err = M.range(bufnr, 1, line_count)
	if captured then
		captured.kind = "whole_file"
	end
	return captured, err
end

-- Re-reads a range straight from disk, for callers holding an excerpt that may
-- have drifted. Returns the text, or nil plus a reason.
---@param path string Absolute path.
---@param first_line integer One-based, inclusive.
---@param last_line integer One-based, inclusive.
---@return string? text, string? err
function M.read_range(path, first_line, last_line)
	local disk_text, err = read_file(path)
	if not disk_text then
		return nil, err
	end
	local lines = split_lines(disk_text)
	if first_line < 1 or last_line < first_line or last_line > #lines then
		return nil, "range no longer exists"
	end
	return table.concat(vim.list_slice(lines, first_line, last_line), "\n")
end

return M
