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

test("companion extension loads and Pi can replace its RPC session", async (t) => {
  const child = spawn(
    "pi",
    ["-ne", "--mode", "rpc", "--extension", "./pi-extension/index.ts"],
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
  t.after(() => child.kill("SIGTERM"));

  const responseFor = (id) =>
    new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`timed out: ${stderrText}`)),
        15_000,
      );
      // Responses share the stream with startup output, so poll for the line
      // carrying our request id rather than assuming it arrives first.
      const poll = setInterval(() => {
        const line = output
          .split("\n")
          .find((entry) => entry.includes(`"id":"${id}"`));
        if (!line) return;
        clearInterval(poll);
        clearTimeout(timer);
        const response = JSON.parse(line);
        assert.equal(response.type, "response");
        assert.equal(response.success, true);
        resolve(response);
      }, 10);
    });

  child.stdin.write('{"id":"before","type":"get_state"}\n');
  const before = await responseFor("before");
  child.stdin.write('{"id":"new","type":"new_session"}\n');
  const replacement = await responseFor("new");
  assert.equal(replacement.data.cancelled, false);
  child.stdin.write('{"id":"after","type":"get_state"}\n');
  const after = await responseFor("after");
  assert.notEqual(after.data.sessionId, before.data.sessionId);
});
