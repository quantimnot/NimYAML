// The injection grammar, package.json and the default aliases must agree
// with syntaxes/generate.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const { LANGUAGES, output, text } = require("../syntaxes/generate");
const manifest = require("../package.json");

test("the grammar is generated from LANGUAGES (npm run grammar)", () => {
  assert.equal(fs.readFileSync(output, "utf8"), text());
});

test("package.json maps every embedded scope to its language", () => {
  const [grammar] = manifest.contributes.grammars;
  assert.equal(grammar.scopeName, JSON.parse(text()).scopeName);
  assert.deepEqual(grammar.embeddedLanguages,
    Object.fromEntries(LANGUAGES.map(([id]) => [`meta.embedded.block.${id}`, id])));
});

test("every name the grammar accepts resolves to the same language", () => {
  const aliases = manifest.contributes.configuration.properties["nimyaml.embedded.aliases"].default;
  for (const [id, , names] of LANGUAGES) {
    for (const name of names) assert.equal(aliases[name], id, name);
  }
});

test("the grammar matches whole comments only", () => {
  const python = new RegExp(JSON.parse(text()).repository.python.begin.replace("(?i:", "(?:"), "i");
  assert.ok(python.test("| # python"));
  assert.ok(python.test("|-2 #py  "));
  assert.ok(python.test("|2+ # Python"));
  assert.ok(!python.test("| # python3"));
  assert.ok(!python.test("> # python"));
  assert.ok(!python.test("| # not python"));
});
