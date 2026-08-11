# Contributor Guide

## Project Overview

pi.nvim is a two-part bridge between Neovim and Pi:

- The Lua plugin captures saved source, manages per-project context drafts and
  sessions, and renders findings as Neovim diagnostics.
- The TypeScript Pi extension exposes an explicitly enabled local socket for
  interactive sessions and adds the `nvim_publish_findings` tool.

The same extension is loaded by headless Pi workers over RPC. Read
`ARCHITECTURE.md` before changing transport, session, context, or findings
behavior.

## Core Invariants

Preserve these behaviors unless a change explicitly replaces them:

1. Only saved, on-disk source is sent. Never save a buffer for the user or send
   unsaved content.
2. Pi never starts or receives steering input without an explicit user action.
3. Interactive session discovery is opt-in through `/nvim-bridge enable`.
   Sharing a project root is not sufficient.
4. Findings are diagnostics and never write source files.
5. Modified buffers are never automatically reloaded after Pi changes a file.
6. Both sides must agree on the wire version and canonical project root.
7. Oversized context bundles are rejected as a whole rather than truncated.

Pi workers inherit the user's normal Pi settings, authentication, extensions,
tools, and permission policy. They are not read-only or sandboxed. Edit/write
events are only reload hints and must not be presented as a complete audit log.

## Repository Layout

```text
plugin/pi.lua                 :Pi* command definitions and startup entry point
lua/pi/init.lua               public setup and user-visible command flow
lua/pi/context.lua            saved-buffer and range capture
lua/pi/draft.lua              context drafts, bundling, and wire envelope
lua/pi/session.lua            discovery, attach, headless lifecycle, state
lua/pi/transport/socket.lua   interactive Pi socket client
lua/pi/transport/rpc.lua      headless Pi RPC client
lua/pi/findings.lua           finding storage and Neovim diagnostics
lua/pi/ui.lua                 prompts, pickers, and scratch buffers
lua/pi/project.lua            project roots, containment, persisted state paths
lua/pi/health.lua             :checkhealth pi checks
lua/pi/types.lua              definition-only Lua types
pi-extension/index.ts         Pi commands, socket server, and findings tool
pi-extension/protocol.ts      wire types, validation, and path handling
tests/                        Lua, extension, and end-to-end coverage
```

## Development Commands

Install JavaScript dependencies with `npm install`.

```sh
npm test
npm run test:extension
npm run typecheck
```

- `npm test` runs deterministic Lua tests in headless Neovim.
- `npm run test:extension` checks that the Pi extension loads over RPC.
- `npm run typecheck` runs strict TypeScript checking and Lua language-server
  diagnostics. It requires `nvim` and `lua-language-server` on `PATH`.
- `npm run test:e2e` exercises a real opted-in socket and a live headless model
  turn. It requires an installed, authenticated Pi and sends the test prompt to
  the configured model provider.

Run the deterministic tests and type checks for normal changes. Run end-to-end
tests when changing discovery, transports, RPC handling, session lifecycle, or
the extension integration and the required model access is available.

## Type and Protocol Changes

Lua records marked `wire` in `lua/pi/types.lua` have hand-maintained TypeScript
counterparts in `pi-extension/protocol.ts`; update both sides together.

The repository pins the native TypeScript 7 compiler, which does not ship
`tsserver`. To use the same compiler in Neovim that `npm run typecheck` uses:

```lua
vim.lsp.config("tsgo", {
  cmd = { "node_modules/.bin/tsc", "--lsp", "--stdio" },
  filetypes = { "typescript" },
  root_markers = { "tsconfig.json", "package.json", ".git" },
})
vim.lsp.enable("tsgo")
```

`.luarc.json` points `workspace.library` at `$VIMRUNTIME/lua`. The Lua typecheck
script obtains that path from Neovim instead of recording a machine-specific
path in the repository.

When changing the socket protocol, update both transports and the extension.
Bump the protocol version for incompatible changes. Keep source text and notes
as JSON data rather than interpolating them into protocol structure.

## Change Map

| Goal | Start at |
| --- | --- |
| Add or change a `:Pi*` command | `plugin/pi.lua` and `lua/pi/init.lua` |
| Change capture or stale-buffer rules | `lua/pi/context.lua` |
| Change draft behavior or message payloads | `lua/pi/draft.lua` |
| Change target selection or fallback behavior | `lua/pi/init.lua` and `lua/pi/session.lua` |
| Change interactive bridge requests or events | `lua/pi/transport/socket.lua` and `pi-extension/index.ts` |
| Change headless RPC behavior | `lua/pi/transport/rpc.lua` |
| Change findings rendering or staleness | `lua/pi/findings.lua` |
| Change root or containment rules | `lua/pi/project.lua` and `pi-extension/protocol.ts` |

Keep the public README focused on installation, setup, workflows, configuration,
commands, and user-visible limitations. Put implementation details here or in
`ARCHITECTURE.md`.
