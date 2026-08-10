// The Pi half of the bridge: a Pi extension that lets one Pi session be driven
// from Neovim and gives Pi a way to send review findings back.
//
// It contributes three things. `/nvim-bridge enable` opens a unix socket in the
// user's private runtime directory and advertises it with a descriptor file —
// this is the opt-in, and without it a Pi process is invisible to Neovim even
// when it shares the project. The socket then serves Neovim's requests (send a
// message, clear findings) and pushes activity, edit, and findings events. The
// `nvim_publish_findings` tool is how Pi returns review annotations, which are
// editor-only and never touch source files.
//
// Findings live in Pi's session history rather than in memory alone, so they are
// rebuilt on reattach and survive a restart.

import type {
  ExtensionAPI,
  ExtensionContext,
} from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { StringDecoder } from "node:string_decoder";
import { join } from "node:path";
import {
  VERSION,
  canonicalRoot,
  descriptorName,
  inside,
  parseJson,
  type Finding,
  validateFinding,
} from "./protocol";

// Pi may load this file more than once (as an installed package and via
// --extension); registering the same tool twice would fail, so the first load
// marks the API object and later ones return immediately.
const GUARD = Symbol.for("pi.nvim.extension.loaded");
// Session entry type recording that findings were cleared. Clearing has to be
// part of the history, otherwise replaying it would resurrect them.
const FINDINGS_CLEAR_TYPE = "pi.nvim/findings-clear";

type Runtime = {
  root: string;
  ctx: ExtensionContext;
  server?: Server;
  socketPath?: string;
  descriptorPath?: string;
  clients: Set<Socket>;
  findings: Map<string, Finding>;
  changedPaths: Set<string>;
};

function runtimeDirectory(): string {
  const stateHome =
    process.env.XDG_STATE_HOME ||
    join(process.env.HOME || "/tmp", ".local", "state");
  const path = join(
    process.env.XDG_RUNTIME_DIR || join(stateHome, "nvim", "run"),
    "pi.nvim",
  );
  // 0700, and re-applied in case the directory already existed with looser
  // permissions: these descriptors name sockets that can drive an agent session.
  mkdirSync(path, { recursive: true, mode: 0o700 });
  chmodSync(path, 0o700);
  return path;
}

function splitLines(text: string): string[] {
  const result = text.split("\n");
  // A trailing newline splits into a phantom empty last line; dropping it keeps
  // indices in step with the line numbers the editor reports.
  if (result.at(-1) === "") result.pop();
  return result;
}

function expectedTextMatches(root: string, finding: Finding): boolean {
  try {
    const text = readFileSync(join(root, finding.path), "utf8");
    return (
      splitLines(text)
        .slice(finding.start_line - 1, finding.end_line)
        .join("\n") === finding.expected_text
    );
  } catch {
    return false;
  }
}

// Rebuilds the finding set from the session's history, so reattaching or
// resuming a session shows the same annotations Pi last published rather than an
// empty slate.
function restoreFindings(runtime: Runtime): void {
  runtime.findings.clear();
  for (const entry of runtime.ctx.sessionManager.getBranch()) {
    if (
      entry.type === "message" &&
      entry.message.role === "toolResult" &&
      entry.message.toolName === "nvim_publish_findings"
    ) {
      for (const finding of (
        entry.message.details as { findings?: Finding[] } | undefined
      )?.findings || [])
        runtime.findings.set(finding.id, finding);
    }
    if (entry.type === "custom" && entry.customType === FINDINGS_CLEAR_TYPE) {
      const id = (entry.data as { id?: string } | undefined)?.id;
      if (id) runtime.findings.delete(id);
      else runtime.findings.clear();
    }
  }
}

function emit(runtime: Runtime, event: Record<string, unknown>): void {
  const line = JSON.stringify(event) + "\n";
  for (const client of runtime.clients)
    if (!client.destroyed) client.write(line);
}

// Findings are always broadcast as a complete set, so a client that missed an
// event still converges instead of accumulating stale annotations.
function broadcastFindings(runtime: Runtime): void {
  emit(runtime, {
    type: "findings",
    findings: [...runtime.findings.values()],
    session_id: runtime.ctx.sessionManager.getSessionId(),
    session_file: runtime.ctx.sessionManager.getSessionFile(),
  });
}

function closeServer(runtime: Runtime): void {
  for (const client of runtime.clients) client.destroy();
  runtime.clients.clear();
  runtime.server?.close();
  // Removing the descriptor and socket is what makes this session undiscoverable
  // again; Neovim only prunes them lazily.
  if (runtime.socketPath) rmSync(runtime.socketPath, { force: true });
  if (runtime.descriptorPath) rmSync(runtime.descriptorPath, { force: true });
  runtime.server = undefined;
}

function descriptor(runtime: Runtime): Record<string, unknown> {
  const session = runtime.ctx.sessionManager;
  return {
    version: VERSION,
    root: runtime.root,
    session_id: session.getSessionId(),
    session_file: session.getSessionFile(),
    display_name: session.getSessionName(),
    pid: process.pid,
    started_at: Date.now(),
    socket_path: runtime.socketPath,
    activity: runtime.ctx.isIdle() ? "idle" : "working",
    capabilities: ["send", "findings", "tool_activity"],
  };
}

// Rewritten whenever activity changes so a Neovim that has not connected yet
// still sees an accurate picture when it lists sessions.
function writeDescriptor(runtime: Runtime): void {
  if (!runtime.descriptorPath) return;
  writeFileSync(runtime.descriptorPath, JSON.stringify(descriptor(runtime)), {
    mode: 0o600,
  });
  chmodSync(runtime.descriptorPath, 0o600);
}

function respond(
  socket: Socket,
  id: unknown,
  data?: unknown,
  error?: string,
): void {
  socket.write(JSON.stringify({ type: "response", id, data, error }) + "\n");
}

function serveClient(runtime: Runtime, socket: Socket): void {
  runtime.clients.add(socket);
  let buffer = "";
  // A decoder rather than chunk.toString(): a multi-byte character can be split
  // across two reads, and source text is routinely non-ASCII.
  const decoder = new StringDecoder("utf8");
  socket.on("data", (chunk: Buffer) => {
    buffer += decoder.write(chunk);
    while (true) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      let line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      const message = parseJson(line);
      if (!message) continue;
      if (message.type === "hello") {
        // The handshake is also the guard: a client on the wrong protocol or a
        // different project must not be able to drive this session.
        if (message.version !== VERSION || message.root !== runtime.root)
          respond(
            socket,
            message.id,
            undefined,
            "protocol or project root mismatch",
          );
        else respond(socket, message.id, descriptor(runtime));
      } else if (
        message.type === "send" &&
        typeof message.message === "string"
      ) {
        const delivery =
          message.delivery === "steer" || message.delivery === "followUp"
            ? message.delivery
            : undefined;
        // Interrupting a working session needs an explicit choice from the user,
        // so a plain send into a busy Pi is refused rather than guessed at.
        if (!runtime.ctx.isIdle() && !delivery)
          respond(
            socket,
            message.id,
            undefined,
            "Pi is busy; choose steering or follow-up delivery",
          );
        else {
          try {
            piSend(runtime, message.message, delivery);
            respond(socket, message.id, { accepted: true });
          } catch (error) {
            respond(
              socket,
              message.id,
              undefined,
              error instanceof Error ? error.message : String(error),
            );
          }
        }
      } else if (message.type === "clear_findings") {
        const id =
          typeof message.id_to_clear === "string"
            ? message.id_to_clear
            : undefined;
        if (id) runtime.findings.delete(id);
        else runtime.findings.clear();
        runtime.ctx.sessionManager.appendCustomEntry(FINDINGS_CLEAR_TYPE, {
          id,
        });
        broadcastFindings(runtime);
        respond(socket, message.id, { cleared: id });
      } else
        respond(socket, message.id, undefined, "unsupported bridge request");
    }
  });
  socket.on("end", () => {
    buffer += decoder.end();
  });
  socket.on("close", () => runtime.clients.delete(socket));
  socket.on("error", () => runtime.clients.delete(socket));
  // Send the current set immediately so a fresh client is never blank until the
  // next change.
  broadcastFindings(runtime);
}

// Captured once at extension load because the socket and tool handlers need to
// speak as the user long after that call returns.
let sendUserMessage: (
  message: string,
  options?: { deliverAs?: "steer" | "followUp" },
) => void;
function piSend(
  runtime: Runtime,
  message: string,
  delivery?: "steer" | "followUp",
): void {
  sendUserMessage(message, delivery ? { deliverAs: delivery } : undefined);
}

// Opting this session in. Nothing listens until a user runs the command, which
// is what keeps arbitrary Pi processes out of Neovim's reach.
function enable(runtime: Runtime): string {
  if (runtime.server) return "Pi bridge is already enabled";
  const sessionId = runtime.ctx.sessionManager.getSessionId();
  const name = descriptorName(runtime.root, sessionId);
  const directory = runtimeDirectory();
  runtime.socketPath = join(directory, `${name}.sock`);
  runtime.descriptorPath = join(directory, `${name}.json`);
  // A socket left behind by a crashed session with the same id would block bind.
  if (existsSync(runtime.socketPath))
    rmSync(runtime.socketPath, { force: true });
  runtime.server = createServer((client) => serveClient(runtime, client));
  // The descriptor is only published once the socket is actually accepting, so
  // Neovim never finds an address it cannot connect to.
  runtime.server.once("listening", () => writeDescriptor(runtime));
  runtime.server.listen(runtime.socketPath);
  return `Pi bridge is enabling for ${runtime.root}`;
}

export default function (pi: ExtensionAPI): void {
  const guarded = pi as unknown as Record<symbol, boolean>;
  if (guarded[GUARD]) return;
  guarded[GUARD] = true;
  let runtime: Runtime | undefined;
  const changedToolPaths = new Map<string, string | undefined>();
  sendUserMessage = pi.sendUserMessage.bind(pi);

  pi.on("session_start", (_event, ctx) => {
    const root = canonicalRoot(ctx.cwd);
    runtime = {
      root,
      ctx,
      clients: new Set(),
      findings: new Map(),
      changedPaths: new Set(),
    };
    restoreFindings(runtime);
  });
  pi.on("session_shutdown", () => {
    changedToolPaths.clear();
    if (runtime) closeServer(runtime);
    runtime = undefined;
  });
  pi.on("agent_start", () => {
    if (runtime) {
      runtime.changedPaths.clear();
      writeDescriptor(runtime);
      emit(runtime, { type: "activity", state: "working" });
    }
  });
  pi.on("agent_settled", () => {
    if (!runtime) return;
    // Edits are reported as one batch at the end of the turn: Neovim reloads
    // clean buffers on this signal and should not do so mid-turn.
    const paths = [...runtime.changedPaths];
    if (paths.length > 0) emit(runtime, { type: "tool_activity", paths });
    writeDescriptor(runtime);
    emit(runtime, { type: "activity", state: "idle" });
  });
  pi.on("tool_execution_start", (event) => {
    if (event.toolName !== "edit" && event.toolName !== "write") return;
    const args = event.args as { path?: unknown } | undefined;
    changedToolPaths.set(
      event.toolCallId,
      typeof args?.path === "string" ? args.path : undefined,
    );
  });
  pi.on("tool_execution_end", (event) => {
    // tool_execution_end does not carry args in Pi's extension API, so recover
    // the path captured at start. This is a hint for Neovim's reload check and
    // never a complete audit trail of the turn.
    const path = changedToolPaths.get(event.toolCallId);
    changedToolPaths.delete(event.toolCallId);
    if (
      !runtime ||
      event.isError ||
      (event.toolName !== "edit" && event.toolName !== "write")
    )
      return;
    const relativePath = typeof path === "string" && inside(runtime.root, path);
    if (relativePath) runtime.changedPaths.add(relativePath);
  });

  pi.registerCommand("nvim-bridge", {
    description:
      "Enable or disable the local Neovim bridge; use /nvim-bridge enable",
    handler: async (args, ctx) => {
      if (!runtime) return;
      if (args.trim() === "enable") ctx.ui.notify(enable(runtime), "info");
      else if (args.trim() === "disable") {
        closeServer(runtime);
        ctx.ui.notify("Pi bridge disabled", "info");
      }
      // Also reachable from headless Pi, which has no bridge socket to carry a
      // clear_findings request and can only be driven by slash commands.
      else if (args.trim().startsWith("clear")) {
        const id = args.trim().split(/\s+/, 2)[1];
        if (id) runtime.findings.delete(id);
        else runtime.findings.clear();
        pi.appendEntry(FINDINGS_CLEAR_TYPE, { id });
        broadcastFindings(runtime);
        ctx.ui.notify("Pi findings cleared", "info");
      } else
        ctx.ui.notify(
          "Usage: /nvim-bridge enable|disable|clear [finding-id]",
          "info",
        );
    },
  });

  pi.registerTool({
    name: "nvim_publish_findings",
    label: "Publish Neovim Findings",
    description:
      "Publish editor-only review findings for saved project source. This never edits source files.",
    promptSnippet: "Publish review findings as Neovim annotations",
    promptGuidelines: [
      "Use nvim_publish_findings to return concrete code-review findings for context supplied from Neovim; include exact current source text in expected_text.",
    ],
    parameters: Type.Object({
      findings: Type.Array(
        Type.Object({
          request_id: Type.String(),
          context_item_id: Type.Optional(Type.String()),
          path: Type.String(),
          start_line: Type.Integer(),
          end_line: Type.Integer(),
          severity: StringEnum([
            "error",
            "warning",
            "information",
            "hint",
          ] as const),
          title: Type.String(),
          message: Type.String(),
          expected_text: Type.String(),
        }),
      ),
    }),
    async execute(_id, params, _signal, _update, ctx) {
      if (!runtime) throw new Error("Neovim bridge runtime is unavailable");
      // Validate the whole batch before publishing any of it, so a bad finding
      // fails the call outright instead of leaving a half-applied set in the
      // editor.
      const published = params.findings.map((finding) =>
        validateFinding(runtime!.root, finding),
      );
      for (const finding of published)
        if (!expectedTextMatches(runtime.root, finding))
          throw new Error(
            `finding expected_text does not match ${finding.path}:${finding.start_line}-${finding.end_line}`,
          );
      for (const finding of published)
        runtime.findings.set(finding.id, finding);
      broadcastFindings(runtime);
      return {
        content: [
          {
            type: "text",
            text: `Published ${published.length} Neovim finding(s).`,
          },
        ],
        details: { findings: published },
      };
    },
  });
}
