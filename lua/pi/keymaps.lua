-- User-facing mappings installed by setup(). Actions use suffixes so changing
-- the prefix keeps the Pi commands together; any action can be disabled with
-- false. WhichKey metadata is optional and does not make WhichKey a dependency.

local M = {}

M.defaults = {
	prefix = "<leader>p",
	add_context = "a",
	send_current = "s",
	send_draft = "S",
	show_context = "v",
	remove_context = "d",
	refresh_context = "r",
	move_context = "m",
	clear_context = "c",
	attach = "A",
	sessions = "l",
	findings = "f",
	reply = "R",
	clear_findings = "C",
	response = "o",
	status = "i",
	stop = "q",
}

M.which_key_defaults = {
	group = "pi",
	icon = { icon = " ", color = "green" },
}

local actions = {
	{ name = "add_context", rhs = ":PiContextAdd<cr>", mode = { "n", "x" }, desc = "Pi: Add Context" },
	{ name = "send_current", rhs = ":PiSend<cr>", mode = { "n", "x" }, desc = "Pi: Send Current Context" },
	{ name = "send_draft", rhs = "<cmd>PiContextSend<cr>", mode = "n", desc = "Pi: Send Context Draft" },
	{ name = "show_context", rhs = "<cmd>PiContextShow<cr>", mode = "n", desc = "Pi: View Context Draft" },
	{ name = "remove_context", rhs = "<cmd>PiContextRemove<cr>", mode = "n", desc = "Pi: Delete Context Item" },
	{ name = "refresh_context", rhs = "<cmd>PiContextRefresh<cr>", mode = "n", desc = "Pi: Refresh Context Item" },
	{ name = "move_context", rhs = ":PiContextMove ", mode = "n", desc = "Pi: Move Context Item" },
	{ name = "clear_context", rhs = "<cmd>PiContextClear<cr>", mode = "n", desc = "Pi: Clear Context Draft" },
	{ name = "attach", rhs = "<cmd>PiAttach<cr>", mode = "n", desc = "Pi: Attach Session" },
	{ name = "sessions", rhs = "<cmd>PiSessions<cr>", mode = "n", desc = "Pi: List Sessions" },
	{ name = "findings", rhs = "<cmd>PiFindings<cr>", mode = "n", desc = "Pi: Show Findings" },
	{ name = "reply", rhs = "<cmd>PiReply<cr>", mode = "n", desc = "Pi: Reply to Finding" },
	{ name = "clear_findings", rhs = "<cmd>PiClear<cr>", mode = "n", desc = "Pi: Clear Findings" },
	{ name = "response", rhs = "<cmd>PiResponse<cr>", mode = "n", desc = "Pi: Open Latest Response" },
	{ name = "status", rhs = "<cmd>PiStatus<cr>", mode = "n", desc = "Pi: Inspect Status" },
	{ name = "stop", rhs = "<cmd>PiStop<cr>", mode = "n", desc = "Pi: Quit Headless Worker" },
}

---@type { lhs: string, mode: string }[]
local installed = {}

local function clear()
	for _, mapping in ipairs(installed) do
		pcall(vim.keymap.del, mapping.mode, mapping.lhs)
	end
	installed = {}
end

---@param config pi.Keymaps|false
---@param which_key pi.WhichKeyConfig|false
local function register_which_key(config, which_key)
	if type(config) ~= "table" or type(which_key) ~= "table" then
		return false
	end
	local ok, wk = pcall(require, "which-key")
	if not ok then
		return false
	end
	local spec = {
		{ config.prefix, group = which_key.group, icon = which_key.icon, mode = { "n", "x" } },
	}
	for _, action in ipairs(actions) do
		local suffix = config[action.name]
		if suffix then
			table.insert(spec, { config.prefix .. suffix, icon = which_key.icon, mode = action.mode })
		end
	end
	wk.add(spec)
	return true
end

---@param config pi.Keymaps|false
---@param which_key pi.WhichKeyConfig|false
---@param group integer Autocommand group shared with the rest of pi.nvim.
function M.setup(config, which_key, group)
	clear()
	if type(config) ~= "table" then
		return
	end
	for _, action in ipairs(actions) do
		local suffix = config[action.name]
		if suffix then
			local lhs = config.prefix .. suffix
			vim.keymap.set(action.mode, lhs, action.rhs, { desc = action.desc })
			for _, mode in ipairs(type(action.mode) == "table" and action.mode or { action.mode }) do
				table.insert(installed, { lhs = lhs, mode = mode })
			end
		end
	end

	if which_key ~= false and not register_which_key(config, which_key) then
		local registered = false
		local function register()
			if not registered then
				registered = register_which_key(config, which_key)
			end
		end
		vim.api.nvim_create_autocmd("VimEnter", {
			group = group,
			once = true,
			callback = register,
		})
		vim.api.nvim_create_autocmd("User", {
			group = group,
			pattern = "VeryLazy",
			once = true,
			callback = register,
		})
	end
end

return M
