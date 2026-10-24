// Tests of embedded/grammar.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("fs");
const path = require("path");
const {
  languageTable, languageOf, injectionGrammar, embeddedLanguages, grammarText, emptyTable,
  GRAMMAR_PATH,
} = require("../embedded/grammar");

// two extensions' manifests, in extension order
const contributions = [
  {
    languages: [
      { id: "python", aliases: ["Python", "py"], extensions: [".py", ".pyi"] },
      { id: "shellscript", aliases: ["Shell Script", "shell"], extensions: [".sh", ".bash"] },
      { id: "cpp", aliases: ["C++", "Cpp"], extensions: [".cpp", ".h"] },
      { id: "c", aliases: ["C"], extensions: [".c", ".h"] },
      { id: "plaintext", extensions: [".txt"] },
    ],
    grammars: [
      { language: "python", scopeName: "source.python" },
      { language: "shellscript", scopeName: "source.shell" },
      { language: "cpp", scopeName: "source.cpp" },
      { language: "c", scopeName: "source.c" },
      { scopeName: "text.injected", injectTo: ["source.python"] },
    ],
  },
  {
    languages: [{ id: "python", extensions: [".pyw"] }, { id: "jsonc", extensions: [".code-profile"] }],
    grammars: [{ language: "python", scopeName: "source.python.other" }],
  },
];

test("names come from the installed languages", () => {
  const t = languageTable(contributions);
  for (const [name, id] of [
    ["python", "python"], ["Py", "python"], ["pyi", "python"], ["pyw", "python"],
    ["shell script", "shellscript"], ["SH", "shellscript"], ["bash", "shellscript"],
    ["c++", "cpp"], ["c", "c"], ["txt", "plaintext"], ["code-profile", "jsonc"],
  ]) assert.equal(languageOf(t, name), id, name);
  assert.equal(languageOf(t, "nim"), undefined);
  // ids before aliases before extensions; the first extension wins
  assert.equal(languageOf(t, "h"), "cpp");
  assert.equal(t.entries.get("python").scopeName, "source.python");
  assert.equal(t.entries.get("plaintext").scopeName, undefined);
});

test("settings add names and grammars and take precedence", () => {
  const t = languageTable(contributions,
    { h: "c", sql: "nosuchlanguage", sh: "python" },
    { regex: "source.regexp.python", nimble: { scopeName: "source.nim", language: "nim" },
      bash: { scopeName: "source.bash", language: "shellscript" }, bad: {} });
  assert.equal(languageOf(t, "h"), "c");
  assert.equal(languageOf(t, "sh"), "python");
  assert.equal(languageOf(t, "sql"), undefined);
  assert.equal(languageOf(t, "regex"), undefined); // coloured, but no language
  assert.equal(t.entries.get("regex").scopeName, "source.regexp.python");
  assert.equal(languageOf(t, "nimble"), "nim");
  assert.equal(languageOf(t, "nim"), "nim");
  assert.equal(t.entries.get("shellscript").scopeName, "source.bash");
  assert.equal(languageOf(t, "bad"), undefined);
});

const beginOf = (t, key) => {
  const begin = injectionGrammar(t).repository[key].begin;
  // JavaScript has no inline (?i:...): the rule is case-insensitive as a whole
  return new RegExp(begin.replace("(?i:", "(?:"), "i");
};

test("one rule per coloured language, matching whole comments", () => {
  const t = languageTable(contributions, {}, { regex: "source.regexp.python" });
  const g = injectionGrammar(t);
  assert.deepEqual(Object.keys(g.repository).sort(), ["c", "cpp", "python", "regex", "shellscript"]);
  assert.deepEqual(g.patterns.length, 5);
  assert.equal(g.repository.cpp.patterns[0].patterns[0].include, "source.cpp");
  assert.equal(g.repository.cpp.patterns[0].contentName, "meta.embedded.block.cpp");
  const python = beginOf(t, "python");
  for (const s of ["| # python", "|-2 #py  ", "|2+ # Python", "| # pyi"]) assert.ok(python.test(s), s);
  for (const s of ["| # python3", "> # python", "| # not python"]) assert.ok(!python.test(s), s);
  assert.ok(beginOf(t, "cpp").test("| # C++"));
  assert.ok(beginOf(t, "shellscript").test("| # shell script"));
  assert.ok(!beginOf(t, "c").test("| # c++"));
});

test("headers may name the language after a directive", () => {
  const t = languageTable(contributions);
  const begin = injectionGrammar(t, ["yaml-lsp", "yaml-embedded-languages"]).repository.python.begin;
  const python = new RegExp(begin.replace("(?i:", "(?:"), "i");
  for (const s of ["| # yaml-lsp: python", "|- #yaml-lsp:py", "| # yaml-embedded-languages: python"]) {
    assert.ok(python.test(s), s);
  }
  for (const s of ["| # yaml-lsp:", "| # other: python"]) assert.ok(!python.test(s), s);
  assert.ok(!beginOf(t, "python").test("| # yaml-lsp: python"));
});

test("the grammar is written where the manifest declares it", () => {
  const manifest = fs.readFileSync(path.join(__dirname, "..", "package.yaml"), "utf8");
  const declared = /scopeName: yaml\+lsp\.embedded\.injection\s*\n\s*path: (\S+)/.exec(manifest);
  assert.ok(declared, "the grammar contribution in package.yaml");
  assert.equal(GRAMMAR_PATH, path.join(__dirname, "..", declared[1]));
});

test("embeddedLanguages maps the scopes of languages", () => {
  const t = languageTable(contributions, {}, { regex: "source.regexp.python" });
  assert.deepEqual(embeddedLanguages(t), {
    "meta.embedded.block.python": "python",
    "meta.embedded.block.shellscript": "shellscript",
    "meta.embedded.block.cpp": "cpp",
    "meta.embedded.block.c": "c",
  });
});

test("the placeholder grammar has no rules", () => {
  const g = JSON.parse(grammarText(emptyTable()));
  assert.deepEqual([g.patterns, g.repository], [[], {}]);
});
