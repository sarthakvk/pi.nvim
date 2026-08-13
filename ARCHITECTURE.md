# Architecture

pi.nvim is two halves of one bridge: a Neovim plugin (Lua) that captures saved
source and renders findings, and a Pi extension (TypeScript) that lets a Pi
session be driven from the editor and publish annotations back.

## Contents

- [Layout](#layout)
- [The two paths to Pi](#the-two-paths-to-pi)
- [Neovim side (`lua/pi/`)](#neovim-side-luapi)
  - [`init.lua` — commands and flow](#initlua--commands-and-flow)
  - [`context.lua` — capture](#contextlua--capture)
  - [`draft.lua` — collection, bundling, envelope](#draftlua--collection-bundling-envelope)
  - [`session.lua` — target selection and state](#sessionlua--target-selection-and-state)
  - [`transport/socket.lua` — interactive transport](#transportsocketlua--interactive-transport)
  - [`transport/rpc.lua` — headless transport](#transportrpclua--headless-transport)
  - [`findings.lua` — annotations](#findingslua--annotations)
  - [`ui.lua`, `project.lua`, `health.lua`](#uilua-projectlua-healthlua)
- [Pi side (`pi-extension/`)](#pi-side-pi-extension)
- [Data shapes](#data-shapes)
- [Invariants](#invariants)
- [Tests](#tests)
- [Where to change what](#where-to-change-what)

## Layout

```
plugin/pi.lua            :Pi* command definitions; the only startup cost
lua/pi/init.lua          public API + command implementations (flow owner)
lua/pi/context.lua       buffer/range -> excerpt record, read from disk
lua/pi/draft.lua         per-root draft list, bundling, wire envelope
lua/pi/session.lua       per-root target state; discover/attach/start/stop
lua/pi/transport/socket.lua  client for an opted-in Pi terminal session
lua/pi/transport/rpc.lua     client for a spawned `pi --mode rpc` worker
lua/pi/findings.lua      findings store -> Neovim diagnostics
lua/pi/ui.lua            every prompt, picker, and scratch listing
lua/pi/project.lua       root/containment/state-file rules
lua/pi/health.lua        :checkhealth pi
pi-extension/index.ts    Pi extension: bridge socket, /nvim-bridge, findings tool
pi-extension/protocol.ts shared wire version, Finding type, path validation
```

## The two paths to Pi

| | interactive | headless |
|---|---|---|
| Process | user's Pi terminal, opted in via `/nvim-bridge` | `pi --mode rpc` spawned by the plugin |
| Transport | `transport/socket.lua` ↔ unix socket in `$XDG_RUNTIME_DIR/pi.nvim` | `transport/rpc.lua` ↔ stdio NDJSON |
| Discovery | descriptor JSON files, matched on `root` | none; started on demand |
| Lifetime | user's; left running | plugin's; killed on `VimLeavePre` |
| Clear findings | `clear_findings` request | `/nvim-bridge clear` slash command |

Both wire formats are newline-delimited JSON, request/`response` correlated by
`id`, with unmatched messages treated as events.

## Neovim side (`lua/pi/`)

### `init.lua` — commands and flow

Owns the user-visible sequence: capture → draft → choose target → send → work
with findings. Everything below it is a detail it delegates to.

Public functions (each is one `:Pi*` command, wired in `plugin/pi.lua`):

| Function | Command | Job |
|---|---|---|
| `setup(options)` | — | merge config, configure diagnostics, install autocommands (revalidate findings on edit/enter/write; stop headless workers on exit) |
| `context_add(opts)` | `:PiContextAdd` | capture file or `:range`, prompt for a note, append to the draft |
| `context_show()` | `:PiContextShow` | open the draft listing scratch buffer |
| `context_remove()` | `:PiContextRemove` | drop the draft item under the cursor |
| `context_refresh()` | `:PiContextRefresh` | re-read the cursor item from disk at its current extmark range |
| `context_clear()` | `:PiContextClear` | empty the draft for this root |
| `context_move(opts)` | `:PiContextMove {n}` | reorder the cursor item |
| `context_send()` | `:PiContextSend` | prompt for an instruction, bundle the draft, deliver, clear on acceptance |
| `send_current(opts)` | `:PiSend` | one-shot single-item bundle that bypasses the draft |
| `attach()` | `:PiAttach` | pick and attach an opted-in terminal session |
| `sessions()` | `:PiSessions` | list attached + discoverable sessions |
| `findings()` | `:PiFindings` | revalidate and open the findings listing |
| `reply()` | `:PiReply` | reply to the finding at cursor, in the session that raised it |
| `clear()` | `:PiClear` | clear the cursor finding (or all), then tell Pi best-effort |
| `response()` | `:PiResponse` | show the headless worker's last assistant reply |
| `status()` | `:PiStatus` | mode / activity / session id |
| `stop()` | `:PiStop` | stop the headless worker, printing the resume command |

Internal seams worth knowing:

- `ensure_target(root, cb)` — the target-resolution policy: attached transport
  wins, else exactly one descriptor auto-attaches, else pick, else `config.fallback`
  (`ask` / `headless` / `none`) decides. Nothing starts Pi without a user send.
- `deliver(root, request, on_sent)` — sends `draft.envelope(request)`; if Pi is
  working it asks *steer vs. queue* rather than guessing.
- `install_session_handlers(root)` — wires this module's reactions onto the
  session state table (findings, known changes, settled, exit, status/widget/title,
  editor prefill). Re-run before every attach/start because state outlives transports.
- `report_known_changes(root, paths)` — `:checktime` for clean buffers, warn for
  modified ones. Never discards unsaved work.
- `current_root()` — `vim.b.pi_root` (scratch listings) → buffer name → cwd.

### `context.lua` — capture

Turns a buffer into an excerpt read **from disk**.

- `buffer_is_saved(bufnr)` → `ok, path|reason`; rejects unnamed, modified, or
  externally-changed buffers (CRLF and trailing-newline normalised for the compare).
- `range(bufnr, first, last)` → excerpt record `{root, path, relative_path,
  start_line, end_line, text, bufnr}`.
- `file(bufnr)` → same, tagged `kind = "whole_file"`.
- `read_range(path, first, last)` → `text` straight from disk, for re-reads.

### `draft.lua` — collection, bundling, envelope

Per-root ordered list (`M.drafts[root]`), each item anchored by two extmarks in
namespace `pi.nvim.draft` so it follows edits.

- `items/add/remove/clear/move` — list maintenance; `remove` also deletes extmarks.
- `refresh(root, index)` — re-capture at the item's live extmark range.
- `resolve_live_range(item)` (local) — current extmark range, or the reason the
  item is untrustworthy. Callers surface that reason; they never fall back to the
  stale snapshot.
- `bundle(root, note, max_bytes)` → request `{id, root, note, contexts[]}`. Every
  excerpt is re-read from disk here, and an oversized bundle is refused, not
  truncated.
- `envelope(request)` → the single JSON text message sent to Pi, containing the
  request note and an array of context records. Source text and notes remain
  JSON data; no textual markers or generated instructions are added.

### `session.lua` — target selection and state

`M.state[root] = {transport, mode, activity, session_id, session_file, on_* handlers}`.

- `get(root)` — the state table (created on demand); everyone else reads/writes it.
- `discover(root)` — descriptors in the runtime dir matching `version == 1` and
  `root`; prunes descriptors whose pid or socket is gone.
- `attach(root, descriptor, cb)` — connect the socket, translate its events
  (`activity`, `findings`, `tool_activity`) onto state, replace any prior transport.
- `attach_origin(root, session_id, cb)` — reattach the exact session that raised a
  finding, for `:PiReply`.
- `choose_and_attach(root, cb)` — 0 → error, 1 → attach, many → `ui.select`.
- `start_headless(root, config, cb)` — spawn the RPC worker (resuming the saved
  session when `resume_headless`), forward its handlers, persist the new session id.
- `stop(root)` — mark stopping, abort + SIGTERM; returns the session reference so
  the caller can print a resume command. Teardown happens in the worker's exit handler.

Edited paths are buffered while Pi works and released as one batch on idle, so
buffers never reload mid-turn.

### `transport/socket.lua` — interactive transport

`connect(descriptor, root, handlers, cb)` connects, frames NDJSON, and performs a
`hello` handshake that **also guards**: a mismatched version or root aborts the
connection. `send(message, delivery, cb)`, `clear_findings(id, cb)`, `close(reason)`
(which fails all in-flight callbacks). All libuv callbacks re-enter via `vim.schedule`.

### `transport/rpc.lua` — headless transport

`start(config, root, saved_session, handlers, cb)` spawns
`pi --mode rpc --extension <path>` (plus `--session` when resuming), reads NDJSON
from stdout, accumulates stderr for the exit report, then requests `get_state` and
`get_tree`. The tree walk rebuilds the finding set from the **active branch only**
(`nvim_publish_findings` tool results minus `pi.nvim/findings-clear` entries), so a
resumed session shows what Pi still believes is current.

- `feed/receive` — line framing and event dispatch: keeps `latest_response`, tracks
  `edit`/`write` paths as a reload *hint*, forwards published findings.
- `ui_request(event)` — answers Pi's extension UI calls (`select`, `confirm`,
  `input`, `editor`, `notify`, `setStatus`, `setWidget`, `setTitle`,
  `set_editor_text`) with Neovim equivalents. Handled inline because Pi blocks on it.
- `command/request/send/extension_command/stop/close` — the write side.

### `findings.lua` — annotations

Per-root store rendered into diagnostics namespace `pi.nvim.findings`. Findings are
editor-only; nothing here writes source.

- `publish(root, findings, origin)` — merge, dropping any path outside the root.
- `replace(root, findings, origin)` — full snapshot (absent means cleared).
- `revalidate(root)` — compare each finding's `expected_text` against the loaded
  buffer and set `stale`; then render.
- `render(root)` — set diagnostics on every project buffer, including empty lists
  so removed annotations disappear.
- `clear(root, id?)`, `list(root)` (sorted), `at_cursor(root)` — resolves either the
  listing line (via `vim.b.pi_finding_ids`) or a range covering the cursor in source.

### `ui.lua`, `project.lua`, `health.lua`

- `ui.lua` — `notify`, `input`, `select` (all through `vim.ui.*`), `open_text`,
  `editor` (buffer prompt, `<C-Enter>`/`<Esc>`), `open_editor_prefill`,
  `open_draft` (two header lines are load-bearing: item N sits on line N+2),
  `open_findings` (stamps `pi_root` and `pi_finding_ids` on the buffer).
- `project.lua` — `root` (git toplevel, else containing directory), `relative`,
  `contains`, `state_file` (digest of root under `stdpath("state")/pi.nvim`). All
  paths go through realpath so a symlink cannot escape the root.
- `health.lua` — `check()`: Neovim ≥ 0.10, `pi` executable, extension file,
  runtime directory.

## Pi side (`pi-extension/`)

`index.ts` default-exports the extension entry point; a symbol guard makes a
double load a no-op.

- `/nvim-bridge [enable|disable|clear [id]]` (`pi.registerCommand`) — no arguments
  toggle the **opt-in** bridge; `enable` binds a unix socket and writes a 0600
  descriptor into the 0700 runtime directory, while `disable` removes them.
  Without enable, a Pi process is invisible to Neovim, even in the same project.
  `clear` also serves headless Pi, which has no socket.
- `nvim_publish_findings` tool (`pi.registerTool`) — Pi's only way to return
  annotations. The whole batch is validated before any of it is published, and each
  finding's `expected_text` must match disk.
- Socket server (`serveClient`) — `hello` (version + root guard), `send` (refuses a
  plain send into a busy Pi; requires `steer`/`followUp`), `clear_findings`.
- Events pushed to clients: `activity` on `agent_start`/`agent_settled`,
  `tool_activity` (batched edited paths, emitted on settle), and `findings` — always
  the complete set, so a client that missed one converges.
- `restoreFindings` — rebuilt from session history on `session_start`, so findings
  survive restart and reattach; clears are recorded as `pi.nvim/findings-clear`
  custom entries.
- `descriptor`/`writeDescriptor` — rewritten on activity change so a Neovim that
  has not connected still sees an accurate listing.

`protocol.ts` is pure and testable: `VERSION`, the `Finding` type, `inside`
(realpath-based containment), `canonicalRoot` (must agree with `pi.project.root`),
`validateFinding`, `descriptorName`, `parseJson`.

## Data shapes

- **Descriptor** (runtime dir JSON) — `version, root, session_id, session_file,
  display_name, pid, started_at, socket_path, activity, capabilities`.
- **Request/bundle** — `{id, root, note, contexts: [{id, kind, path, start_line,
  end_line, text, note}]}`.
- **Finding** — `{id, request_id, context_item_id?, path, start_line, end_line,
  severity, title, message, expected_text}` (+ `stale`, `origin_session_id`,
  `origin_session_file` on the Neovim side).

## Invariants

1. Only saved, on-disk source is sent; buffers are never saved for the user.
2. Pi never starts, and is never steered, without an explicit user action.
3. Discovery is opt-in — sharing a working directory is not enough.
4. Findings are diagnostics; nothing in the findings path writes to a source file.
5. Both ends must agree on `VERSION` and on what a project root is.
6. Source and notes are sent as JSON data; they do not become envelope structure
   or bypass project-root validation.

## Tests

- `npm test` — `tests/lua/run.lua`, offline: capture refusals, extmark tracking,
  and JSON envelope data handling.
- `npm run test:extension` — `tests/extension/rpc-load.test.mjs`, offline: the
  extension loads in `pi --mode rpc` without collision.
- `npm run test:e2e` — `tests/e2e/socket.mjs` (real Pi, opt-in + handshake) and
  `tests/e2e/run-headless.sh` → `headless.lua` (live model turn: known changes,
  findings, session resume).

## Where to change what

| Goal | Start at |
|---|---|
| New `:Pi*` command | `plugin/pi.lua` + a public function in `lua/pi/init.lua` |
| Change what gets captured / staleness rules | `lua/pi/context.lua` |
| Change the message Pi receives | `draft.bundle` / `draft.envelope` |
| Change target selection or fallback behaviour | `init.ensure_target`, `session.lua` |
| New bridge request or event | `transport/socket.lua` + `serveClient` in `index.ts` (bump `VERSION` if incompatible) |
| New headless capability / Pi UI primitive | `transport/rpc.lua` (`receive`, `ui_request`) |
| Change how findings look or when they go stale | `lua/pi/findings.lua`, `ui.open_findings` |
| Change finding validation | `validateFinding` in `pi-extension/protocol.ts` |
| Change root or containment rules | `lua/pi/project.lua` **and** `protocol.ts` (`inside`, `canonicalRoot`) |
