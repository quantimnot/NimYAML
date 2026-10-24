// Tests of the grid's pure parts, grid/edits.js and grid/webview/model.ts;
// run with `bun test`. The trees and edits themselves come from yamllsp and
// are tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const { minimalEdit } = require("../grid/edits");
const {
  columnsOf, memberOf, displayText, isMultiline, valueOfDraft, stateKey, draftLines,
} = require("../grid/webview/model.ts");

const apply = (before, e) => before.slice(0, e.start) + e.text + before.slice(e.end);

test("minimalEdit replaces only what differs", () => {
  assert.equal(minimalEdit("a: 1\n", "a: 1\n"), null);
  assert.deepEqual(minimalEdit("a: 1  # c\nb: 2\n", "a: 23  # c\nb: 2\n"),
    { start: 3, end: 4, text: "23" });
  // insertions and deletions at the ends
  assert.deepEqual(minimalEdit("ab", "abc"), { start: 2, end: 2, text: "c" });
  assert.deepEqual(minimalEdit("abc", "bc"), { start: 0, end: 1, text: "" });
  // repeated text: prefix and suffix do not overlap
  for (const [before, after] of [["aaa", "aa"], ["aa", "aaaa"], ["x: aa", "x: a"]]) {
    assert.equal(apply(before, minimalEdit(before, after)), after);
  }
});

test("minimalEdit keeps surrogate pairs and CRLF whole", () => {
  // 😀 and 😁 share their high surrogate
  const e = minimalEdit("a: 😀\n", "a: 😁\n");
  assert.deepEqual(e, { start: 3, end: 5, text: "😁" });
  const crlf = minimalEdit("a: 1\r\nb: 2\r\n", "a: 1\nb: 2\r\n");
  assert.equal(apply("a: 1\r\nb: 2\r\n", crlf), "a: 1\nb: 2\r\n");
  assert.notEqual(crlf.start, 5);
});

const s = (text, kind = "string") => ({ kind, text });

test("columns of an array's table", () => {
  const items = [
    { kind: "object", members: [["b", s("1")], ["a", s("2")]] },
    s("x"),
    { kind: "object", members: [["c", s("3")], ["a", s("4")]] },
  ];
  assert.deepEqual(columnsOf(items), ["b", "a", "c"]);
  assert.deepEqual(columnsOf([s("x"), { kind: "array", items: [] }]), []);
  assert.deepEqual(memberOf(items[2], "a"), s("4"));
  assert.equal(memberOf(items[2], "b"), undefined);
  assert.equal(memberOf(s("x"), "a"), undefined);
});

test("scalars as shown and as edited", () => {
  assert.equal(displayText(s("", "null")), "null");
  assert.equal(displayText(s("~", "null")), "~");
  assert.equal(isMultiline(s("a\nb")), true);
  assert.equal(isMultiline(s("1")), false);
  // strings stay strings, whatever they look like
  assert.equal(valueOfDraft(s("x"), "42"), "\"42\"");
  assert.equal(valueOfDraft(s("x"), "a \"q\"\n"), "\"a \\\"q\\\"\\n\"");
  // other scalars are YAML as typed
  assert.equal(valueOfDraft(s("1", "number"), "[1, 2]"), "[1, 2]");
  assert.equal(valueOfDraft(s("1", "number"), "  "), "~");
  assert.deepEqual(draftLines("a\nb"), [{ text: "a", hasBreak: true }, { text: "b", hasBreak: false }]);
});

test("state keys tell documents apart", () => {
  assert.notEqual(stateKey(0, ["a"]), stateKey(1, ["a"]));
  assert.notEqual(stateKey(0, ["0"]), stateKey(0, [0]));
});
