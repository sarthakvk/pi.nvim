// Smoke test for the companion extension: `pi --mode rpc` must load
// pi-extension/index.ts and stay usable. It is deliberately shallow — a
// successful get_state response proves the extension parsed, registered its
// command and tool without collision, and did not throw at session start, which
// is the failure mode most likely to slip past the Lua tests. No model is
// contacted, so this runs offline.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

const packageRoot = new URL("../..", import.meta.url).pathname;

test("companion extension loads in Pi RPC mode", async () => {
  const child = spawn(
    "pi",
    ["--mode", "rpc", "--extension", "./pi-extension/index.ts"],
    {
      cwd: packageRoot,
      stdio: ["pipe", "pipe", "pipe"],
    },
  );
  let output = "";
  let stderrText = "";
  child.stdout.on("data", (chunk) => {
    output += chunk;
  });
  // Kept only to make a timeout report why Pi never answered.
  child.stderr.on("data", (chunk) => {
    stderrText += chunk;
  });
  child.stdin.write('{"id":"state","type":"get_state"}\n');
  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`timed out: ${stderrText}`)),
      15_000,
    );
    // Responses share the stream with startup output, so poll for the line
    // carrying our request id rather than assuming it arrives first.
    const poll = setInterval(() => {
      const line = output
        .split("\n")
        .find((entry) => entry.includes('"id":"state"'));
      if (!line) return;
      clearInterval(poll);
      clearTimeout(timer);
      const response = JSON.parse(line);
      assert.equal(response.type, "response");
      assert.equal(response.success, true);
      resolve();
    }, 10);
  });
  child.kill("SIGTERM");
});
