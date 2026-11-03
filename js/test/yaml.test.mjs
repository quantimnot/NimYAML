// yaml.mjs, the library's API over JavaScript values, and cli.mjs on the
// in-memory host. The yaml command itself is tested by the native suite,
// test/tyamlcli.nim, which runs against this build with
// YAML_CLI_COMMAND="node js/bin/yaml.mjs".

import { test } from "node:test";
import assert from "node:assert/strict";
import * as Y from "../yaml.mjs";
import { run } from "../cli.mjs";
import { memoryHost } from "../hosts/memory.mjs";

test("load and loadAll: YAML to values, Unicode kept", () => {
  assert.deepEqual(Y.loadAll("a: 1\nb: [x, 2.5, true, null]\nc: é😀\n---\n- 3\n"),
    [{ a: 1, b: ["x", 2.5, true, null], c: "é😀" }, [3]]);
  assert.deepEqual(Y.load("{\"json\": [1]}"), { json: [1] });
  // quoted, a scalar is a string whatever it looks like
  assert.deepEqual(Y.load("a: \"80\"\nb: 'true'\nc: |\n  1\n"),
    { a: "80", b: "true", c: "1\n" });
  assert.throws(() => Y.load("a\n---\nb\n"), /expected one document, found 2/);
});

test("a parse error is a YamlError with its position", () => {
  assert.throws(() => Y.load("a: [\n"), (e) =>
    e instanceof Y.YamlError && e.kind === "YamlParserError" &&
    e.line === 2 && e.column === 1);
});

test("dump: styles decided by the dumper; strings that look typed keep quotes", () => {
  const value = { a: 1, b: ["x", { c: null }], n: "80", s: "é" };
  assert.equal(Y.dump(value), "a: 1\nb:\n  - x\n  - c: null\nn: \"80\"\ns: é\n");
  assert.deepEqual(Y.load(Y.dump(value)), value);
  assert.deepEqual(JSON.parse(Y.dump(value, { style: "json" })), value);
  assert.throws(() => Y.dump(1, { style: "nope" }), /unknown style/);
});

test("lint", () => {
  const [d] = Y.lint("a: 1\na: 2\n");
  assert.equal(d.rule, "duplicate-key");
  assert.deepEqual(d.start, { line: 2, column: 1 });
  assert.equal(Y.lint("k: yes\n", { config: "rules:\n  truthy: {level: off}\n" }).length, 0);
});

test("validate: JSON Schema output", () => {
  const schema = { type: "object", properties: { a: { type: "integer" } } };
  assert.equal(Y.validate({ a: 1 }, schema).valid, true);
  const result = Y.validate({ a: "x" }, schema);
  assert.equal(result.valid, false);
  assert.ok(result.errors.some((e) => e.instanceLocation === "/a"));
  assert.deepEqual(Y.validate({ a: "x" }, schema, { format: "flag" }), { valid: false });
});

test("query, patches, diff", () => {
  assert.deepEqual(Y.query({ a: [{ b: 1 }, { b: 2 }] }, "$.a[*].b"),
    [{ path: "$['a'][0]['b']", value: 1 }, { path: "$['a'][1]['b']", value: 2 }]);
  assert.deepEqual(Y.applyPatch({ a: 1 }, [{ op: "add", path: "/b", value: 2 }]),
    { a: 1, b: 2 });
  assert.deepEqual(Y.applyMergePatch({ a: 1, b: 2 }, { b: null }), { a: 1 });
  assert.deepEqual(Y.createMergePatch({ a: 1, b: 2 }, { a: 1 }), { b: null });
  const patch = Y.diff({ a: 1 }, { a: 2, b: 3 });
  assert.deepEqual(Y.applyPatch({ a: 1 }, patch), { a: 2, b: 3 });
  assert.throws(() => Y.applyPatch({}, [{ op: "remove", path: "/x" }]), Y.YamlError);
});

test("inferSchema, canonicalize, expandDirectives, assign", () => {
  const schema = Y.inferSchema([{ a: 1 }, { a: 2.5, b: "x" }]);
  assert.deepEqual(schema.required, ["a"]);
  assert.equal(schema.properties.a.type, "number");
  assert.equal(Y.canonicalize({ b: 1, a: [1e21, 0.1] }), "{\"a\":[1e+21,0.1],\"b\":1}");
  assert.equal(Y.expandDirectives("%GLOBAL YAML 1.2\n--- a\n--- b\n"),
    "%YAML 1.2\n--- a\n...\n%YAML 1.2\n--- b\n");
  assert.deepEqual(Y.assign("# keep\na: 1 # c\nb: 2\n", "$.a", "42"),
    { text: "# keep\na: 42 # c\nb: 2\n", count: 1 });
});

test("the yaml command on an in-memory host", () => {
  const host = memoryHost({ cwd: "/w", files: { "/w/a.yaml": "a: 1  # one\nb: {c: [1, 2]}\n" } });
  assert.equal(run(["$.b.c[1]", "a.yaml"], { host }), 0);
  assert.equal(host.take(1), "2\n");
  assert.equal(run(["$.a = 5", "-i", "a.yaml"], { host }), 0);
  assert.equal(host.text("/w/a.yaml"), "a: 5  # one\nb: {c: [1, 2]}\n");
  assert.equal(run(["to", "json"], { host: memoryHost({ stdin: "x: [1]\n" }) }), 0);
  assert.equal(run(["nope"], { host }), 2);
  assert.match(host.take(2), /unknown command: nope/);
});
