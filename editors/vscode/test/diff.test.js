// Tests of diff/format.js; run with `bun test`. The changes themselves come
// from yamllsp and are tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const { sideOf, changePath, changeValues, summary, pickItems, isJson, errorMessage } =
  require("../diff/format");

const change = (kind, extra = {}) => ({
  kind, document: 0, oldPointer: "/a/1", oldPath: "$.a[1]", newPointer: "/a/0",
  newPath: "$.a[0]", ...extra,
});

test("the side of a change is where its node is", () => {
  assert.equal(sideOf(change("added")), "new");
  assert.equal(sideOf(change("changed")), "new");
  assert.equal(sideOf(change("removed")), "old");
});

test("paths in either format, the root, and documents", () => {
  assert.equal(changePath(change("changed"), "pointer", [1, 1]), "/a/0");
  assert.equal(changePath(change("removed"), "pointer", [1, 1]), "/a/1");
  assert.equal(changePath(change("changed"), "path", [1, 1]), "$.a[0]");
  assert.equal(changePath(change("changed"), undefined, [1, 1]), "/a/0");
  assert.equal(changePath(change("changed", { newPointer: "" }), "pointer", [1, 1]), "(root)");
  assert.equal(changePath(change("changed", { document: 1 }), "pointer", [1, 2]), "#2 /a/0");
  assert.equal(changePath(change("added", { document: 1, newPointer: "" }), "pointer", [1, 2]), "#2");
});

test("values on one line", () => {
  assert.equal(changeValues(change("added", { new: "x" })), "x");
  assert.equal(changeValues(change("removed", { old: "y" })), "y");
  assert.equal(changeValues(change("changed", { old: "1", new: "2" })), "1 → 2");
});

test("a summary by kind", () => {
  assert.equal(summary([change("changed"), change("added"), change("changed")]), "2 changed, 1 added");
  assert.equal(summary([change("removed")]), "1 removed");
  assert.equal(summary([]), "no changes");
});

test("quick pick items keep their changes", () => {
  const c = change("changed", { old: "1", new: "2" });
  const [item] = pickItems({ documents: [1, 1], changes: [c] }, "pointer");
  assert.equal(item.label, "$(diff-modified) /a/0");
  assert.equal(item.description, "1 → 2");
  assert.equal(item.change, c);
});

test("JSON by language or extension", () => {
  assert.ok(isJson("json"));
  assert.ok(isJson("jsonc"));
  assert.ok(isJson("/x/package.JSON"));
  assert.ok(!isJson("yaml"));
  assert.ok(!isJson("/x/a.yaml"));
  assert.ok(!isJson("/x/a.jsonl"));
});

test("errors name the side", () => {
  assert.equal(errorMessage({ side: "new", line: 2, character: 4, message: "bad" },
    { old: "a.yaml", new: "b.yaml" }), "b.yaml:3:5: bad");
});
