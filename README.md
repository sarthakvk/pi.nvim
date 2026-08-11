# pi.nvim

Send saved code from Neovim to an existing [Pi](https://pi.dev) conversation
and receive review findings back as native diagnostics.

> [!WARNING]
> pi.nvim is under active development. It works as a prototype, but its API and
> behavior may change.

pi.nvim keeps code navigation in Neovim and the conversation in Pi. Send a
file, a visual selection, or a draft assembled from several files without
copying source into a terminal. Pi can respond in its normal terminal UI or run
as a project-scoped headless worker managed by Neovim.

## Features

- Sends files and line ranges with their project-relative locations
- Builds multi-file context drafts before starting a Pi turn
- Connects only to Pi terminal sessions that explicitly opt in
- Starts and resumes a headless Pi session when no terminal session is available
- Renders Pi review findings with Neovim diagnostics, without changing source
- Refuses unsaved or externally changed buffers instead of sending stale code
- Adds no default mappings or permanent UI

## Requirements

- Neovim 0.10 or newer
- [Pi](https://pi.dev) 0.83 or newer, installed as `pi` and authenticated

## Installation

pi.nvim has two parts: the Neovim plugin and a companion Pi package. Install
both from this repository.

First, install the Pi package:

```sh
pi install git:github.com/sarthakvk/pi.nvim
```

Then install the Neovim plugin with your plugin manager.

### lazy.nvim

```lua
{
  "sarthakvk/pi.nvim",
  config = function()
    require("pi").setup()
  end,
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  "https://github.com/sarthakvk/pi.nvim",
})

require("pi").setup()
```

For local development, point your plugin manager at the checkout and install
the same checkout as the Pi package:

```sh
pi install /absolute/path/to/pi.nvim
```

Run `:checkhealth pi` after installation to verify the integration.

## Quick Start

1. Start Pi from the root of your project.
2. Run `/nvim-bridge enable` in Pi. This opts that terminal session into local
   discovery by Neovim.
3. Open a saved project file in Neovim and run `:PiSend`. To send only a visual
   selection, select it first and run `:PiSend` from Visual mode.
4. Enter an instruction when prompted. The source, path, line range, and
   instruction are sent to the opted-in Pi conversation.

For a request that needs several files, build a draft instead:

```vim
:PiContextAdd explain how this type is used
:PiContextAdd compare this implementation
:PiContextShow
:PiContextSend
```

Run `:PiFindings` to list review findings Pi has published. From a finding or
its source range, use `:PiReply` to continue the conversation or `:PiClear` to
remove it.

## How Sessions Work

### Interactive Pi

Run `/nvim-bridge enable` in a Pi terminal to make only that session available
to Neovim. Sessions are matched to the current project root. Use `:PiAttach` or
`:PiSessions` when more than one session is available.

The prompt, streamed response, and normal Pi controls remain in the terminal.
Closing Neovim does not stop an interactive Pi session.

### Headless Pi

If no opted-in terminal session is available, the default `fallback = "ask"`
prompts before starting Pi in RPC mode. The worker uses your existing Pi
authentication, model, settings, extensions, tools, and permission policy.

Use `:PiResponse` to open its latest response, `:PiStatus` to inspect it, and
`:PiStop` to stop it. Headless sessions are persisted per project and can be
resumed later.

## Configuration

The defaults are suitable for most installations:

```lua
require("pi").setup({
  fallback = "ask",
  resume_headless = true,
  max_context_bytes = 256 * 1024,
  pi_executable = "pi",
  diagnostics = {
    signs = true,
    underline = true,
    virtual_text = false,
  },
})
```

| Option | Default | Description |
| --- | --- | --- |
| `fallback` | `"ask"` | Behavior when no terminal Pi is available: `"ask"`, `"headless"`, or `"none"` |
| `resume_headless` | `true` | Resume the last persisted headless session for the project |
| `max_context_bytes` | `256 * 1024` | Reject complete context bundles larger than this limit |
| `pi_executable` | `"pi"` | Pi executable name or path |
| `extension_path` | bundled extension | Override the companion extension used by headless Pi |
| `diagnostics` | signs and underlines | Options passed to `vim.diagnostic.config` for Pi findings |

Pi is never started when Neovim launches. A worker starts only after an
explicit send, subject to `fallback`.

## Commands

| Command | Description |
| --- | --- |
| `:[range]PiSend [note]` | Send the current saved file or range immediately |
| `:[range]PiContextAdd [note]` | Add the current saved file or range to the project draft |
| `:PiContextShow` | Open the current project's draft |
| `:PiContextRemove` | Remove the draft item under the cursor |
| `:PiContextRefresh` | Re-read the draft item under the cursor from disk |
| `:PiContextMove {position}` | Move the draft item under the cursor |
| `:PiContextClear` | Clear the current project's draft |
| `:PiContextSend` | Send the draft with an overall instruction |
| `:PiAttach` | Choose and attach an opted-in terminal session |
| `:PiSessions` | List attached and discoverable sessions |
| `:PiFindings` | List findings for the current project |
| `:PiReply` | Reply to the finding under the cursor |
| `:PiClear` | Clear the finding under the cursor, or all findings |
| `:PiResponse` | Open the latest headless Pi response |
| `:PiStatus` | Show the bridge mode, activity, and session ID |
| `:PiStop` | Stop the current headless worker |

When Pi is already working, pi.nvim asks whether the new request should steer
the current turn or wait as a follow-up.

## Safety and Limitations

- Context always comes from saved files on disk. pi.nvim never saves a buffer
  for you and refuses modified or externally stale buffers.
- The bridge transport stays on the local machine, but Pi sends prompts and
  source to whichever model provider you configured.
- Pi is not made read-only or sandboxed. It retains its normal tools and
  permissions and can modify the working tree.
- pi.nvim reports `edit` and `write` activity it recognizes, but shell commands
  and third-party tools can change files without forming a complete audit trail.
- Findings are editor diagnostics, not source comments. They are marked stale
  when their expected source no longer matches.
- pi.nvim does not provide accept/reject or patch-staging controls. Review Pi's
  changes with your normal editor and Git workflow.

## Development

Contributor guidance lives in [AGENTS.md](AGENTS.md). See
[ARCHITECTURE.md](ARCHITECTURE.md) for the implementation and protocol design.
