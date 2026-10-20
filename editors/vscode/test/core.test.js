// Tests of embedded/core.js; run with `bun test` (bun --test).
// Block scalar geometry comes from yamllsp and is tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const {
  globToRe,
  resolveRegions,
  RegionMap,
  decodeTokens,
  encodeTokens,
  mergeSemanticTokens,
} = require("../embedded/core");
const { languageTable, languageOf } = require("../embedded/grammar");

const known = new Set(["python", "shellscript", "sql"]);
const table = languageTable([{ languages: [
  { id: "python", extensions: [".py"] },
  { id: "shellscript", extensions: [".sh"] },
  { id: "sql" },
  { id: "cobol" },
] }]);
const options = (extra = {}) => ({
  languageOf: (name) => languageOf(table, name),
  stickyDirective: "yaml-lsp",
  compatDirective: true,
  keyRules: [],
  isKnownLanguage: (id) => known.has(id),
  docPath: "/w/x.yaml",
  ...extra,
});
const literal = (line, end, extra = {}) => ({
  line, style: "literal", start: line + 1, end, indent: 2, ...extra,
});

test("header comment names the language, through aliases", () => {
  const lines = ["a: | # py", "  import os", "", "  print(1)"];
  const { regions } = resolveRegions(
    [literal(0, 3, { comment: "py", key: "a" })], lines, options());
  assert.equal(regions.length, 1);
  assert.deepEqual(
    { ...regions[0] },
    { ordinal: 0, languageId: "python", provenance: "inline-comment", key: "a",
      headerLine: 0, start: 1, end: 3, indent: 2,
      content: "import os\n\nprint(1)\n" });
});

test("unknown languages and blocks without one are no regions", () => {
  const lines = ["a: | # cobol", "  x", "b: |", "  y"];
  const blocks = [literal(0, 1, { comment: "cobol" }), literal(2, 3)];
  assert.equal(resolveRegions(blocks, lines, options()).regions.length, 0);
});

test("sticky directive applies until cleared, not from block content", () => {
  const lines = [
    "# yaml-lsp: python", "a: |", "  # yaml-lsp: sql", "b: |", "  x",
    "# yaml-lsp", "c: |", "  y",
  ];
  const blocks = [literal(1, 2), literal(3, 4), literal(6, 7)];
  const { regions } = resolveRegions(blocks, lines, options());
  assert.deepEqual(regions.map((r) => [r.headerLine, r.languageId, r.provenance, r.ordinal]),
    [[1, "python", "sticky-directive", 0], [3, "python", "sticky-directive", 1]]);
});

test("compatible directive only when enabled", () => {
  const lines = ["# yaml-embedded-languages: sh", "a: |", "  x"];
  assert.equal(resolveRegions([literal(1, 2)], lines, options()).regions[0].languageId,
    "shellscript");
  assert.equal(resolveRegions([literal(1, 2)], lines,
    options({ compatDirective: false })).regions.length, 0);
});

test("key rules, with file patterns, have the lowest precedence", () => {
  const keyRules = [
    { keyPattern: "^run$", language: "shellscript", filePattern: "**/.github/workflows/*.yml" },
    { keyPattern: "^query$", language: "sql" },
    { keyPattern: "(", language: "python" },
  ];
  const lines = ["run: |", "  x", "query: |", "  y", "run: | # python", "  z"];
  const blocks = [literal(0, 1, { key: "run" }), literal(2, 3, { key: "query" }),
    literal(4, 5, { key: "run", comment: "python" })];
  const at = (docPath) => resolveRegions(blocks, lines, options({ keyRules, docPath }))
    .regions.map((r) => [r.headerLine, r.languageId, r.provenance]);
  assert.deepEqual(at("/w/x.yaml"),
    [[2, "sql", "key-rule"], [4, "python", "inline-comment"]]);
  assert.deepEqual(at("/w/.github/workflows/ci.yml"),
    [[0, "shellscript", "key-rule"], [2, "sql", "key-rule"], [4, "python", "inline-comment"]]);
});

test("folded blocks are reported, not projected", () => {
  const lines = ["a: > # python", "  x"];
  const r = resolveRegions([{ ...literal(0, 1, { comment: "python" }), style: "folded" }],
    lines, options());
  assert.deepEqual(r, { regions: [], folded: [{ headerLine: 0, languageId: "python" }] });
});

test("globToRe", () => {
  assert.ok(globToRe("**/*.yml").test("/a/b/c.yml"));
  assert.ok(globToRe("**/*.yml").test("c.yml"));
  assert.ok(!globToRe("*.yml").test("a/c.yml"));
  assert.ok(globToRe("a?.yaml").test("ab.yaml"));
});

test("RegionMap is an offset, clamped to the region", () => {
  const m = new RegionMap({ start: 3, end: 5, indent: 4 });
  assert.ok(m.containsLine(3) && m.containsLine(5) && !m.containsLine(2) && !m.containsLine(6));
  assert.deepEqual(m.toProjection({ line: 4, character: 6 }), { line: 1, character: 2 });
  assert.deepEqual(m.toProjection({ line: 4, character: 1 }), { line: 1, character: 0 });
  assert.deepEqual(m.toHost({ line: 1, character: 2 }), { line: 4, character: 6 });
  assert.deepEqual(m.toHostRange({ start: { line: 0, character: 0 }, end: { line: 9, character: 1 } }),
    { start: { line: 3, character: 4 }, end: { line: 5, character: 5 } });
  assert.equal(m.reindent("a\nb\n\nc"), "a\n    b\n\n    c");
  assert.equal(new RegionMap({ start: 0, end: 0, indent: 0 }).reindent("a\nb"), "a\nb");
});

test("token encoding round-trips", () => {
  const data = [0, 2, 3, 1, 0, 0, 4, 1, 2, 1, 2, 0, 5, 0, 0];
  assert.deepEqual([...encodeTokens(decodeTokens(data))], data);
});

test("embedded tokens replace yamllsp's on content lines, by name", () => {
  const legend = { tokenTypes: ["comment", "string", "property", "keyword"],
                   tokenModifiers: ["declaration"] };
  // a: | # py      -> property, comment
  //   def f(): x   -> string (yamllsp's view of the content)
  // b: 1           -> property
  const host = encodeTokens([
    { line: 0, character: 0, length: 1, type: 2, modifiers: 0 },
    { line: 0, character: 5, length: 4, type: 0, modifiers: 0 },
    { line: 1, character: 2, length: 10, type: 1, modifiers: 0 },
    { line: 2, character: 0, length: 1, type: 2, modifiers: 0 },
  ]);
  const embedded = {
    map: new RegionMap({ start: 1, end: 1, indent: 2 }),
    legend: { tokenTypes: ["function", "keyword"], tokenModifiers: ["readonly", "declaration"] },
    data: encodeTokens([
      { line: 0, character: 0, length: 3, type: 1, modifiers: 0 },
      { line: 0, character: 4, length: 1, type: 0, modifiers: 3 }, // no "function" in legend
      { line: 5, character: 0, length: 1, type: 1, modifiers: 2 }, // outside the region
    ]),
  };
  assert.deepEqual(decodeTokens(mergeSemanticTokens(host, legend, [embedded])), [
    { line: 0, character: 0, length: 1, type: 2, modifiers: 0 },
    { line: 0, character: 5, length: 4, type: 0, modifiers: 0 },
    { line: 1, character: 2, length: 3, type: 3, modifiers: 0 },
    { line: 2, character: 0, length: 1, type: 2, modifiers: 0 },
  ]);
});
