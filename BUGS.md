# Known bugs

Collected during the readability refactor (commits `1db9d09`..`d9e8042`). That pass was
documentation-only, so none of these were fixed — the refactor deliberately preserved
behavior, including the broken behavior.

**Verification status:** these were spotted by reading the code during the refactor. They
have not been independently reproduced. Confirm each before fixing.

---

## Correctness

### 1. Findings sort line numbers as strings

`lua/pi/findings.lua:83`

`table.sort` compares `a.path .. a.start_line`, so ordering is lexicographic over a
concatenated string. Line 10 sorts before line 9, and the concatenation lets paths
interleave — `a.lua` + `12` and `a.lua1` + `2` produce the same key.

Compare path first, then line number numerically.

### 2. Tool failures still publish findings

`lua/pi/transport/rpc.lua`, `M:receive`

Findings are published from `tool_execution_end` without checking `event.result.isError`.
The extension's own `tool_execution_end` handler *does* check `event.isError`, so the two
paths disagree: a failed tool call can still push annotations into the buffer.

Match the extension's check.

### 3. Cancelling the context note still adds the item

`lua/pi/init.lua`, `M.context_add`

Cancelling the `ui.input` prompt yields `nil`, but `add_with_note(nil)` proceeds and adds
the item with an empty note. Cancel should almost certainly abort the add.

### 4. Final unterminated line is dropped

`pi-extension/index.ts`, `socket.on("end")`

The handler flushes the `StringDecoder` into `buffer` but never parses what it flushed. A
final message arriving without a trailing newline is silently discarded.

### 5. Request and item ids can collide

`lua/pi/init.lua`, `M.send_current`

Both ids are `sha256(hrtime())` with no random component — unlike `draft.new_id`, which
also hashes `math.random()` and the pid. Two ids generated in the same tick are identical,
and the item id and request id are generated the same way.

Reuse `draft.new_id`.

---

## Resource leaks

### 6. Repeated `session_start` leaks the previous server

`pi-extension/index.ts`, `session_start`

`runtime` is replaced without calling `closeServer` on the previous value. If the event
fires twice, the old socket and its descriptor stay on disk, leaving a dead session
advertised as discoverable.

### 7. Failed spawn leaks pipes

`lua/pi/transport/rpc.lua`, `M.start`

On spawn failure the three pipes have already been created and are abandoned without
`:close()`, leaking file descriptors.

---

## Error handling

### 8. Server `error` event is unhandled

`pi-extension/index.ts`, `enable()`

No `error` listener is attached to the server. A failed `listen` (`EADDRINUSE`, `EACCES`)
raises an unhandled `'error'` event, and the user is still told "Pi bridge is enabling".

### 9. `XDG_RUNTIME_DIR=""` reports the wrong directory

`lua/pi/health.lua` vs `lua/pi/session.lua`

Health checks use `vim.env.XDG_RUNTIME_DIR or …`, while `runtime_dir()` also treats `""`
as unset. With the variable set to the empty string, `:checkhealth` reports a different
directory than the one actually in use.

Share one helper.

---

## Dead / misleading UI

### 10. `:PiSessions` selection does nothing

`lua/pi/init.lua`, `M.sessions`

The picker's callback is `function() end`. The command presents a selectable list, but
choosing an entry has no effect.

---

## Tests

### 11. E2E startup detection hardcodes a model name

`tests/e2e/socket.mjs:41`

Startup is detected with `output.includes("gpt-5.6")`. This fails wherever a different
model is configured — it already fails in the current environment, which uses
`gpt-5.4-mini`. Pre-existing and unrelated to the refactor.

Key on something stable in the startup output instead.
