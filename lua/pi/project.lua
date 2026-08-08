local M = {}

local function realpath(path)
  return vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

function M.root(path)
  path = realpath(path or vim.fn.getcwd())
  local directory = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
  local result = vim.fn.system({ "git", "-C", directory, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 then
    return realpath(vim.trim(result))
  end
  return realpath(directory)
end

function M.relative(root, path)
  path = realpath(path)
  if path == root then
    return "."
  end
  local prefix = root .. "/"
  if path:sub(1, #prefix) ~= prefix then
    return nil
  end
  return path:sub(#prefix + 1)
end

function M.contains(root, path)
  return M.relative(root, path) ~= nil
end

function M.state_file(root)
  local digest = vim.fn.sha256(root):sub(1, 16)
  local directory = vim.fn.stdpath("state") .. "/pi.nvim"
  vim.fn.mkdir(directory, "p", "0700")
  return directory .. "/" .. digest .. ".json"
end

return M
