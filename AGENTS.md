# Agent Map

This file is a lightweight starting point for coding agents, not a source of
truth. Confirm behavior in the implementation and tests before making changes.

## Project

pi.nvim is a local bridge between Neovim and [Pi](https://pi.dev). It has two
parts:

- a Lua Neovim plugin that captures saved source, sends context, manages Pi
  sessions, and displays findings as diagnostics;
- a TypeScript Pi extension that serves opted-in terminal sessions, runs in
  headless RPC workers, and publishes findings back to Neovim.

Interactive sessions use a local Unix socket after `/nvim-bridge enable`.
Headless sessions use Pi's NDJSON RPC mode. Pi keeps its normal tools and
permissions; this project is a bridge, not a sandbox or patch-review system.

## Start Here

- `README.md`: user-facing behavior, installation, configuration, and commands.
- `ARCHITECTURE.md`: implementation details, data flow, protocol, and change map.
- `package.json`: available test and typecheck commands.
- `BUGS.md`: previously observed issues; reproduce them before relying on them.
- `PROPOSAL.md`: design background and future direction, not current behavior.

## File Map

```text
plugin/pi.lua                Neovim command entry points
lua/pi/init.lua              public API and command flow
lua/pi/context.lua           saved-file and range capture
lua/pi/draft.lua             context drafts and request bundles
lua/pi/session.lua           target selection and session lifecycle
lua/pi/transport/socket.lua  interactive-session transport
lua/pi/transport/rpc.lua     headless-worker transport
lua/pi/findings.lua          finding storage and diagnostics
lua/pi/ui.lua                prompts and temporary buffers
lua/pi/project.lua           roots, containment, and state paths
lua/pi/health.lua            :checkhealth pi
lua/pi/types.lua             definition-only Lua types
pi-extension/index.ts        Pi extension and socket server
pi-extension/protocol.ts     wire types, validation, and path rules
tests/lua/                   headless Neovim tests
tests/extension/             extension tests
tests/e2e/                   live socket and headless integration tests
```

## Important Seams

- Source context comes from saved files on disk; modified or stale buffers are
  rejected rather than saved or sent.
- Findings are editor diagnostics and do not write source files.
- Root containment and wire shapes cross the Lua/TypeScript boundary. Check
  `lua/pi/types.lua`, `lua/pi/project.lua`, and `pi-extension/protocol.ts`
  together when changing them.
- Interactive discovery is explicit, and headless Pi starts only from a user
  send. Session and transport changes can affect both paths.

## Verification

- `npm test`: Lua tests in headless Neovim.
- `npm run test:extension`: deterministic Pi extension tests.
- `npm run typecheck`: TypeScript and Lua language-server checks.
- `npm run test:e2e`: live integration checks; requires authenticated Pi and
  sends prompts to the configured model provider.

Choose checks based on the files changed. Use `ARCHITECTURE.md` and nearby tests
to locate the relevant behavior rather than expanding this file into a second
manual.
