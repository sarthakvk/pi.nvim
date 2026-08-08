import { createHash, randomUUID } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

export const VERSION = 1;

export type Finding = {
  id: string;
  request_id: string;
  context_item_id?: string;
  path: string;
  start_line: number;
  end_line: number;
  severity: "error" | "warning" | "information" | "hint";
  title: string;
  message: string;
  expected_text: string;
};

export function identifier(): string {
  return randomUUID();
}

export function inside(root: string, candidate: string): string | undefined {
  try {
    const realRoot = realpathSync.native(root);
    const absolute = resolve(realRoot, candidate);
    let realCandidate: string;
    try { realCandidate = realpathSync.native(absolute); }
    catch { realCandidate = join(realpathSync.native(dirname(absolute)), basename(absolute)); }
    const relativePath = relative(realRoot, realCandidate);
    if (relativePath === "" || relativePath === ".." || relativePath.startsWith(`..${sep}`)) return undefined;
    return relativePath.split(sep).join("/");
  } catch {
    return undefined;
  }
}

export function canonicalRoot(cwd: string): string {
  try {
    return realpathSync.native(execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { encoding: "utf8" }).trim());
  } catch {
    return realpathSync.native(cwd);
  }
}

export function validateFinding(root: string, value: unknown): Finding {
  if (!value || typeof value !== "object") throw new Error("finding must be an object");
  const input = value as Record<string, unknown>;
  const path = typeof input.path === "string" ? inside(root, input.path) : undefined;
  const severity = input.severity;
  if (!path) throw new Error("finding path must be a project-relative path");
  if (!Number.isInteger(input.start_line) || !Number.isInteger(input.end_line) || (input.start_line as number) < 1 || (input.end_line as number) < (input.start_line as number)) throw new Error("finding lines must be a valid one-based inclusive range");
  if (!["error", "warning", "information", "hint"].includes(String(severity))) throw new Error("invalid finding severity");
  for (const key of ["request_id", "title", "message", "expected_text"] as const) if (typeof input[key] !== "string" || input[key] === "") throw new Error(`finding ${key} must be a non-empty string`);
  const sourceLines = readFileSync(join(root, path), "utf8").split("\n");
  if (sourceLines.at(-1) === "") sourceLines.pop();
  if ((input.end_line as number) > sourceLines.length) throw new Error("finding range exceeds file length");
  if (sourceLines.slice((input.start_line as number) - 1, input.end_line as number).join("\n") !== input.expected_text) throw new Error("finding expected_text does not match its range");
  return {
    id: typeof input.id === "string" && input.id !== "" ? input.id : identifier(), request_id: input.request_id as string,
    context_item_id: typeof input.context_item_id === "string" ? input.context_item_id : undefined, path,
    start_line: input.start_line as number, end_line: input.end_line as number, severity: severity as Finding["severity"],
    title: input.title as string, message: input.message as string, expected_text: input.expected_text as string,
  };
}

export function descriptorName(root: string, sessionId: string): string {
  return createHash("sha256").update(`${root}\0${sessionId}`).digest("hex").slice(0, 24);
}

export function parseJson(line: string): Record<string, unknown> | undefined {
  try {
    const value = JSON.parse(line);
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
  } catch { return undefined; }
}
