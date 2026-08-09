-- The per-project context draft for pi.nvim: an ordered, in-memory list of the
-- source excerpts a user collects with the :PiContext* commands, plus the
-- bundling that turns one project's list into the single text message sent to
-- Pi. Items are anchored with extmarks and re-read from disk at send time, so
-- Pi never receives a snapshot that has drifted away from the file on disk.

local context = require("pi.context")

local M = { drafts = {}, namespace = vim.api.nvim_create_namespace("pi.nvim.draft") }

-- Neovim has no UUID primitive; hashing the clock, the RNG, and the process id
-- is enough for ids that only have to be unique across one editor's drafts.
local function new_id()
	return vim.fn.sha256(("%s:%s:%s"):format(vim.loop.hrtime(), math.random(), vim.loop.os_getpid())):sub(1, 32)
end

local function items_for_root(root)
	M.drafts[root] = M.drafts[root] or {}
	return M.drafts[root]
end

function M.items(root)
	return items_for_root(root)
end

function M.add(captured, note)
	local items = items_for_root(captured.root)
	local start_mark = vim.api.nvim_buf_set_extmark(captured.bufnr, M.namespace, captured.start_line - 1, 0, {})
	local end_mark = vim.api.nvim_buf_set_extmark(captured.bufnr, M.namespace, captured.end_line - 1, 0, {})
	local item = {
		id = new_id(),
		kind = captured.kind or "range",
		root = captured.root,
		path = captured.path,
		relative_path = captured.relative_path,
		start_line = captured.start_line,
		end_line = captured.end_line,
		snapshot = captured.text,
		note = note or "",
		bufnr = captured.bufnr,
		start_mark = start_mark,
		end_mark = end_mark,
	}
	table.insert(items, item)
	return item
end

function M.remove(root, index)
	local item = items_for_root(root)[index]
	if not item then
		return nil
	end
	if vim.api.nvim_buf_is_valid(item.bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, item.bufnr, M.namespace, item.start_mark)
		pcall(vim.api.nvim_buf_del_extmark, item.bufnr, M.namespace, item.end_mark)
	end
	table.remove(items_for_root(root), index)
	return item
end

function M.clear(root)
	for index = #items_for_root(root), 1, -1 do
		M.remove(root, index)
	end
end

function M.move(root, from, to)
	local items = items_for_root(root)
	if not items[from] or to < 1 or to > #items then
		return false
	end
	local item = table.remove(items, from)
	table.insert(items, to, item)
	return true
end

local resolve_live_range

function M.refresh(root, index)
	local item = items_for_root(root)[index]
	if not item then
		return nil, "no such draft item"
	end
	local first_line, last_line = resolve_live_range(item)
	if not first_line then
		return nil, last_line
	end
	local captured, err = context.range(item.bufnr, first_line, last_line)
	if not captured then
		return nil, err
	end
	item.start_line, item.end_line = first_line, last_line
	item.snapshot = captured.text
	return item
end

-- Returns where the item's extmarks currently sit, or nil plus a reason the item
-- can no longer be trusted. Callers surface that reason to the user rather than
-- falling back to the snapshot taken when the item was added.
resolve_live_range = function(item)
	if not vim.api.nvim_buf_is_valid(item.bufnr) then
		return nil, "source buffer is no longer available"
	end
	local ok, reason = context.buffer_is_saved(item.bufnr)
	if not ok then
		return nil, reason
	end
	local start_position = vim.api.nvim_buf_get_extmark_by_id(item.bufnr, M.namespace, item.start_mark, {})
	local end_position = vim.api.nvim_buf_get_extmark_by_id(item.bufnr, M.namespace, item.end_mark, {})
	if #start_position == 0 or #end_position == 0 then
		return nil, "source range can no longer be resolved"
	end
	-- Extmark rows are zero-based while draft items are one-based. The ordering
	-- check below is a defensive guard, not a state the marks are known to reach.
	local start_line, end_line = start_position[1] + 1, end_position[1] + 1
	if start_line > end_line then
		return nil, "source range can no longer be resolved"
	end
	return start_line, end_line
end

function M.bundle(root, overall_note, maximum_bytes)
	local contexts = {}
	-- Every excerpt is re-read from disk here rather than taken from item.snapshot,
	-- so the current saved source is sent accurately.
	for _, item in ipairs(items_for_root(root)) do
		local first_line, last_line = resolve_live_range(item)
		if not first_line then
			return nil, last_line
		end
		local text, err = context.read_range(item.path, first_line, last_line)
		if not text then
			return nil, err
		end
		table.insert(contexts, {
			id = item.id,
			kind = item.kind,
			path = item.relative_path,
			start_line = first_line,
			end_line = last_line,
			text = text,
			note = item.note,
		})
	end
	if #contexts == 0 then
		return nil, "the context draft is empty"
	end
	local request = { id = new_id(), root = root, note = overall_note or "", contexts = contexts }
	local encoded = vim.json.encode(request)
	-- Oversized bundles are refused instead of truncated so the user decides what
	-- to drop; failing here leaves the draft untouched for them to narrow.
	if #encoded > maximum_bytes then
		return nil, ("context bundle is %d bytes; limit is %d bytes"):format(#encoded, maximum_bytes)
	end
	return request
end

-- The transport accepts a user message as text, so keep the complete request
-- structured as JSON without adding a textual envelope.
function M.envelope(request)
	local payload = {
		id = request.id,
		root = request.root,
		note = request.note,
		contexts = {},
	}
	for _, item in ipairs(request.contexts) do
		table.insert(payload.contexts, {
			id = item.id,
			kind = item.kind,
			path = item.path,
			start_line = item.start_line,
			end_line = item.end_line,
			text = item.text,
			note = item.note,
		})
	end
	return vim.json.encode(payload)
end

return M
