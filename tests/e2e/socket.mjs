// End-to-end check of the opt-in bridge socket, from the Neovim side's point of
// view but without Neovim: it starts a real interactive Pi in a throwaway Git
// project, opts in with /nvim-bridge enable, then finds the descriptor and
// completes the handshake exactly as lua/pi/transport/socket.lua would.
//
// This covers what the Lua tests cannot: that the descriptor really appears in
// the runtime directory, and that the socket answers a hello for the right root
// and protocol version. It needs a working `pi` on PATH.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const project = mkdtempSync(join(tmpdir(), "pi-nvim-socket-"));
execFileSync("git", ["init", "-q"], { cwd: project });
const extension = new URL("../../pi-extension/index.ts", import.meta.url)
  .pathname;
// Interactive Pi needs a terminal, so `script` supplies a pty; a plain pipe
// would leave it in non-interactive mode and no slash command would run.
const child = spawn(
  "script",
  ["-qfec", `pi --extension ${JSON.stringify(extension)}`, "/dev/null"],
  {
    cwd: project,
    stdio: ["pipe", "pipe", "pipe"],
  },
);
let output = "";
child.stdout.on("data", (chunk) => {
  output += chunk;
});

// Pi's output is the only progress signal available, so the whole test is
// written as polls with a deadline; the tail of the output goes into failures
// because it is usually the reason.
function waitFor(predicate, message) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15_000;
    const timer = setInterval(() => {
      if (predicate()) {
        clearInterval(timer);
        resolve();
      } else if (Date.now() > deadline) {
        clearInterval(timer);
        reject(new Error(`${message}\n${output.slice(-2000)}`));
      }
    }, 20);
  });
}

try {
  await waitFor(
    () => output.includes("gpt-5.6"),
    "interactive Pi did not start",
  );
  child.stdin.write("/nvim-bridge enable\r");
  // Resolved the same way the extension does, so the test looks where a real
  // session would actually have published itself.
  const stateHome =
    process.env.XDG_STATE_HOME || join(process.env.HOME, ".local", "state");
  const runtime = join(
    process.env.XDG_RUNTIME_DIR || join(stateHome, "nvim", "run"),
    "pi.nvim",
  );
  let descriptor;
  // Other sessions may have left descriptors behind, so match on this project.
  await waitFor(() => {
    descriptor = readdirSync(runtime)
      .filter((name) => name.endsWith(".json"))
      .map((name) => ({
        name,
        value: JSON.parse(readFileSync(join(runtime, name), "utf8")),
      }))
      .find(({ value }) => value.root === project);
    return Boolean(descriptor);
  }, "bridge descriptor was not created");
  const socket = createConnection(descriptor.value.socket_path);
  let received = "";
  socket.on("data", (chunk) => {
    received += chunk;
  });
  await new Promise((resolve, reject) =>
    socket.once("connect", resolve).once("error", reject),
  );
  socket.write(
    JSON.stringify({ id: "hello", type: "hello", version: 1, root: project }) +
      "\n",
  );
  await waitFor(
    () => received.includes('"id":"hello"'),
    "bridge handshake did not respond",
  );
  const response = JSON.parse(
    received.split("\n").find((line) => line.includes('"id":"hello"')),
  );
  assert.equal(response.data.root, project);
  assert.equal(response.data.version, 1);
  socket.destroy();
  // Killing Pi below skips its shutdown hook, so clean up what it published.
  rmSync(join(runtime, descriptor.name), { force: true });
  rmSync(descriptor.value.socket_path, { force: true });
  console.log("socket bridge end-to-end passed");
} finally {
  child.kill("SIGTERM");
  rmSync(project, { recursive: true, force: true });
}
