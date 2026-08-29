// End-to-end check of the opt-in bridge socket, from the Neovim side's point of
// view but without Neovim: it starts a real interactive Pi in a throwaway Git
// project, opts in with /nvim-bridge, then finds the descriptor and completes the
// handshake exactly as lua/pi/transport/socket.lua would.
//
// This covers what the Lua tests cannot: that the descriptor really appears in
// the runtime directory, and that the socket answers a hello for the right root
// and protocol version. It needs a working `pi` on PATH.

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import {
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
} from "node:fs";
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
  ["-qfec", `pi -ne --extension ${JSON.stringify(extension)}`, "/dev/null"],
  {
    cwd: project,
    stdio: ["pipe", "pipe", "pipe"],
  },
);
let output = "";
child.stdout.on("data", (chunk) => {
  output += chunk;
});

// The pty fills the output with terminal control sequences, so anything matched
// against it is matched against the stripped text.
const CONTROL_SEQUENCES =
  /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]/g;
function stripped() {
  return output.replace(CONTROL_SEQUENCES, "");
}
// Pi prints its name and version before it accepts input, and that banner is
// the same whatever model the machine running this test has configured.
function piStarted() {
  return /\bpi\s+v\d+\.\d+\.\d+/.test(stripped());
}

// Pi's output is the only progress signal available, so the whole test is
// written as polls with a deadline; the tail of the output goes into failures
// because it is usually the reason.
function waitFor(predicate, message) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 15_000;
    const timer = setInterval(() => {
      let satisfied;
      try {
        satisfied = predicate();
      } catch (error) {
        // A throw out of a timer callback would skip the cleanup in `finally`
        // and leave the Pi child running, so it fails the wait instead.
        clearInterval(timer);
        return reject(error);
      }
      if (satisfied) {
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
  await waitFor(piStarted, "interactive Pi did not start");
  child.stdin.write("/nvim-bridge\r");
  // Resolved the same way the extension does, so the test looks where a real
  // session would actually have published itself.
  const stateHome =
    process.env.XDG_STATE_HOME || join(process.env.HOME, ".local", "state");
  const runtime = join(
    process.env.XDG_RUNTIME_DIR || join(stateHome, "nvim", "run"),
    "pi.nvim",
  );
  // Every descriptor this project has published. Other sessions share the
  // runtime directory, so this matches on the project; a descriptor being
  // rewritten by one of them is skipped rather than thrown out of a poll.
  function projectDescriptors() {
    return readdirSync(runtime)
      .filter((name) => name.endsWith(".json"))
      .flatMap((name) => {
        try {
          return [
            {
              name,
              value: JSON.parse(readFileSync(join(runtime, name), "utf8")),
            },
          ];
        } catch {
          return [];
        }
      })
      .filter(({ value }) => value.root === project);
  }
  // The bridge serves one session at a time, so this project should never have
  // more than one; `notSessionId` makes a poll wait for the replacement rather
  // than settling for a stale descriptor that should have been removed.
  function findDescriptor(notSessionId) {
    return projectDescriptors().find(
      ({ value }) => value.session_id !== notSessionId,
    );
  }
  // Connects and completes the handshake exactly as the Lua transport does,
  // returning the descriptor the bridge answered with.
  async function handshake(socketPath, id) {
    const socket = createConnection(socketPath);
    let received = "";
    socket.on("data", (chunk) => {
      received += chunk;
    });
    await new Promise((resolve, reject) =>
      socket.once("connect", resolve).once("error", reject),
    );
    socket.write(
      JSON.stringify({ id, type: "hello", version: 1, root: project }) + "\n",
    );
    await waitFor(
      () => received.includes(`"id":"${id}"`),
      "bridge handshake did not respond",
    );
    const response = JSON.parse(
      received.split("\n").find((line) => line.includes(`"id":"${id}"`)),
    );
    socket.destroy();
    return response.data;
  }
  let descriptor;
  await waitFor(() => {
    descriptor = findDescriptor();
    return Boolean(descriptor);
  }, "bridge descriptor was not created");
  const response = await handshake(descriptor.value.socket_path, "hello");
  assert.equal(response.root, project);
  assert.equal(response.version, 1);

  // A client that closes right after writing leaves its last message without a
  // trailing newline; the bridge must still serve it.
  const halfOpen = createConnection({
    path: descriptor.value.socket_path,
    allowHalfOpen: true,
  });
  let halfOpenReceived = "";
  halfOpen.on("data", (chunk) => {
    halfOpenReceived += chunk;
  });
  await new Promise((resolve, reject) =>
    halfOpen.once("connect", resolve).once("error", reject),
  );
  halfOpen.end(
    JSON.stringify({
      id: "unterminated",
      type: "hello",
      version: 1,
      root: project,
    }),
  );
  await waitFor(
    () => halfOpenReceived.includes('"id":"unterminated"'),
    "bridge dropped a message that arrived without a trailing newline",
  );
  halfOpen.destroy();

  // Clearing the conversation is not a request to hide from Neovim: /new
  // replaces the session, and the bridge has to follow it under the new
  // session's name rather than leaving the project unreachable.
  child.stdin.write("/new\r");
  let replacement;
  await waitFor(() => {
    replacement = findDescriptor(descriptor.value.session_id);
    return Boolean(replacement);
  }, "bridge did not follow the session across /new");
  assert.ok(
    !existsSync(join(runtime, descriptor.name)),
    "the replaced session's descriptor was left behind",
  );
  const renewed = await handshake(replacement.value.socket_path, "renewed");
  assert.equal(renewed.root, project);
  assert.equal(renewed.session_id, replacement.value.session_id);

  // With no argument the command toggles the bridge back off.
  child.stdin.write("/nvim-bridge\r");
  await waitFor(
    () =>
      !existsSync(join(runtime, replacement.name)) &&
      !existsSync(replacement.value.socket_path),
    "bridge descriptor was not removed by the toggle",
  );

  // The other half of the same rule: following the session must not resurrect a
  // bridge the user turned off. Discovery is opt-in, so a /new after a disable
  // has to leave the project invisible.
  //
  // A descriptor that must never appear can only be checked by watching for a
  // while: this samples throughout the window rather than once at the end, so a
  // bridge that came back and was torn down again would still be caught. Pi's
  // own output cannot stand in for it — the TUI diffs its render, so a repeated
  // "New session started" is never written to the terminal a second time.
  child.stdin.write("/new\r");
  let advertised;
  const watcher = setInterval(() => {
    advertised = advertised || findDescriptor();
  }, 20);
  await new Promise((resolve) => setTimeout(resolve, 3000));
  clearInterval(watcher);
  assert.equal(
    advertised,
    undefined,
    "/new re-advertised a bridge the user had disabled",
  );

  // And that /new really did replace the session, so the check above was not
  // just watching a Pi that did nothing at all: opting back in has to advertise
  // a third session id.
  child.stdin.write("/nvim-bridge enable\r");
  let reopened;
  await waitFor(() => {
    reopened = findDescriptor(replacement.value.session_id);
    return Boolean(reopened);
  }, "the bridge did not come back after an explicit enable");
  assert.notEqual(reopened.value.session_id, descriptor.value.session_id);

  // Killing Pi below skips its shutdown hook, so clean up anything it published.
  for (const { name, value } of projectDescriptors()) {
    rmSync(join(runtime, name), { force: true });
    rmSync(value.socket_path, { force: true });
  }
  console.log("socket bridge end-to-end passed");
} finally {
  child.kill("SIGTERM");
  rmSync(project, { recursive: true, force: true });
}
