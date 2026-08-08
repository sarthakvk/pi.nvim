import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { StringEnum } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { chmodSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server, type Socket } from "node:net";
import { StringDecoder } from "node:string_decoder";
import { join } from "node:path";
import { VERSION, canonicalRoot, descriptorName, inside, parseJson, type Finding, validateFinding } from "./protocol";

const GUARD = Symbol.for("pi.nvim.extension.loaded");
const FINDING_TYPE = "pi.nvim/findings-clear";

type Runtime = { root: string; ctx: ExtensionContext; server?: Server; socketPath?: string; descriptorPath?: string; clients: Set<Socket>; findings: Map<string, Finding>; changedPaths: Set<string> };

function runtimeDirectory(): string {
  const stateHome = process.env.XDG_STATE_HOME || join(process.env.HOME || "/tmp", ".local", "state");
  const path = join(process.env.XDG_RUNTIME_DIR || join(stateHome, "nvim", "run"), "pi.nvim");
  mkdirSync(path, { recursive: true, mode: 0o700 });
  chmodSync(path, 0o700);
  return path;
}

function lines(text: string): string[] {
  const result = text.split("\n");
  if (result.at(-1) === "") result.pop();
  return result;
}

function expectedText(root: string, finding: Finding): boolean {
  try {
    const text = readFileSync(join(root, finding.path), "utf8");
    return lines(text).slice(finding.start_line - 1, finding.end_line).join("\n") === finding.expected_text;
  } catch { return false; }
}

function restore(runtime: Runtime): void {
  runtime.findings.clear();
  for (const entry of runtime.ctx.sessionManager.getBranch()) {
    if (entry.type === "message" && entry.message.role === "toolResult" && entry.message.toolName === "nvim_publish_findings") {
      for (const finding of (entry.message.details as { findings?: Finding[] } | undefined)?.findings || []) runtime.findings.set(finding.id, finding);
    }
    if (entry.type === "custom" && entry.customType === FINDING_TYPE) {
      const id = (entry.data as { id?: string } | undefined)?.id;
      if (id) runtime.findings.delete(id); else runtime.findings.clear();
    }
  }
}

function emit(runtime: Runtime, event: Record<string, unknown>): void {
  const line = JSON.stringify(event) + "\n";
  for (const client of runtime.clients) if (!client.destroyed) client.write(line);
}

function findingsEvent(runtime: Runtime): void {
  emit(runtime, {
    type: "findings", findings: [...runtime.findings.values()],
    session_id: runtime.ctx.sessionManager.getSessionId(), session_file: runtime.ctx.sessionManager.getSessionFile(),
  });
}

function closeServer(runtime: Runtime): void {
  for (const client of runtime.clients) client.destroy();
  runtime.clients.clear();
  runtime.server?.close();
  if (runtime.socketPath) rmSync(runtime.socketPath, { force: true });
  if (runtime.descriptorPath) rmSync(runtime.descriptorPath, { force: true });
  runtime.server = undefined;
}

function descriptor(runtime: Runtime): Record<string, unknown> {
  const session = runtime.ctx.sessionManager;
  return {
    version: VERSION, root: runtime.root, session_id: session.getSessionId(), session_file: session.getSessionFile(),
    display_name: session.getSessionName(), pid: process.pid, started_at: Date.now(), socket_path: runtime.socketPath,
    activity: runtime.ctx.isIdle() ? "idle" : "working", capabilities: ["send", "findings", "tool_activity"],
  };
}

function writeDescriptor(runtime: Runtime): void {
  if (!runtime.descriptorPath) return;
  writeFileSync(runtime.descriptorPath, JSON.stringify(descriptor(runtime)), { mode: 0o600 });
  chmodSync(runtime.descriptorPath, 0o600);
}

function respond(socket: Socket, id: unknown, data?: unknown, error?: string): void {
  socket.write(JSON.stringify({ type: "response", id, data, error }) + "\n");
}

function serveClient(runtime: Runtime, socket: Socket): void {
  runtime.clients.add(socket);
  let buffer = "";
  const decoder = new StringDecoder("utf8");
  socket.on("data", (chunk: Buffer) => {
    buffer += decoder.write(chunk);
    while (true) {
      const newline = buffer.indexOf("\n");
      if (newline < 0) break;
      let line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
      if (line.endsWith("\r")) line = line.slice(0, -1);
      const message = parseJson(line);
      if (!message) continue;
      if (message.type === "hello") {
        if (message.version !== VERSION || message.root !== runtime.root) respond(socket, message.id, undefined, "protocol or project root mismatch");
        else respond(socket, message.id, descriptor(runtime));
      } else if (message.type === "send" && typeof message.message === "string") {
        const delivery = message.delivery === "steer" || message.delivery === "followUp" ? message.delivery : undefined;
        if (!runtime.ctx.isIdle() && !delivery) respond(socket, message.id, undefined, "Pi is busy; choose steering or follow-up delivery");
        else {
          try { piSend(runtime, message.message, delivery); respond(socket, message.id, { accepted: true }); }
          catch (error) { respond(socket, message.id, undefined, error instanceof Error ? error.message : String(error)); }
        }
      } else if (message.type === "clear_findings") {
        const id = typeof message.id_to_clear === "string" ? message.id_to_clear : undefined;
        if (id) runtime.findings.delete(id); else runtime.findings.clear();
        runtime.ctx.sessionManager.appendCustomEntry(FINDING_TYPE, { id });
        findingsEvent(runtime); respond(socket, message.id, { cleared: id });
      } else respond(socket, message.id, undefined, "unsupported bridge request");
    }
  });
  socket.on("end", () => { buffer += decoder.end(); });
  socket.on("close", () => runtime.clients.delete(socket));
  socket.on("error", () => runtime.clients.delete(socket));
  findingsEvent(runtime);
}

let sendUserMessage: (message: string, options?: { deliverAs?: "steer" | "followUp" }) => void;
function piSend(runtime: Runtime, message: string, delivery?: "steer" | "followUp"): void { sendUserMessage(message, delivery ? { deliverAs: delivery } : undefined); }

function enable(runtime: Runtime): string {
  if (runtime.server) return "Pi bridge is already enabled";
  const sessionId = runtime.ctx.sessionManager.getSessionId();
  const name = descriptorName(runtime.root, sessionId);
  const directory = runtimeDirectory();
  runtime.socketPath = join(directory, `${name}.sock`);
  runtime.descriptorPath = join(directory, `${name}.json`);
  if (existsSync(runtime.socketPath)) rmSync(runtime.socketPath, { force: true });
  runtime.server = createServer((client) => serveClient(runtime, client));
  runtime.server.once("listening", () => writeDescriptor(runtime));
  runtime.server.listen(runtime.socketPath);
  return `Pi bridge is enabling for ${runtime.root}`;
}

export default function (pi: ExtensionAPI): void {
  const marked = pi as unknown as Record<symbol, boolean>;
  if (marked[GUARD]) return;
  marked[GUARD] = true;
  let runtime: Runtime | undefined;
  sendUserMessage = pi.sendUserMessage.bind(pi);

  pi.on("session_start", (_event, ctx) => {
    const root = canonicalRoot(ctx.cwd);
    runtime = { root, ctx, clients: new Set(), findings: new Map(), changedPaths: new Set() };
    restore(runtime);
  });
  pi.on("session_shutdown", () => { if (runtime) closeServer(runtime); runtime = undefined; });
  pi.on("agent_start", () => { if (runtime) { runtime.changedPaths.clear(); writeDescriptor(runtime); emit(runtime, { type: "activity", state: "working" }); } });
  pi.on("agent_settled", () => {
    if (!runtime) return;
    const paths = [...runtime.changedPaths];
    if (paths.length > 0) emit(runtime, { type: "tool_activity", paths });
    writeDescriptor(runtime); emit(runtime, { type: "activity", state: "idle" });
  });
  pi.on("tool_execution_end", (event) => {
    if (!runtime || event.isError || (event.toolName !== "edit" && event.toolName !== "write")) return;
    const path = (event.args as { path?: unknown }).path;
    const contained = typeof path === "string" && inside(runtime.root, path);
    if (contained) runtime.changedPaths.add(contained);
  });

  pi.registerCommand("nvim-bridge", {
    description: "Enable or disable the local Neovim bridge; use /nvim-bridge enable",
    handler: async (args, ctx) => {
      if (!runtime) return;
      if (args.trim() === "enable") ctx.ui.notify(enable(runtime), "info");
      else if (args.trim() === "disable") { closeServer(runtime); ctx.ui.notify("Pi bridge disabled", "info"); }
      else if (args.trim().startsWith("clear")) {
        const id = args.trim().split(/\s+/, 2)[1];
        if (id) runtime.findings.delete(id); else runtime.findings.clear();
        pi.appendEntry(FINDING_TYPE, { id }); findingsEvent(runtime); ctx.ui.notify("Pi findings cleared", "info");
      } else ctx.ui.notify("Usage: /nvim-bridge enable|disable|clear [finding-id]", "info");
    },
  });

  pi.registerTool({
    name: "nvim_publish_findings", label: "Publish Neovim Findings",
    description: "Publish editor-only review findings for saved project source. This never edits source files.",
    promptSnippet: "Publish review findings as Neovim annotations",
    promptGuidelines: ["Use nvim_publish_findings to return concrete code-review findings for context supplied from Neovim; include exact current source text in expected_text."],
    parameters: Type.Object({ findings: Type.Array(Type.Object({
      request_id: Type.String(), context_item_id: Type.Optional(Type.String()), path: Type.String(), start_line: Type.Integer(), end_line: Type.Integer(),
      severity: StringEnum(["error", "warning", "information", "hint"] as const),
      title: Type.String(), message: Type.String(), expected_text: Type.String(),
    })) }),
    async execute(_id, params, _signal, _update, ctx) {
      if (!runtime) throw new Error("Neovim bridge runtime is unavailable");
      const published = params.findings.map((finding) => validateFinding(runtime!.root, finding));
      for (const finding of published) if (!expectedText(runtime.root, finding)) throw new Error(`finding expected_text does not match ${finding.path}:${finding.start_line}-${finding.end_line}`);
      for (const finding of published) runtime.findings.set(finding.id, finding);
      findingsEvent(runtime);
      return { content: [{ type: "text", text: `Published ${published.length} Neovim finding(s).` }], details: { findings: published } };
    },
  });
}
