import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";

const root = new URL("../..", import.meta.url).pathname;

test("companion extension loads in Pi RPC mode", async () => {
  const child = spawn("pi", ["--mode", "rpc", "--extension", "./pi-extension/index.ts"], {
    cwd: root, stdio: ["pipe", "pipe", "pipe"],
  });
  let output = "";
  let errors = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { errors += chunk; });
  child.stdin.write('{"id":"state","type":"get_state"}\n');
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timed out: ${errors}`)), 15_000);
    const poll = setInterval(() => {
      const line = output.split("\n").find((entry) => entry.includes('"id":"state"'));
      if (!line) return;
      clearInterval(poll); clearTimeout(timer);
      const response = JSON.parse(line);
      assert.equal(response.type, "response");
      assert.equal(response.success, true);
      resolve();
    }, 10);
  });
  child.kill("SIGTERM");
});
