# pi.nvim

Point an existing [Pi](https://pi.dev) conversation at the code you are looking
at in Neovim, or send exact excerpts of it, and receive review findings back as
native diagnostics.

> [!WARNING]
> pi.nvim is under active development. It works as a prototype, but its API and
> behavior may change.

pi.nvim keeps code navigation in Neovim and the conversation in Pi. Ask about
the file you are in without leaving it, or assemble a draft of excerpts from
several files, without copying source into a terminal. Pi can respond in its
normal terminal UI or run as a project-scoped headless worker managed by
Neovim.

## Features

- Tells Pi where you are — file, selection, or cursor line — and lets it read
  from there, so a question needs no setup
- Builds multi-file context drafts, quoting exact excerpts, before starting a
  Pi turn
- Connects only to Pi terminal sessions that explicitly opt in
- Starts and resumes a headless Pi session when no terminal session is available
- Renders Pi review findings with Neovim diagnostics, without changing source
- Refuses unsaved or externally changed buffers rather than quoting stale code
- Includes configurable `<leader>p` mappings and adds no permanent UI

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
  opts = {},
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
2. Run `/nvim-bridge` in Pi. This toggles that terminal session into or out of
   local discovery by Neovim; `enable` and `disable` are also available.
3. Open a project file in Neovim and run `:PiSend`. To point at a specific
   range, select it first and run `:PiSend` from Visual mode.
4. Enter an instruction when prompted. Pi receives the instruction plus the
   file's project-relative path and where you are in it — the selected range,
   or the line your cursor is on — and reads the file itself.

`:PiSend` sends no source, so it works on any buffer: an empty file, one you
have not written yet, or one with unsaved changes. Pi reads what is on disk, so
pi.nvim warns when that is behind your buffer. With no file at all, the
instruction is sent on its own.

To have Pi work from exact source rather than reading for itself — a quote of
particular lines, or several files at once — build a draft instead:

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

Run `/nvim-bridge` in a Pi terminal to toggle whether only that session is
available to Neovim. Sessions are matched to the current project root. Use
`:PiAttach` or `:PiSessions` when more than one session is available.

The opt-in belongs to that Pi process, not to one conversation: starting a new
session, resuming, forking, or reloading keeps the bridge on and re-advertises
whichever session is now current. Neovim reattaches on the next send. Quitting
Pi ends the opt-in, so a fresh `pi` is invisible until you run `/nvim-bridge`
again.

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
  keymaps = {
    prefix = "<leader>p",
  },
})
```

| Option              | Default              | Description                                                                   |
| ------------------- | -------------------- | ----------------------------------------------------------------------------- |
| `fallback`          | `"ask"`              | Behavior when no terminal Pi is available: `"ask"`, `"headless"`, or `"none"` |
| `resume_headless`   | `true`               | Resume the last persisted headless session for the project                    |
| `max_context_bytes` | `256 * 1024`         | Reject complete context bundles larger than this limit                        |
| `pi_executable`     | `"pi"`               | Pi executable name or path                                                    |
| `extension_path`    | bundled extension    | Override the companion extension used by headless Pi                          |
| `diagnostics`       | signs and underlines | Options passed to `vim.diagnostic.config` for Pi findings                     |
| `keymaps`           | `<leader>p` mappings | Mapping prefix and action suffixes; use `false` to disable all mappings       |
| `which_key`         | Pi group and icon    | WhichKey metadata; use `false` to disable the integration                     |

Pi is never started when Neovim launches. A worker starts only after an
explicit send, subject to `fallback`.

### Keymaps

The default mappings keep all Pi actions under `<leader>p`:

| Mapping      | Modes          | Action                                                        |
| ------------ | -------------- | ------------------------------------------------------------- |
| `<leader>pa` | Normal, Visual | Add the current file or selection to the context draft        |
| `<leader>ps` | Normal, Visual | Send an instruction pointing at the current file or selection |
| `<leader>pS` | Normal         | Send the context draft                                        |
| `<leader>pv` | Normal         | View the context draft                                        |
| `<leader>pd` | Normal         | Delete the context item under the cursor                      |
| `<leader>pr` | Normal         | Refresh the context item under the cursor                     |
| `<leader>pm` | Normal         | Move the context item under the cursor                        |
| `<leader>pc` | Normal         | Clear the context draft                                       |
| `<leader>pA` | Normal         | Attach a Pi session                                           |
| `<leader>pl` | Normal         | List Pi sessions                                              |
| `<leader>pf` | Normal         | Show findings                                                 |
| `<leader>pR` | Normal         | Reply to the finding under the cursor                         |
| `<leader>pC` | Normal         | Clear findings                                                |
| `<leader>po` | Normal         | Open the latest headless response                             |
| `<leader>pi` | Normal         | Inspect status                                                |
| `<leader>pq` | Normal         | Stop the headless worker                                      |

Change the prefix or any action suffix in `setup()`. Set an action to `false`
to leave it unmapped:

```lua
require("pi").setup({
  keymaps = {
    prefix = "<leader>a",
    add_context = "x",
    send_current = "s",
    stop = false,
  },
})
```

Set `keymaps = false` to install no mappings and define your own with
`vim.keymap.set`. If WhichKey is installed, pi.nvim registers the group and a
consistent icon automatically; set `which_key = false` to opt out.

## Commands

| Command                       | Description                                                       |
| ----------------------------- | ----------------------------------------------------------------- |
| `:[range]PiSend [note]`       | Send an instruction that points Pi at the current file or range   |
| `:[range]PiContextAdd [note]` | Add the current saved file or range, quoted, to the project draft |
| `:PiContextShow`              | Open the current project's draft                                  |
| `:PiContextRemove`            | Remove the draft item under the cursor                            |
| `:PiContextRefresh`           | Re-read the draft item under the cursor from disk                 |
| `:PiContextMove {position}`   | Move the draft item under the cursor                              |
| `:PiContextClear`             | Clear the current project's draft                                 |
| `:PiContextSend`              | Send the draft with an overall instruction                        |
| `:PiAttach`                   | Choose and attach an opted-in terminal session                    |
| `:PiSessions`                 | List attached and discoverable sessions                           |
| `:PiFindings`                 | List findings for the current project                             |
| `:PiReply`                    | Reply to the finding under the cursor                             |
| `:PiClear`                    | Clear the finding under the cursor, or all findings               |
| `:PiResponse`                 | Open the latest headless Pi response                              |
| `:PiStatus`                   | Show the bridge mode, activity, and session ID                    |
| `:PiStop`                     | Stop the current headless worker                                  |

When Pi is already working, pi.nvim asks whether the new request should steer
the current turn or wait as a follow-up.

## Safety and Limitations

- Quoted source always comes from saved files on disk. pi.nvim never saves a
  buffer for you, and the draft refuses modified or externally stale buffers
  rather than sending source that has drifted.
- `:PiSend` quotes nothing, so it is allowed where the draft is not. It sends a
  path and a location, and Pi reads the saved file — which is not your buffer if
  you have unsaved changes. pi.nvim warns when that is the case.
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

See [ARCHITECTURE.md](ARCHITECTURE.md) for the implementation and protocol
design. [AGENTS.md](AGENTS.md) provides a concise repository map for coding
agents.
