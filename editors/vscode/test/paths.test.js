// Tests of paths/format.js; run with `bun test`. The paths themselves come
// from yamllsp and are tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const { formatOf, pathText, displayText, previewValue, pickItems } = require("../paths/format");

const node = (document, pointer, path, extra = {}) =>
  ({ document, pointer, path, range: { start: { line: 0, character: 0 } }, ...extra });

test("formats, pointer by default", () => {
  assert.equal(formatOf("path").name, "JSON Path");
  assert.equal(formatOf("pointer").name, "JSON Pointer");
  assert.equal(formatOf(undefined).name, "JSON Pointer");
  assert.equal(formatOf("nonsense").key, "pointer");
});

test("the text copied and the text shown", () => {
  const n = node(0, "/a/0", "$.a[0]", { documents: 1 });
  assert.equal(pathText(n, "pointer"), "/a/0");
  assert.equal(pathText(n, "path"), "$.a[0]");
  assert.equal(displayText(n, "path"), "$.a[0]");
  // the root's pointer is empty
  assert.equal(pathText(node(0, "", "$"), "pointer"), "");
  assert.equal(displayText(node(0, "", "$", { documents: 1 }), "pointer"), "(root)");
  // the document is shown when there are several
  assert.equal(displayText(node(1, "/b", "$.b", { documents: 3 }), "pointer"), "#2 /b");
});

test("values on one line", () => {
  assert.equal(previewValue(undefined), "");
  assert.equal(previewValue("x\ny\r\nz"), "x↵y↵z");
});

test("quick pick items, with a separator per document when there are several", () => {
  const one = pickItems([node(0, "", "$"), node(0, "/a", "$.a", { value: "1\n" })], "path");
  assert.deepEqual(one.map((i) => [i.label, i.description, i.kind]),
    [["$", "", undefined], ["$.a", "1↵", undefined]]);
  assert.equal(one[1].node.pointer, "/a");
  const two = pickItems([node(0, "", "$"), node(1, "", "$"), node(1, "/0", "$[0]")], "pointer");
  assert.deepEqual(two.map((i) => [i.label, i.kind]), [
    ["Document 1", -1], ["(root)", undefined],
    ["Document 2", -1], ["(root)", undefined], ["/0", undefined]]);
});
