// What the model actually reads. formatContextEnvelope is the last step before
// a Neovim send reaches Pi's input, and it has to serve two shapes that arrive
// on the same wire: draft excerpts, which quote source, and the pointers
// :PiSend produces, which quote nothing and leave the reading to Pi. Offline
// and pure — protocol.ts touches neither Pi nor the filesystem.

import assert from "node:assert/strict";
import test from "node:test";

import { formatContextEnvelope } from "../../pi-extension/protocol.ts";

const envelope = (contexts, note = "have a look") =>
  JSON.stringify({ id: "request", root: "/project", note, contexts });

test("a pointer names the location and carries no source", () => {
  const formatted = formatContextEnvelope(
    envelope([{ id: "item", path: "lua/pi/init.lua", cursor_line: 312, note: "" }]),
  );
  // The path is absolute: Pi's working directory can be any subdirectory of the
  // project root it was matched on, and a pointer is unreadable if it resolves
  // against the wrong one.
  assert.equal(
    formatted,
    [
      "### Context 1",
      "",
      "- **File path:** `/project/lua/pi/init.lua`",
      "- **Cursor line:** 312",
      "---",
      "have a look",
    ].join("\n"),
  );
  // No fence means no source: the whole point of a pointer is that Pi reads the
  // file itself rather than being handed a copy.
  assert.ok(!formatted.includes("```"));
});

test("an instruction with no context is unwrapped, not passed through as JSON", () => {
  // The editor sends this shape when there was no file to point at. It travels
  // as JSON so Pi cannot mistake a leading "/" for a slash command, which means
  // the model must never be shown the JSON itself.
  assert.equal(formatContextEnvelope(envelope([], "/clear the stale caches")), "/clear the stale caches");
});

test("a selection points at the range instead of the cursor", () => {
  const formatted = formatContextEnvelope(
    envelope([
      { id: "item", path: "lua/pi/init.lua", start_line: 40, end_line: 58, note: "" },
    ]),
  );
  assert.ok(formatted.includes("- **File path:** `/project/lua/pi/init.lua`"));
  assert.ok(formatted.includes("- **Start line:** 40"));
  assert.ok(formatted.includes("- **End line:** 58"));
  assert.ok(!formatted.includes("Cursor line"));
});

test("a file with no location at all is still a usable pointer", () => {
  const formatted = formatContextEnvelope(
    envelope([{ id: "item", path: "empty.txt", note: "" }]),
  );
  assert.equal(
    formatted,
    ["### Context 1", "", "- **File path:** `/project/empty.txt`", "---", "have a look"].join("\n"),
  );
});

test("draft excerpts keep quoting their source", () => {
  const formatted = formatContextEnvelope(
    envelope([
      {
        id: "item",
        kind: "range",
        path: "lua/pi/init.lua",
        start_line: 1,
        end_line: 1,
        text: "local M = {}",
        note: "this line",
      },
    ]),
  );
  assert.equal(
    formatted,
    [
      "### Context 1",
      "",
      "- **File path:** `lua/pi/init.lua`",
      "- **Kind:** `range`",
      "- **Start line:** 1",
      "- **End line:** 1",
      "",
      "```lua",
      "local M = {}",
      "```",
      "> this line",
      "---",
      "have a look",
    ].join("\n"),
  );
});

test("text without a range is refused rather than sent unlocatable", () => {
  const rejected = formatContextEnvelope(
    envelope([{ id: "item", path: "one.txt", text: "alpha", note: "" }]),
  );
  assert.equal(rejected, undefined);
});

test("a plain message is left alone", () => {
  assert.equal(formatContextEnvelope("what does this do?"), undefined);
  assert.equal(formatContextEnvelope('{"note":"no contexts key"}'), undefined);
});
