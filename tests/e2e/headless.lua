vim.opt.runtimepath:prepend(vim.fn.getcwd())
local pi = require("pi")
pi.setup({ fallback = "headless" })

local root = assert(arg[1], "temporary project root required")
local sample = root .. "/sample.js"
local session = require("pi.session")
local settled, failure, finding_count = 0, nil, 0
local current = session.get(root)
current.on_settled = function() settled = settled + 1 end
current.on_findings = function(items) finding_count = finding_count + #items end

local function wait_for(predicate, message)
  assert(vim.wait(120000, function() return predicate() or failure end, 50), failure or message)
  assert(not failure, failure)
end

session.start_headless(root, pi.config, function(target, err)
  if not target then failure = err; return end
  target.transport:send([[This is a bridge end-to-end test. Use the write or edit tool to change sample.js so its complete content is exactly `const answer = 43;` followed by a newline. Then call nvim_publish_findings once with a hint finding for sample.js lines 1-1, request_id "e2e", title "Changed answer", message "The test edit completed", and expected_text exactly `const answer = 43;`. Finally reply with exactly: pi-nvim-e2e-ok]], nil, function(_, send_err)
    failure = send_err
  end)
end)

wait_for(function() return settled >= 1 end, "Pi did not settle after the edit")
assert(table.concat(vim.fn.readfile(sample), "\n") == "const answer = 43;", "Pi did not edit the fixture")
assert(session.get(root).transport.changed_paths["sample.js"], "Pi did not report the known edit")
assert(finding_count > 0, "Pi did not publish a finding")
local first_session = session.get(root).session_file
assert(first_session and vim.fn.filereadable(first_session) == 1, "headless session was not persisted")
assert(session.stop(root))
wait_for(function() return session.get(root).mode == nil end, "Pi worker did not stop")

session.start_headless(root, pi.config, function(target, err)
  if not target then failure = err; return end
  target.transport:send("Reply with exactly: pi-nvim-resume-ok", nil, function(_, send_err)
    failure = send_err
  end)
end)
wait_for(function() return settled >= 2 end, "resumed Pi did not settle")
local resumed = session.get(root)
assert(resumed.session_file == first_session, "headless worker did not resume the persisted session")
assert(resumed.transport.latest_response:find("pi%-nvim%-resume%-ok"), "resumed session response was missing")
assert(session.stop(root))
print("headless Pi edit, findings, and resume end-to-end passed")
