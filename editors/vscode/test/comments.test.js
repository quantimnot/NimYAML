// Tests of comments/rules.js; run with `bun test`.

const test = require("node:test");
const assert = require("node:assert/strict");
const { commentOnEnterRules, MAX_SPACES } = require("../comments/rules");

const NONE = 0;
const rules = commentOnEnterRules(NONE);

// what VS Code appends after the indentation when Enter is pressed with
// `before` to the left of the cursor: the first rule that matches wins
function appended(before) {
  const rule = rules.find((r) => r.beforeText.test(before));
  return rule?.action.appendText;
}

test("a comment continues with its spaces after #", () => {
  assert.equal(appended("# text"), "# ");
  assert.equal(appended("  # text"), "# ");
  assert.equal(appended("    #   indented"), "#   ");
  assert.equal(appended("#text"), "#");
  assert.equal(appended("#"), "#");
  assert.equal(appended("# "), "# ");
  // ends with what increaseIndentPattern matches
  assert.equal(appended("  # Example:"), "# ");
  assert.equal(appended("\t# tab-indented"), "# ");
});

test("more spaces than there are rules for", () => {
  const most = " ".repeat(MAX_SPACES);
  assert.equal(appended("#" + most + "    deep"), "#" + most);
});

test("the indentation is the line's", () => {
  for (const r of rules) assert.equal(r.action.indentAction, NONE);
});

test("not a comment", () => {
  assert.equal(appended("key: value"), undefined);
  assert.equal(appended("key: value # trailing"), undefined);
  assert.equal(appended("- item"), undefined);
  assert.equal(appended(""), undefined);
  assert.equal(appended("#!/usr/bin/env yaml as json"), undefined);
});
