// Tests of paths/format.js; run with `bun test`. The paths themselves come
// from yamllsp and are tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const { formatOf, fragmentOf, pathText, displayText, previewValue, pickItems } =
  require("../paths/format");

const node = (document, pointer, path, extra = {}) =>
  ({ document, pointer, path, range: { start: { line: 0, character: 0 } }, ...extra });

test("formats, pointer by default", () => {
  assert.equal(formatOf("path").name, "JSON Path");
  assert.equal(formatOf("pointer").name, "JSON Pointer");
  assert.equal(formatOf(undefined).name, "JSON Pointer");
  assert.equal(formatOf("nonsense").key, "pointer");
  assert.equal(formatOf("fragment").name, "URL Fragment");
});

test("URL fragments, as in RFC 6901 section 6", () => {
  const examples = [
    ["", "#"], ["/foo", "#/foo"], ["/foo/0", "#/foo/0"], ["/", "#/"],
    ["/a~1b", "#/a~1b"], ["/c%d", "#/c%25d"], ["/e^f", "#/e%5Ef"],
    ["/g|h", "#/g%7Ch"], ["/i\\j", "#/i%5Cj"], ['/k"l', "#/k%22l"],
    ["/ ", "#/%20"], ["/m~0n", "#/m~0n"],
  ];
  for (const [pointer, fragment] of examples) assert.equal(fragmentOf(pointer), fragment);
  // what a fragment may hold is kept, anything else is UTF-8 percent-encoded
  assert.equal(fragmentOf("/a:b@c/d?e/!$&'()*+,;=-._"), "#/a:b@c/d?e/!$&'()*+,;=-._");
  assert.equal(fragmentOf("/#/[0]/{x}/<y>/`"), "#/%23/%5B0%5D/%7Bx%7D/%3Cy%3E/%60");
  assert.equal(fragmentOf("/größe/日本"), "#/gr%C3%B6%C3%9Fe/%E6%97%A5%E6%9C%AC");
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

test("URL fragments, relative or after the file's URI", () => {
  const n = node(0, "/a b/0", "$['a b'][0]", { documents: 1 });
  assert.equal(pathText(n, "fragment"), "#/a%20b/0");
  assert.equal(pathText(n, "fragment", "file:///home/me/x%20y.yaml"),
    "file:///home/me/x%20y.yaml#/a%20b/0");
  // the URI is only for fragments
  assert.equal(pathText(n, "pointer", "file:///x.yaml"), "/a b/0");
  // the root's fragment is shown as it is, and always without the URI
  assert.equal(displayText(node(0, "", "$", { documents: 1 }), "fragment"), "#");
  assert.equal(displayText(node(1, "/b", "$.b", { documents: 2 }), "fragment"), "#2 #/b");
  assert.deepEqual(pickItems([node(0, "", "$"), node(0, "/a", "$.a")], "fragment")
    .map((i) => i.label), ["#", "#/a"]);
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
