-- Project boundary rules for pi.nvim: which directory counts as a project root,
-- whether a path lives inside one, and where that project's state file goes.
-- Containment is decided by string prefix, so every path is resolved through
-- realpath first; otherwise a symlink pointing out of the tree would still look
-- like it was inside, and the bridge would ship files the user never opted into.

local M = {}

local function realpath(path)
  -- fs_realpath fails for paths that do not exist yet, so fall back to plain
  -- absolute expansion rather than losing the path entirely.
  return vim.uv.fs_realpath(path) or vim.fn.fnamemodify(path, ":p")
end

function M.root(path)
  path = realpath(path or vim.fn.getcwd())
  local directory = vim.fn.isdirectory(path) == 1 and path or vim.fn.fnamemodify(path, ":h")
  local toplevel = vim.fn.system({ "git", "-C", directory, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 then
    return realpath(vim.trim(toplevel))
  end
  -- Outside a Git worktree the containing directory is the whole project, which
  -- keeps single-file and non-Git work usable without widening the boundary.
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
  -- Roots are absolute paths and cannot be used as file names, so key the state
  -- file by a digest of the root instead.
  local digest = vim.fn.sha256(root):sub(1, 16)
  local directory = vim.fn.stdpath("state") .. "/pi.nvim"
  vim.fn.mkdir(directory, "p", "0700")
  return directory .. "/" .. digest .. ".json"
end

return M
