# pi.nvim

> **WARNING**: This is currently in development phase, I built this as a prototype with pi, it works but it is sloppy, I am currently working on that.

A local, editor-first bridge from Neovim to [Pi](https://pi.dev). It sends only
saved source text to an opted-in Pi terminal session or a project-scoped
headless Pi RPC worker. Pi remains the conversation UI; Neovim provides context
capture and non-source review annotations.

## Requirements

- Neovim 0.10 or newer
- Pi 0.83 or newer, available as `pi`

Install this repository as both a Neovim plugin and a Pi package. For a local
checkout, load the Lua plugin through your plugin manager and install the Pi
package with:

```sh
pi install /absolute/path/to/pi.nvim
```

## Configuration

`fallback` defaults to `"ask"`: a send with no attached terminal Pi asks before
starting headless Pi. `"headless"` starts one after an explicit send; `"none"`
reports that no target exists. Pi never starts at Neovim startup.

`resume_headless` defaults to `true`, reusing the last persisted Pi session for
the project when its worker is not running. `max_context_bytes` defaults to
256 KiB and rejects oversized complete bundles rather than truncating them.

`diagnostics` defaults to signs and underlines on with virtual text off.
`pi_executable` defaults to `"pi"`; `extension_path` normally needs no change.
The headless worker deliberately inherits normal Pi settings, extensions,
tools, authentication, and permission policy. It is **not** read-only.

```lua
require("pi").setup({
  fallback = "ask",
  max_context_bytes = 256 * 1024,
})
```

## Workflow

1. In an interactive Pi terminal for the same project, run `/nvim-bridge enable`.
   This creates a user-private local socket descriptor; arbitrary Pi processes
   are never discovered just from their working directory.
2. In Neovim, use `:PiContextAdd` on a saved file or range, optionally adding a
   note. Repeat for other files/ranges, then inspect with `:PiContextShow`.
3. Use `:PiContextSend` for an overall instruction. `:PiSend` sends the current
   saved file/range immediately without changing the draft.
4. Pi may call `nvim_publish_findings`; annotations are diagnostics, not source
   comments. Use `:PiFindings`, `:PiReply`, and `:PiClear` to work with them.

When Pi is busy, the bridge explicitly asks whether to steer the current work
or queue a follow-up. Modified or externally stale buffers are refused on both
add and send; the bridge never saves a buffer or transmits its unsaved content.

## Commands

- `:PiContextAdd [note]`, `:PiContextShow`, `:PiContextRemove`,
  `:PiContextRefresh`, `:PiContextMove {position}`, `:PiContextClear`,
  `:PiContextSend`
- `:PiSend [note]`, `:PiAttach`, `:PiSessions`, `:PiStatus`, `:PiStop`
- `:PiFindings`, `:PiReply`, `:PiClear`, `:PiResponse`

No mappings or permanent UI are installed. `:checkhealth pi` checks the local
integration.

## Verification

`npm test` and `npm run test:extension` are deterministic local checks.
`npm run test:e2e` exercises the opted-in bridge socket and a real headless Pi
turn, so it requires an authenticated Pi model and sends the test prompt to its
configured provider.

## Boundaries

Version 1 does not isolate, accept, reject, or stage Pi edits. Pi tools can
change the working tree according to their normal configuration. The bridge
reports `edit`/`write` activity it can identify and never reloads a modified
Neovim buffer automatically; shell and third-party tool changes cannot form a
complete audit trail. Use your normal editor and Git workflow to review edits.
