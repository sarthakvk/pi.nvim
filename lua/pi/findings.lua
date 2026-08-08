local project = require("pi.project")

local M = { by_root = {}, namespace = vim.api.nvim_create_namespace("pi.nvim.findings") }

local severity = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  information = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

local function entries(root)
  M.by_root[root] = M.by_root[root] or {}
  return M.by_root[root]
end

local function buffer_for(root, relative)
  local path = root .. "/" .. relative
  local bufnr = vim.fn.bufnr(path, false)
  return bufnr > 0 and bufnr or nil
end

local function actual_text(bufnr, first, last)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false), "\n")
end

function M.revalidate(root)
  for _, finding in pairs(entries(root)) do
    local bufnr = buffer_for(root, finding.path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      finding.stale = actual_text(bufnr, finding.start_line, finding.end_line) ~= finding.expected_text
    end
  end
  M.render(root)
end

function M.render(root)
  local per_buffer = {}
  for _, finding in pairs(entries(root)) do
    local bufnr = buffer_for(root, finding.path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      per_buffer[bufnr] = per_buffer[bufnr] or {}
      table.insert(per_buffer[bufnr], {
        lnum = finding.start_line - 1, end_lnum = finding.end_line,
        col = 0, end_col = 0, severity = severity[finding.severity] or vim.diagnostic.severity.INFO,
        source = "pi.nvim", code = finding.id,
        message = (finding.stale and "[stale] " or "") .. finding.title .. ": " .. finding.message,
        user_data = { pi_finding_id = finding.id },
      })
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and project.contains(root, name) then
      vim.diagnostic.set(M.namespace, bufnr, per_buffer[bufnr] or {})
    end
  end
end

function M.publish(root, findings, origin)
  local target = entries(root)
  for _, finding in ipairs(findings) do
    if project.relative(root, root .. "/" .. finding.path) then
      target[finding.id] = vim.tbl_extend("force", { stale = false }, finding, origin or {})
    end
  end
  M.revalidate(root)
end

function M.replace(root, findings, origin)
  M.by_root[root] = {}
  M.publish(root, findings, origin)
end

function M.clear(root, id)
  if id then entries(root)[id] = nil else M.by_root[root] = {} end
  M.render(root)
end

function M.list(root)
  local result = {}
  for _, finding in pairs(entries(root)) do table.insert(result, finding) end
  table.sort(result, function(a, b) return a.path .. a.start_line < b.path .. b.start_line end)
  return result
end

function M.at_cursor(root)
  local bufnr = vim.api.nvim_get_current_buf()
  local listed = vim.b[bufnr].pi_finding_ids
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if listed and listed[line] then return entries(root)[listed[line]] end
  local path = project.relative(root, vim.api.nvim_buf_get_name(bufnr))
  for _, finding in pairs(entries(root)) do
    if finding.path == path and line >= finding.start_line and line <= finding.end_line then return finding end
  end
end

return M
