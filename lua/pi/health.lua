local M = {}

function M.check()
  vim.health.start("pi.nvim")
  if vim.fn.has("nvim-0.10") == 1 then vim.health.ok("Neovim 0.10+") else vim.health.error("Neovim 0.10+ is required") end
  local executable = require("pi").config.pi_executable
  if vim.fn.executable(executable) == 1 then vim.health.ok("Pi executable: " .. executable) else vim.health.error("Pi executable not found: " .. executable) end
  local extension = require("pi").config.extension_path
  if vim.fn.filereadable(extension) == 1 then vim.health.ok("Companion extension: " .. extension) else vim.health.error("Companion extension missing: " .. extension) end
  local runtime = vim.env.XDG_RUNTIME_DIR or vim.fn.stdpath("state") .. "/run"
  local stat = vim.uv.fs_stat(runtime)
  if stat and stat.type == "directory" then vim.health.ok("Runtime directory: " .. runtime) else vim.health.warn("Runtime directory will be created on demand: " .. runtime) end
end

return M
