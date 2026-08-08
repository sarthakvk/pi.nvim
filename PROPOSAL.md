# Proposal: Pi–Neovim collaboration bridge

## Decision sought

Adopt a small, editor-first bridge between Neovim and a Pi conversation. The
bridge prefers an existing interactive Pi session, where Pi remains a separate
terminal application and the place where the conversation happens. When no
interactive session is available, Neovim may run a persistent headless Pi
session for the project. Neovim remains the place for reading, navigating, and
making sense of code.

This is not a second chat interface in Neovim. Headless operation is a way to
run the same Pi harness without requiring a terminal to remain open, not a
separate agent implementation.

The work is deliberately split into two versions. Version 1 establishes the
collaboration loop: send editor context to a project Pi conversation and
receive non-source annotations back. Version 2 adds reviewable agent change
proposals.

## Version 1: conversation and non-source annotations

### Context without restating it

From a file in Neovim, you can deliberately send the current selection or file
context to the Pi conversation, together with a short note, question, or
constraint. Pi receives the relevant text, location, and any unsaved editor
content as part of the conversation you are already having.

The interaction starts from the editor. With an interactive session, the
prompt, streamed work, questions, and answers stay in Pi's terminal. With a
headless session, Neovim reports progress and completion and exposes the latest
answer on demand. In either case, you do not have to copy a block, switch
terminals, paste it, and explain where it came from.

### One continuing conversation

The bridge attaches to a Pi session for the current project. Context sent from
Neovim joins that session rather than starting isolated one-off agent runs.
With an interactive session, you retain Pi's normal history, controls,
authentication, model choice, and terminal workflow.

If no suitable interactive session is available, Neovim can deliberately start
a project-scoped Pi process in headless RPC mode. The process uses the existing
Pi installation, authentication, settings, model configuration, extensions,
tools, and permission policies. Its conversation is stored as a normal
persistent Pi session and can later be resumed in a terminal.

Neovim never sends code to an arbitrary Pi process. Starting a headless session
is governed by an explicit user choice or configuration, and multiple suitable
interactive sessions require an explicit selection.

### Deliberate control while work is in progress

When Pi is idle, an editor request begins a normal conversational turn. When
Pi is already working, you can choose whether the new context should redirect
current work or wait as a follow-up. Sending a selection is therefore an
intentional collaboration action, not an invisible background prompt.

Selecting text alone never sends it. The editor remains quiet until you invoke
the bridge.

### Editor-native review findings

Pi can return several review findings to Neovim as non-source annotations
associated with files and ranges. They can be shown, navigated, replied to,
and cleared without adding comments to production files. The explanation and
surrounding discussion remain in the Pi conversation.

A reply to an annotation normally returns to the Pi session that created it.
You can explicitly direct it to another attached Pi conversation when that is
what you intend. Annotations that no longer match the edited text are marked
stale rather than presented as current findings.

### Local, minimal integration

The bridge stays on the local machine and uses the Pi installation and
authentication you already use. It does not require an additional hosted
service, API key, or model vendor commitment.

Neovim adds only on-demand actions for sending context, choosing or starting a
Pi session, viewing returned annotations, and opening the latest headless
response. Interactive-session prompts and streamed work remain in Pi's
terminal. Headless progress is reported without adding a chat window, a
streaming-response mirror, or permanent screen furniture; its latest response
is available in a temporary editor surface when requested.

### Version 1 boundaries

Version 1 does not mediate Pi's file edits or provide accept/reject controls
for them. This boundary is the same for interactive and headless Pi sessions:
if you ask Pi to change code, it uses its normally configured tools and
permissions, and its changes can reach the working tree directly. You review
them using your existing editor and Git workflow. The bridge reports known
file-changing activity but neither treats those changes as accepted nor
promises to keep them isolated from the working tree.

## Version 2: reviewable agent change proposals

Version 2 adds a distinct workflow for requests where Pi is asked to change
code. Pi presents a proposal against the editor/workspace state at the time of
the request; it does not directly become accepted work.

Neovim opens review only when requested, using a temporary diff surface rather
than a permanent agent panel. You can:

- inspect each proposed block beside the current buffer;
- accept or reject an individual block;
- accept or reject the complete proposal;
- edit the resulting code yourself before accepting it.

If you edit the same area while Pi is working, review identifies that overlap
rather than overwriting your newer buffer state. You resolve only those
conflicts with a merge-conflict-style choice between your current code, Pi's
proposal, or a manual edit.

Version 2 keeps proposal review separate from ordinary Git staging. It does
not confuse pre-existing uncommitted work with Pi's changes, and rejecting a
proposal leaves your own edits untouched.

## Typical Version 1 experience

1. You read code in Neovim and select the lines that matter.
2. You invoke “send to Pi,” adding: “I think this cache invalidation is unsafe;
   trace the race before changing anything.”
3. The existing Pi terminal receives that as a normal message with the
   selection and location. You follow its investigation there and continue the
   conversation normally.
4. Pi returns two review findings. Neovim marks the relevant lines without
   modifying the source file.
5. You reply to one finding from its annotation; the reply continues in the
   same Pi conversation.

If no interactive Pi session is available, the same action can start a
headless project session instead. Neovim reports activity and completion,
renders any returned findings, and lets you open the latest prose response on
demand. The persisted session can be stopped and resumed later in Pi's
terminal for a fully interactive conversation.

## Boundaries and honest limitations

- This does not turn a separately launched, unprepared Pi process into a
  bridge target merely because it happens to share a working directory. An
  interactive Pi session must opt into the bridge before Neovim can use it;
  otherwise Neovim starts and owns a distinct headless process.
- A headless Pi session is not read-only. It has the same configured ability to
  write files, run destructive commands, commit, push, or access the network as
  the Pi process that was launched. Those capabilities remain explicit Pi
  policy decisions, not protections supplied by the bridge.
- Version 1 reports known edit and write tool activity but does not provide a
  complete audit boundary: shell commands and external tools may change files
  without identifying every affected path.
- A persisted session must not be opened concurrently by a headless process
  and a terminal Pi process. Neovim stops its worker before handing the session
  off for terminal use.
- Version 1 deliberately does not offer a partial-patch review UI. That
  belongs to Version 2, where it can preserve unsaved work and handle
  overlapping edits reliably.
- Annotations are advisory metadata. They do not replace tests, diagnostics,
  Git history, or human code review.

## Success criteria

Version 1 is successful when it removes the mechanical context-transfer step
without moving understanding or control away from you: Neovim remains the
primary code-reading environment, interactive Pi remains a visible terminal
collaborator when used, headless Pi remains observable and resumable when a
terminal is unnecessary, and annotations never require source-file comments.

Version 2 is successful when it adds a reviewable path for agent edits without
confusing them with your own work or requiring a permanently visible AI UI.
