# Version 1 implementation plan

Status: draft for review

## Goal

Build the smallest local bridge that lets Neovim assemble saved source context
from several sections, send that bundle to a project Pi conversation, and
receive review findings as editor metadata. Prefer an opted-in interactive Pi
session, but allow Neovim to own a persistent headless Pi process when no
terminal session is needed.

The first supported baseline is Neovim 0.10 and the Pi 0.83 extension/RPC APIs.

## Version 1 contract

### In scope

- Build one request from an ordered bundle of visual selections, line ranges,
  and whole files, including sections from different files.
- Attach an optional note to each context item and a free-form overall question
  or instruction to the bundle.
- Include exact saved file text and source locations for every item.
- Refuse context from a modified buffer until the user saves or discards its
  changes.
- Attach only to interactive Pi sessions that explicitly enable the bridge.
- Choose among multiple matching Pi sessions.
- Start and resume a project-scoped headless Pi session when configured or
  confirmed by the user.
- Preserve Pi's normal authentication, model selection, settings, extensions,
  tools, and permission policies in headless mode.
- Choose steering or follow-up delivery when Pi is already working.
- Receive structured findings as non-source annotations.
- Navigate, inspect, reply to, and clear findings.
- Mark findings stale when their anchored source no longer matches.
- Report headless progress and known file-changing tool activity.
- Open the latest headless prose response in a temporary read-only buffer.
- Stop a headless worker and resume its persisted session in terminal Pi.

### Out of scope

- A Neovim chat window or streamed transcript mirror.
- Accept/reject controls for Pi edits.
- Patch isolation, overlap resolution, or Git staging integration.
- Treating Pi changes as implicitly accepted work.
- Discovering arbitrary Pi processes by working directory alone.
- Remote transports or a hosted coordination service.

Change-proposal review remains Version 2.

## Product decisions

### Headless Pi has normal capabilities

The plugin will not add `--no-tools`, a read-only `--tools` allowlist, or
`--no-extensions` when spawning Pi. The worker inherits normal Pi configuration
and can edit files, run shell commands, commit, push, or use the network when
its configured tools and policies permit that.

The bridge will implement Pi's RPC extension-UI protocol so permission-gate
extensions can ask for confirmation through Neovim. This preserves configured
policy; it does not introduce a new safety boundary.

### Pi receives only saved source

Context is taken from files on disk, never from modified Neovim buffers. Adding
or immediately sending context from a modified buffer is refused with a prompt
to save or discard first. Before sending a draft, Neovim revalidates every item
and refuses the complete request if a source buffer has unsaved changes or its
file changed externally without being reloaded. The draft remains intact after
refusal.

This removes buffer-version data from the bridge protocol and ensures that Pi's
prompt context agrees with what its file tools can read from the working tree.

### Headless mode remains minimal, not invisible

Neovim will show state transitions and known tool activity without reproducing
the conversation stream. On completion it will report the result, render any
findings, and retain the latest assistant text for an on-demand response buffer.
The complete conversation remains in the persisted Pi session.

### Version 1 does not mediate edits

For both terminal and headless sessions, `edit` and `write` operate on the
working tree normally. The bridge records paths reported by known file tools
and prompts Neovim to check externally changed buffers after Pi settles. It
cannot reliably attribute changes made by `bash` or third-party tools, so it
must not claim to provide a complete change audit.

## Architecture

```text
                         interactive Pi
                       +------------------+
                       | bridge extension |
Neovim application <--| Unix socket      |
       ^               +------------------+
       |
       |               headless Pi owned by Neovim
       |               +------------------+
       +-------------->| pi --mode rpc    |
        JSONL stdio    | bridge extension |
                       +------------------+
```

Neovim presents one application-level session interface over two transport
adapters:

- **Socket transport:** communicates with an opted-in interactive Pi extension.
- **RPC transport:** owns a `pi --mode rpc` child and normalizes Pi RPC events.

The companion extension supplies terminal-session discovery, message injection,
normalized session/tool activity, and the structured findings tool. In RPC
mode, findings also appear in normal tool-result events, so Neovim does not
need a second socket to its own child.

## Repository layout

```text
plugin/pi.lua                     command registration
lua/pi/init.lua                   setup and public API
lua/pi/context.lua                saved file/range capture
lua/pi/draft.lua                  multi-item context draft
lua/pi/project.lua                canonical project identity
lua/pi/session.lua                target selection and lifecycle
lua/pi/transport/socket.lua       interactive-session transport
lua/pi/transport/rpc.lua          headless RPC process and JSONL parser
lua/pi/findings.lua               annotation state and stale checks
lua/pi/ui.lua                     prompts, status, and temporary buffers
pi-extension/index.ts             extension entry point
pi-extension/protocol.ts          socket messages and validation
pi-extension/findings.ts          tool definition and persistence
lua/pi/health.lua                 :checkhealth support
tests/lua/                        headless Neovim tests
tests/extension/                  TypeScript tests
tests/fixtures/                   fake socket and RPC peers
package.json                      Pi package manifest and test scripts
README.md                         installation and usage
```

The TypeScript extension is loaded directly by Pi; v1 should not require a
separate compilation step.

## Project and session identity

A project is identified by the real path of `git rev-parse --show-toplevel`.
Outside Git, use the real path of Pi's or Neovim's working directory. Requests
for buffers outside that root are rejected plainly in v1 rather than silently
attaching them to the wrong project.

An enabled interactive extension writes a descriptor and Unix socket beneath
`$XDG_RUNTIME_DIR/pi.nvim/`, falling back to a user-private temporary runtime
directory when necessary. The directory is user-only and sockets/descriptors
are not accessible to other users.

Each descriptor contains:

- protocol version;
- canonical project root;
- Pi session ID, optional session file, and display name;
- process ID and start time;
- socket path;
- idle/busy state and extension capabilities.

Descriptors are created only after `/nvim-bridge` enables the session and are
removed on disable or `session_shutdown`. Neovim validates the process,
handshake, protocol version, and exact project root before attachment. Dead
descriptors are removed during discovery.

Neovim stores the last headless session file/ID per project under
`stdpath("state")`. It never opens that session in another Pi process while its
worker is alive. Stopping or handing off the worker is an explicit lifecycle
step.

## Context draft and request

Neovim maintains one in-memory context draft per project. Adding an item does
not contact Pi. A draft can contain ordered items from several ranges and
files, and each item can carry an optional note. The user can inspect,
remove, reorder, refresh, or clear items before sending the bundle. An item can
be added only while its buffer is unmodified and synchronized with its file.

Each added range is anchored with Neovim extmarks so it follows later edits.
The draft retains the original path, range, saved-text snapshot, and file hash
for validation and review. At send time, Neovim verifies that every source
buffer is unmodified and synchronized with disk, resolves every extmark, and
reads the exact selected text from the saved file. If the saved text changed
since it was added, the item is labelled `changed_since_added`; if its source
has unsaved or externally changed content, or its range can no longer be
resolved, sending is refused until the file is saved or reloaded and the item
is refreshed or removed. An old snapshot is never silently transmitted.

A request carries:

- a generated request ID;
- the canonical project root;
- the user's overall free-form note or instruction;
- the requested delivery mode;
- an ordered `contexts` array.

Each context item carries:

- a generated item ID and item kind: range or whole file;
- project-relative path and one-based inclusive line range;
- exact text read from the saved file at send time;
- current saved-file SHA-256 hash;
- original saved-file hash and whether it changed after being added;
- the optional item-specific note.

The final Pi user message uses a documented text envelope with request metadata,
the overall note, and one clearly delimited section per context item in draft
order. Both transports generate the same envelope. Saved source text and item
notes are editor context; neither is silently written into a source file or
converted to a source-code comment.

The configured size limit applies to the aggregate encoded context bundle.
Oversized bundles are refused rather than truncated, and the draft is retained
so the user can remove or narrow individual items.

When Pi is idle, sending starts a normal turn. When it is busy, Neovim asks
whether to steer current work, queue a follow-up, or cancel. The transport maps
that choice to `pi.sendUserMessage(..., { deliverAs })` or the corresponding RPC
command. The draft is cleared only after Pi acknowledges that the request was
accepted; cancellation, validation errors, and transport failures preserve it.

## Findings

Register a `nvim_publish_findings` tool with a strict schema and Pi prompt
guidance that tells the agent to use it for editor review findings. Each finding
contains:

- originating request ID and optional originating context-item ID;
- project-relative path;
- one-based inclusive start and end lines;
- severity: error, warning, information, or hint;
- short title and explanatory message;
- exact expected source text for the annotated lines.

The extension validates project containment and ranges, generates stable
finding IDs, returns the normalized findings in tool-result details, and sends
them to attached socket clients. Tool-result details make publications part of
the Pi session history and allow branch-aware reconstruction after reload.
Clear operations are recorded as custom session entries that do not enter LLM
context. On socket attachment, the extension reconstructs the active branch and
sends a finding snapshot. On RPC attachment or resume, Neovim obtains the
session tree through RPC and reconstructs the same snapshot from normalized
tool results and clear entries.

Neovim keeps finding metadata separately and renders it through a dedicated
`vim.diagnostic` namespace. A finding is current only while its expected text
matches the corresponding buffer lines. Text changes, file reloads, and buffer
entry trigger revalidation; mismatches are shown as stale rather than moved by
heuristics.

A reply includes the finding ID, original request ID, current/stale state, and
reply text. It returns to the originating Pi session unless the user explicitly
chooses another attached session.

## Headless RPC worker

The worker starts lazily on the first send for which headless fallback is
selected. It runs with the project root as `cwd`, persistent sessions enabled,
and the companion extension explicitly available. It otherwise inherits Pi's
normal resource discovery and configuration.

The RPC adapter will:

- implement strict LF-delimited incremental JSON parsing;
- correlate command responses by request ID;
- handle prompt, steer, follow-up, abort, state, session, and tree commands;
- consume agent, message, tool, queue, retry, compaction, and extension-error
  events;
- implement RPC extension UI requests for select, confirm, input, editor,
  notification, status, widget text, title, and editor-prefill operations;
- retain the latest completed assistant text;
- track paths reported by `edit` and `write` calls;
- capture stderr and unexpected exits without mixing it into JSON stdout;
- terminate the child on explicit stop or Neovim exit and clean up state.

After `agent_settled`, the plugin reports completion, refreshes findings, and
checks unmodified buffers whose paths were changed by known file tools. Modified
Neovim buffers are never reloaded automatically; they receive a conflict
warning instead.

Stopping a worker reports the persisted session ID/path and the exact
`pi --session ...` command needed to resume it interactively. Launching an
external terminal is not part of v1.

## Neovim interface

V1 exposes commands and equivalent Lua functions, with no default mappings:

- `:PiContextAdd` adds the current saved file or command range to the project
  draft and accepts an optional item-specific note.
- `:PiContextShow` opens the ordered draft for inspection and reordering.
- `:PiContextRemove` removes the item at the cursor or one chosen from the draft.
- `:PiContextRefresh` resets an item's baseline snapshot to its current text.
- `:PiContextClear` discards the project draft.
- `:PiContextSend` prompts for the overall request and sends the complete draft.
- `:PiSend` remains a convenience action that immediately sends one current
  saved file or command-range item without changing an existing draft.
- `:PiAttach` discovers and chooses an opted-in terminal session.
- `:PiSessions` shows the active attachment and available targets.
- `:PiFindings` opens a navigable list of project findings.
- `:PiReply` replies to a finding at the cursor or selected from a list.
- `:PiClear` clears a finding, buffer findings, or project findings.
- `:PiResponse` opens the latest headless assistant response temporarily.
- `:PiStatus` reports session identity, mode, activity, and pending messages.
- `:PiStop` aborts if necessary, stops a headless worker, and reports how to
  resume its session.

Visual-mode mappings can call ranged `:PiContextAdd` or `:PiSend`, but the
plugin will not install mappings itself. Both actions refuse modified buffers.
Draft context uses a separate extmark namespace from returned findings and has
no permanent visible decoration by default.

## Configuration defaults

Keep configuration small and explain behaviour in `README.md` before showing a
setup example:

- **Fallback policy — `ask`:** when no interactive target exists, ask whether to
  start headless Pi. `headless` starts it automatically on an explicit send;
  `none` reports that no target exists. None of these starts Pi at editor
  startup.
- **Automatic terminal attachment — enabled:** attach automatically only when
  exactly one opted-in session matches the project. Multiple matches always
  open a chooser.
- **Resume headless session — enabled:** reuse the last valid project session;
  otherwise create a normal persistent Pi session.
- **Maximum context size — 256 KiB:** apply the limit to the aggregate encoded
  bundle and reject larger requests without partial transmission. This limit is
  configurable for projects with unusually large generated files.
- **Diagnostic presentation:** signs and underlines enabled, virtual text
  disabled, with details shown on demand.
- **Pi executable — `pi`:** resolve it from the environment. A custom executable
  path may be supplied, but the plugin does not expose a second model or tool
  configuration layer.

There is intentionally no Neovim setting that makes headless Pi read-only or
maintains a separate headless tool list. Tool and permission configuration
belongs to Pi so terminal and headless behaviour do not drift.

## Implementation sequence

### Phase 1 — Prove Pi integration points

Build disposable vertical spikes before establishing abstractions:

1. Load the companion extension in interactive Pi, opt in, connect over a Unix
   socket, and inject idle, steering, and follow-up messages.
2. Spawn persistent `pi --mode rpc`, send a prompt, observe tool and completion
   events, stop it, and resume the same session.
3. Exercise an RPC extension permission dialog through a minimal client.
4. Verify that a headless Pi launched without a tool allowlist can edit a file
   in a disposable project and that the edit event identifies the path.
5. Verify extension behaviour when the companion is both installed normally and
   passed explicitly, preventing duplicate tools, commands, or sockets.

Stop and revise the design at the first failed end-to-end check.

### Phase 2 — Package skeleton and protocol

- Add the Lua plugin and TypeScript package structure.
- Define versioned context-bundle/socket message types and runtime descriptors.
- Implement validators, payload limits, JSONL framing, and error responses.
- Add `:checkhealth` checks for Neovim/Pi versions, executable discovery,
  runtime-directory permissions, and companion-extension availability.
- Add fake socket and RPC peers for deterministic tests.

Verification: headless Neovim exchanges fragmented and combined JSONL messages
with both fake peers, including non-ASCII data and embedded newlines.

### Phase 3 — Interactive terminal vertical slice

- Implement `/nvim-bridge`, descriptor lifecycle, and socket handshake.
- Implement project discovery and exact-root attachment.
- Implement the project context draft with extmark-backed ranged and whole-file
  items, refusing modified or externally stale buffers.
- Add item notes, overall request text, inspection, reordering, refresh,
  removal, and clear operations.
- Send ordered multi-file bundles into an idle terminal Pi conversation.
- Keep `:PiSend` as an immediate one-item path independent of the draft.
- Add busy-state steer/follow-up selection and multi-session selection.

Verification: several saved ranges from different files appear exactly once,
in draft order, with the correct paths, ranges, item notes, and overall note in
the chosen existing Pi conversation. Modified and externally stale buffers are
refused without sending anything, and a failed send preserves the draft.

### Phase 4 — Findings loop

- Register and validate `nvim_publish_findings`.
- Deliver tool results over socket and RPC transports.
- Reconstruct active findings from the current Pi session branch.
- Render diagnostics and implement navigation, replies, and clears.
- Revalidate expected text and mark stale findings.

Verification: multiple findings survive buffer close/reopen and extension
reload; editing an anchored line marks only the affected finding stale; replies
continue in the originating conversation.

### Phase 5 — Headless fallback

- Implement lazy RPC process startup and startup-failure reporting.
- Add project session persistence and resume.
- Normalize RPC state and events into the session interface.
- Implement all supported extension-UI request types needed by permission
  extensions.
- Add progress, known-change reporting, response buffer, stop, and terminal
  handoff instructions.
- Handle child exit, Neovim exit, and interrupted turns.

Verification: with no terminal Pi running, one explicit send starts a headless
worker using existing Pi authentication and settings; it can investigate and
edit a disposable project, reports completion and known changed files, returns
findings, and resumes the same conversation after restart.

### Phase 6 — Hardening and documentation

- Handle stale descriptors, malformed messages, version mismatch, missing
  authentication/model, renamed/deleted files, symlinks, and project changes.
- Guard against duplicate session ownership where the bridge can observe it.
- Test modified Neovim buffers against external Pi edits without overwriting
  editor content.
- Document installation as both a Neovim plugin and a Pi package.
- Document the unmediated-edit boundary and the Version 2 handoff clearly.
- Run the complete automated suite and both real interactive/headless workflows.

## Test strategy

### Extension tests

Use Node's test runner for:

- descriptor and socket lifecycle;
- protocol validation and size limits;
- project containment;
- finding normalization and persistence reconstruction;
- clear/reply routing;
- shutdown cleanup and stale locks.

### Neovim tests

Run Neovim headlessly against fake peers for:

- exact multi-range, multi-file saved-context capture and ordering;
- refusal of modified and externally stale buffers at add and send time;
- extmark tracking across saved edits, changed-item detection, refresh, and
  invalid-item refusal;
- draft inspection, reordering, removal, preservation on failure, and clearing;
- project/session selection;
- fragmented JSONL and RPC correlation;
- busy delivery choices;
- diagnostics, stale detection, navigation, reply, and clear;
- process failure and cleanup;
- non-ASCII text and line endings;
- external edits with clean and modified buffers.

### End-to-end checks

Use disposable projects for two real workflows:

1. Opted-in terminal Pi receives a multi-file context bundle and publishes
   findings back to Neovim.
2. Neovim starts headless Pi, Pi changes a file with its normal tools, Neovim
   reports the activity, and the persisted session resumes after worker restart.

These checks are required release evidence; unit tests alone are insufficient.

## Definition of done

Version 1 is complete when:

1. No editor content is sent without an explicit action, and no unsaved source
   content is sent under any circumstance.
2. An ordered bundle of saved ranges from multiple files reaches exactly the
   selected project session with its item-level and overall notes intact.
3. No arbitrary same-directory Pi process is treated as a bridge target.
4. Busy sends require an explicit steer/follow-up decision.
5. Headless fallback uses existing Pi authentication and normal capabilities.
6. Configured Pi permission dialogs remain actionable from Neovim.
7. Findings never modify source and stale findings are distinguishable.
8. Replies preserve session association.
9. Known external edits are reported without overwriting modified buffers.
10. A headless conversation persists and can be resumed in terminal Pi after
    its worker stops.
11. The editor has no permanent bridge UI when the workflow is idle.
12. The real terminal and headless end-to-end checks both pass.
