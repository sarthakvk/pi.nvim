-- Source capture for pi.nvim: turns a buffer or line range into the excerpt
-- record that pi.draft collects and pi.init sends to Pi. Excerpts always come
-- from disk and a buffer only qualifies while it is saved and inside the project
-- root, so Pi sees what is really on the filesystem; the whole-file hash on each
-- record lets a later refresh notice the range went stale.

local project = require("pi.project")

local M = {}

local function read_file(path)
	local file, err = io.open(path, "rb")
	if not file then
		return nil, err
	end
	local text = file:read("*a")
	file:close()
	return text
end

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
		-- Hash the whole file, not just the excerpt, so a later re-read can tell
		-- that the range shifted because of edits made outside it.
		hash = vim.fn.sha256(disk_text),
		bufnr = bufnr,
	}
end

function M.file(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local captured, err = M.range(bufnr, 1, line_count)
	if captured then
		captured.kind = "whole_file"
	end
	return captured, err
end

-- Re-reads a range straight from disk, for callers holding an excerpt that may
-- have drifted. Returns the text plus a fresh whole-file hash, or nil plus a
-- reason.
function M.read_range(path, first_line, last_line)
	local disk_text, err = read_file(path)
	if not disk_text then
		return nil, err
	end
	local lines = split_lines(disk_text)
	if first_line < 1 or last_line < first_line or last_line > #lines then
		return nil, "range no longer exists"
	end
	return table.concat(vim.list_slice(lines, first_line, last_line), "\n"), vim.fn.sha256(disk_text)
end

return M
