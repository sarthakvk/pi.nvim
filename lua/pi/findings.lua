-- Pi's review findings, held per project root and surfaced as Neovim
-- diagnostics. Findings are editor-only annotations: nothing here writes to a
-- source file. Each finding carries the exact text it was written against, so
-- once the user edits that range the finding is marked stale rather than
-- silently pointing at unrelated lines.

local project = require("pi.project")

local M = { by_root = {}, namespace = vim.api.nvim_create_namespace("pi.nvim.findings") }

local severity = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  information = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

local function findings_for_root(root)
  M.by_root[root] = M.by_root[root] or {}
  return M.by_root[root]
end

local function bufnr_for(root, relative_path)
  local path = root .. "/" .. relative_path
  local bufnr = vim.fn.bufnr(path, false)
  return bufnr > 0 and bufnr or nil
end

local function buffer_text(bufnr, first_line, last_line)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, first_line - 1, last_line, false), "\n")
end

function M.revalidate(root)
  for _, finding in pairs(findings_for_root(root)) do
    local bufnr = bufnr_for(root, finding.path)
    -- Only loaded buffers can be compared. An unloaded file keeps whatever
    -- staleness it last had rather than being guessed at from disk.
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      finding.stale = buffer_text(bufnr, finding.start_line, finding.end_line) ~= finding.expected_text
    end
  end
  M.render(root)
end

function M.render(root)
  local diagnostics_by_buffer = {}
  for _, finding in pairs(findings_for_root(root)) do
    local bufnr = bufnr_for(root, finding.path)
    if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
      diagnostics_by_buffer[bufnr] = diagnostics_by_buffer[bufnr] or {}
      table.insert(diagnostics_by_buffer[bufnr], {
        lnum = finding.start_line - 1, end_lnum = finding.end_line,
        col = 0, end_col = 0, severity = severity[finding.severity] or vim.diagnostic.severity.INFO,
        source = "pi.nvim", code = finding.id,
        message = (finding.stale and "[stale] " or "") .. finding.title .. ": " .. finding.message,
        user_data = { pi_finding_id = finding.id },
      })
    end
  end
  -- Every project buffer is set, including the ones with no findings: passing an
  -- empty list is what clears annotations that this pass no longer produces.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name ~= "" and project.contains(root, name) then
      vim.diagnostic.set(M.namespace, bufnr, diagnostics_by_buffer[bufnr] or {})
    end
  end
end

function M.publish(root, findings, origin)
  local store = findings_for_root(root)
  for _, finding in ipairs(findings) do
    -- Findings arrive from a model and can name any path, so drop anything that
    -- resolves outside the project instead of annotating a foreign file.
    if project.relative(root, root .. "/" .. finding.path) then
      store[finding.id] = vim.tbl_extend("force", { stale = false }, finding, origin or {})
    end
  end
  M.revalidate(root)
end

-- Used for a full snapshot from Pi, where absent findings mean cleared rather
-- than unchanged.
function M.replace(root, findings, origin)
  M.by_root[root] = {}
  M.publish(root, findings, origin)
end

function M.clear(root, id)
  if id then findings_for_root(root)[id] = nil else M.by_root[root] = {} end
  M.render(root)
end

function M.list(root)
  local result = {}
  for _, finding in pairs(findings_for_root(root)) do table.insert(result, finding) end
  table.sort(result, function(a, b) return a.path .. a.start_line < b.path .. b.start_line end)
  return result
end

-- Resolves the finding the user means: the line under the cursor in the
-- :PiFindings listing, or failing that a finding whose range covers the cursor
-- in a source buffer.
function M.at_cursor(root)
  local bufnr = vim.api.nvim_get_current_buf()
  local ids_by_line = vim.b[bufnr].pi_finding_ids
  local line = vim.api.nvim_win_get_cursor(0)[1]
  if ids_by_line and ids_by_line[line] then return findings_for_root(root)[ids_by_line[line]] end
  local path = project.relative(root, vim.api.nvim_buf_get_name(bufnr))
  for _, finding in pairs(findings_for_root(root)) do
    if finding.path == path and line >= finding.start_line and line <= finding.end_line then return finding end
  end
end

return M
