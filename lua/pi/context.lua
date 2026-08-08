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
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

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
  local disk, err = read_file(path)
  if not disk then
    return false, "cannot read saved file: " .. err
  end
  local buffer = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if disk:sub(-1) == "\n" then
    buffer = buffer .. "\n"
  end
  if buffer ~= disk:gsub("\r\n", "\n") then
    return false, "file changed externally; reload it before sending"
  end
  return true, path
end

function M.range(bufnr, first, last)
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
  local disk, err = read_file(path)
  if not disk then
    return nil, err
  end
  local lines = split_lines(disk)
  first, last = first or 1, last or #lines
  if first < 1 or last < first or last > #lines then
    return nil, "invalid source range"
  end
  return {
    root = root,
    path = path,
    relative_path = relative,
    start_line = first,
    end_line = last,
    text = table.concat(vim.list_slice(lines, first, last), "\n"),
    hash = vim.fn.sha256(disk),
    bufnr = bufnr,
  }
end

function M.file(bufnr)
  local lines = vim.api.nvim_buf_line_count(bufnr)
  local captured, err = M.range(bufnr, 1, lines)
  if captured then captured.kind = "whole_file" end
  return captured, err
end

function M.read_range(path, first, last)
  local disk, err = read_file(path)
  if not disk then
    return nil, err
  end
  local lines = split_lines(disk)
  if first < 1 or last < first or last > #lines then
    return nil, "range no longer exists"
  end
  return table.concat(vim.list_slice(lines, first, last), "\n"), vim.fn.sha256(disk)
end

return M
