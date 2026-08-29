// Shared vocabulary between the Pi side of the bridge and Neovim: the wire
// version, the Finding record, and the path and validation rules both ends must
// agree on. Kept apart from index.ts because these are pure functions with no
// Pi runtime dependency, which is what makes them testable and safe to reuse.
//
// The project-boundary rules here mirror lua/pi/project.lua deliberately: if the
// two disagreed about what a root or a relative path is, findings would resolve
// to different files on each side.

import { createHash, randomUUID } from "node:crypto";
import { readFileSync, realpathSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { basename, dirname, join, relative, resolve, sep } from "node:path";

// Bumped only on an incompatible change; both ends refuse a mismatch at the
// handshake rather than half-speaking an older dialect.
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

// Returns `candidate` as a root-relative POSIX path, or undefined if it escapes
// the project. Both ends are resolved through realpath first so a symlink cannot
// be used to reach outside the root, and a candidate that does not exist yet is
// resolved via its parent directory so new files are still judged fairly.
export function inside(root: string, candidate: string): string | undefined {
  try {
    const realRoot = realpathSync.native(root);
    const absolute = resolve(realRoot, candidate);
    let realCandidate: string;
    try {
      realCandidate = realpathSync.native(absolute);
    } catch {
      realCandidate = join(
        realpathSync.native(dirname(absolute)),
        basename(absolute),
      );
    }
    const relativePath = relative(realRoot, realCandidate);
    // "" is the root directory itself, which is never a file we may annotate.
    if (
      relativePath === "" ||
      relativePath === ".." ||
      relativePath.startsWith(`..${sep}`)
    )
      return undefined;
    return relativePath.split(sep).join("/");
  } catch {
    return undefined;
  }
}

// Must agree with pi.project.root on the Lua side: the Git worktree top level,
// or the working directory when there is no worktree.
export function canonicalRoot(cwd: string): string {
  try {
    return realpathSync.native(
      execFileSync("git", ["-C", cwd, "rev-parse", "--show-toplevel"], {
        encoding: "utf8",
      }).trim(),
    );
  } catch {
    return realpathSync.native(cwd);
  }
}

// Findings come from a model, so nothing about them is trusted. Beyond shape and
// range checks, the claimed expected_text is compared against the file on disk:
// an annotation whose anchor text does not exist would land on unrelated lines,
// so it is rejected at the source instead of being shown as stale in the editor.
export function validateFinding(root: string, value: unknown): Finding {
  if (!value || typeof value !== "object")
    throw new Error("finding must be an object");
  const input = value as Record<string, unknown>;
  const path =
    typeof input.path === "string" ? inside(root, input.path) : undefined;
  const severity = input.severity;
  if (!path) throw new Error("finding path must be a project-relative path");
  if (
    !Number.isInteger(input.start_line) ||
    !Number.isInteger(input.end_line) ||
    (input.start_line as number) < 1 ||
    (input.end_line as number) < (input.start_line as number)
  )
    throw new Error("finding lines must be a valid one-based inclusive range");
  if (!["error", "warning", "information", "hint"].includes(String(severity)))
    throw new Error("invalid finding severity");
  for (const key of [
    "request_id",
    "title",
    "message",
    "expected_text",
  ] as const)
    if (typeof input[key] !== "string" || input[key] === "")
      throw new Error(`finding ${key} must be a non-empty string`);
  const sourceLines = readFileSync(join(root, path), "utf8").split("\n");
  // A trailing newline splits into a phantom empty last line; dropping it keeps
  // indices in step with the line numbers the editor reports.
  if (sourceLines.at(-1) === "") sourceLines.pop();
  if ((input.end_line as number) > sourceLines.length)
    throw new Error("finding range exceeds file length");
  if (
    sourceLines
      .slice((input.start_line as number) - 1, input.end_line as number)
      .join("\n") !== input.expected_text
  )
    throw new Error("finding expected_text does not match its range");
  return {
    id:
      typeof input.id === "string" && input.id !== "" ? input.id : identifier(),
    request_id: input.request_id as string,
    // Spread rather than assigning undefined, so an absent id stays absent in
    // the JSON that crosses to Neovim instead of becoming an explicit null.
    ...(typeof input.context_item_id === "string" && {
      context_item_id: input.context_item_id,
    }),
    path,
    start_line: input.start_line as number,
    end_line: input.end_line as number,
    severity: severity as Finding["severity"],
    title: input.title as string,
    message: input.message as string,
    expected_text: input.expected_text as string,
  };
}

// File-name stem for a session's socket and descriptor. Hashed because roots and
// session ids are not safe as path components, and keyed on both so two sessions
// in the same project do not collide.
export function descriptorName(root: string, sessionId: string): string {
  return createHash("sha256")
    .update(`${root}\0${sessionId}`)
    .digest("hex")
    .slice(0, 24);
}

// Parses one framed line, yielding undefined for anything that is not a JSON
// object, so callers can skip junk without a try/catch at every call site.
export function parseJson(line: string): Record<string, unknown> | undefined {
  try {
    const value = JSON.parse(line);
    return value && typeof value === "object" && !Array.isArray(value)
      ? (value as Record<string, unknown>)
      : undefined;
  } catch {
    return undefined;
  }
}

// Either an excerpt -- `text` plus the range it was taken from -- or a pointer,
// which names a location and leaves the reading to Pi. A pointer has no `text`
// and no `kind`, and carries whichever of the two locations the editor knew: the
// range the user selected, or the line their cursor was on.
type Context = {
  text?: string;
  note?: string;
  path: string;
  start_line?: number;
  end_line?: number;
  cursor_line?: number;
  kind?: string;
};

type ContextEnvelope = {
  note: string;
  root?: string;
  contexts: Context[];
};

function parseContextEnvelope(text: string): ContextEnvelope | undefined {
  try {
    const value = JSON.parse(text);
    if (!value || typeof value !== "object" || !Array.isArray(value.contexts)) {
      return undefined;
    }
    if (typeof value.note !== "string") return undefined;
    if (value.root !== undefined && typeof value.root !== "string")
      return undefined;
    const contexts = value.contexts.map((context: unknown) => {
      if (!context || typeof context !== "object")
        throw new Error("invalid context");
      const item = context as Record<string, unknown>;
      if (typeof item.path !== "string" || item.path === "") {
        throw new Error("invalid context metadata");
      }
      if (item.text !== undefined && typeof item.text !== "string") {
        throw new Error("invalid context text");
      }
      if (
        item.kind !== undefined &&
        (typeof item.kind !== "string" || item.kind === "")
      ) {
        throw new Error("invalid context kind");
      }
      if (item.note !== undefined && typeof item.note !== "string") {
        throw new Error("invalid context note");
      }
      // A range is all or nothing, and an excerpt must say which lines it quotes:
      // text without a range would be source Pi cannot locate. A pointer may omit
      // the range entirely, which means the whole file.
      const ranged =
        item.start_line !== undefined || item.end_line !== undefined;
      if (ranged || item.text !== undefined) {
        if (
          !Number.isInteger(item.start_line) ||
          !Number.isInteger(item.end_line) ||
          (item.start_line as number) < 1 ||
          (item.end_line as number) < (item.start_line as number)
        ) {
          throw new Error("invalid context lines");
        }
      }
      if (
        item.cursor_line !== undefined &&
        (!Number.isInteger(item.cursor_line) ||
          (item.cursor_line as number) < 1)
      ) {
        throw new Error("invalid context cursor line");
      }
      return {
        text: item.text as string | undefined,
        note: item.note as string | undefined,
        path: item.path,
        start_line: item.start_line as number | undefined,
        end_line: item.end_line as number | undefined,
        cursor_line: item.cursor_line as number | undefined,
        kind: item.kind as string | undefined,
      };
    });
    return { note: value.note, root: value.root, contexts };
  } catch {
    return undefined;
  }
}

function blockquote(text: string): string {
  return text
    .split("\n")
    .map((line) => `> ${line}`)
    .join("\n");
}

function fenceFor(text: string): string {
  const runs = text.match(/`+/g) ?? [];
  const longestRun = runs.reduce(
    (longest, run) => Math.max(longest, run.length),
    0,
  );
  // Triple backticks are the normal format. Use a longer fence only when the
  // source itself contains a backtick run that would close a Markdown block.
  return "`".repeat(Math.max(3, longestRun + 1));
}

function languageForPath(path: string): string {
  const extension = path.toLowerCase().split(".").at(-1) ?? "";
  const languages: Record<string, string> = {
    bash: "bash",
    c: "c",
    cc: "cpp",
    css: "css",
    cpp: "cpp",
    go: "go",
    h: "c",
    hpp: "cpp",
    html: "html",
    java: "java",
    js: "javascript",
    json: "json",
    jsx: "jsx",
    lua: "lua",
    md: "markdown",
    mjs: "javascript",
    py: "python",
    rs: "rust",
    scss: "scss",
    sh: "bash",
    sql: "sql",
    svelte: "svelte",
    toml: "toml",
    ts: "typescript",
    tsx: "tsx",
    vue: "vue",
    xml: "xml",
    yaml: "yaml",
    yml: "yaml",
    zig: "zig",
  };
  return languages[extension] ?? "text";
}

function inlineCode(text: string): string {
  const runs = text.match(/`+/g) ?? [];
  const longestRun = runs.reduce(
    (longest, run) => Math.max(longest, run.length),
    0,
  );
  const fence = "`".repeat(longestRun + 1);
  return `${fence}${text}${fence}`;
}

function constructFilePath(
  filepath: string,
  start_line: number | undefined,
  end_line: number | undefined,
): string {
  const line: string[] = [];
  line.push(start_line !== undefined ? String(start_line) : "");
  line.push(end_line !== undefined ? String(end_line) : "");
  return `@${filepath}:${line.join("-")}`;
}

export function formatContextEnvelope(text: string): string | undefined {
  const envelope = parseContextEnvelope(text);
  if (!envelope) return undefined;
  // An envelope with no contexts is an instruction the editor had no file to
  // attach. It still arrives as JSON so that Pi does not read a leading "/" as
  // a slash command, so it has to be unwrapped here rather than passed through.
  if (envelope.contexts.length === 0) return envelope.note;

  const sections = envelope.contexts.map((context, index) => {
    // An excerpt quotes its source inline, so the relative path is a label. A
    // pointer's path is the only way to reach the file, and Pi's working
    // directory is not necessarily the project root it was matched on, so that
    // path has to be absolute.
    const path =
      context.text === undefined && envelope.root
        ? `${envelope.root}/${context.path}`
        : context.path;
    const filepath = constructFilePath(
      path,
      context.start_line,
      context.end_line,
    );
    const lines = [`### Context ${index + 1}`, "", `- **File:** ${filepath}`];
    if (context.kind !== undefined)
      lines.push(`- **Kind:** ${inlineCode(context.kind)}`);
    if (context.cursor_line !== undefined) {
      lines.push(`- **Cursor line:** ${context.cursor_line}`);
    }
    // A pointer stops here: the path and the location are the whole context, and
    // Pi reads the file if it needs what is in it.
    if (context.text !== undefined) {
      const fence = fenceFor(context.text);
      lines.push(
        "",
        `${fence}${languageForPath(context.path)}`,
        context.text,
        fence,
      );
    }
    if (context.note) lines.push(blockquote(context.note));
    return lines.join("\n");
  });
  return `${sections.join("\n---\n")}\n---\n${envelope.note}`;
}
