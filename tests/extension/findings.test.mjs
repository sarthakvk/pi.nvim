import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";

import { createFinding } from "../../pi-extension/protocol.ts";

function fixture() {
  const root = mkdtempSync(join(tmpdir(), "pi-nvim-findings-"));
  writeFileSync(
    join(root, "sample.ts"),
    "const first = 1;\nconst second = 2;\n",
  );
  return root;
}

test("creates source anchors and metadata from a small model input", (t) => {
  const root = fixture();
  t.after(() => rmSync(root, { recursive: true, force: true }));

  const finding = createFinding(root, "request-1", {
    path: "sample.ts",
    start_line: 1,
    end_line: 2,
    severity: "warning",
    diagnostic: "These constants should be combined.",
  });

  assert.equal(finding.request_id, "request-1");
  assert.equal(finding.path, "sample.ts");
  assert.equal(finding.severity, "warning");
  assert.equal(finding.message, "These constants should be combined.");
  assert.equal(finding.expected_text, "const first = 1;\nconst second = 2;");
  assert.ok(finding.id);
});

test("requires the model to choose a valid severity", (t) => {
  const root = fixture();
  t.after(() => rmSync(root, { recursive: true, force: true }));

  assert.throws(
    () =>
      createFinding(root, "request-1", {
        path: "sample.ts",
        start_line: 1,
        end_line: 1,
        diagnostic: "A diagnostic without a severity.",
      }),
    /invalid finding severity/,
  );
});
