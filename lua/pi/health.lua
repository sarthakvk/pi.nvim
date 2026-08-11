-- `:checkhealth pi` report. Every check here covers a local prerequisite the
-- bridge cannot recover from on its own: the Neovim version the plugin's APIs
-- need, the Pi executable and companion extension it spawns, and the runtime
-- directory where opted-in terminal sessions advertise themselves.

local M = {}

function M.check()
	vim.health.start("pi.nvim")
	if vim.fn.has("nvim-0.10") == 1 then
		vim.health.ok("Neovim 0.10+")
	else
		vim.health.error("Neovim 0.10+ is required")
	end
	local executable = require("pi").config.pi_executable
	if vim.fn.executable(executable) == 1 then
		vim.health.ok("Pi executable: " .. executable)
	else
		vim.health.error("Pi executable not found: " .. executable)
	end
	local extension = require("pi").config.extension_path
	if vim.fn.filereadable(extension) == 1 then
		vim.health.ok("Companion extension: " .. extension)
	else
		vim.health.error("Companion extension missing: " .. extension)
	end
	local runtime = require("pi.session").runtime_dir_path()
	local stat = vim.uv.fs_stat(runtime)
	-- A missing runtime directory is only a warning: it is created when a Pi
	-- session first opts in, so its absence just means none has yet.
	if stat and stat.type == "directory" then
		vim.health.ok("Runtime directory: " .. runtime)
	else
		vim.health.warn("Runtime directory will be created on demand: " .. runtime)
	end
end

return M
