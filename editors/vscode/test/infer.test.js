// Tests of infer/format.js; run with `bun test`. The schemas themselves
// come from yamllsp and are tested in test/tlsp.nim.

const test = require("node:test");
const assert = require("node:assert/strict");
const { inputFormat, inferOptions, requestParams, schemaDocument, errorMessage } =
  require("../infer/format");

test("which languages and files are read, and how", () => {
  const yaml = { json: false, lines: false };
  const json = { json: true, lines: false };
  const lines = { json: false, lines: true };
  assert.deepEqual(inputFormat("yaml"), yaml);
  assert.deepEqual(inputFormat("/a/b.yml"), yaml);
  assert.deepEqual(inputFormat("/a/b.YAML"), yaml);
  assert.deepEqual(inputFormat("json"), json);
  assert.deepEqual(inputFormat("jsonc"), json);
  assert.deepEqual(inputFormat("/a/tsconfig.jsonc"), json);
  assert.deepEqual(inputFormat("jsonl"), lines);
  assert.deepEqual(inputFormat("/logs/x.ndjson"), lines);
  assert.equal(inputFormat("cbor"), undefined);
  assert.equal(inputFormat("/a/b.cbor"), undefined);
  assert.equal(inputFormat("plaintext"), undefined);
});

test("options from the settings, with their defaults", () => {
  const settings = (values) => (name, fallback) => values[name] ?? fallback;
  assert.deepEqual(inferOptions(settings({})), {
    required: true, additionalProperties: true, enumLimit: 0, formats: true, integers: true,
  });
  assert.deepEqual(inferOptions(settings({
    required: false, additionalProperties: false, enumLimit: 5, formats: false, integers: false,
  })), {
    required: false, additionalProperties: false, enumLimit: 5, formats: false, integers: false,
  });
  // a limit is a whole number, and never negative
  assert.equal(inferOptions(settings({ enumLimit: 2.7 })).enumLimit, 2);
  assert.equal(inferOptions(settings({ enumLimit: -1 })).enumLimit, 0);
  assert.equal(inferOptions(settings({ enumLimit: "x" })).enumLimit, 0);
});

test("the request sends texts and their formats, not labels", () => {
  const options = { required: true };
  assert.deepEqual(requestParams([
    { label: "a.yaml", text: "a: 1", json: false, lines: false },
    { label: "b.json", text: "{}", json: true, lines: false },
  ], options), {
    inputs: [
      { text: "a: 1", json: false, lines: false },
      { text: "{}", json: true, lines: false },
    ],
    options,
  });
});

test("the schema's editor says where it comes from", () => {
  assert.equal(schemaDocument("type: object\n", ["a.yaml"], 1),
    "# inferred from a.yaml (1 document)\ntype: object\n");
  assert.equal(schemaDocument("type: object\n", ["a.yaml", "b.json"], 3),
    "# inferred from a.yaml, b.json (3 documents)\ntype: object\n");
  assert.equal(schemaDocument("x\n", ["a", "b", "c", "d", "e"], 5),
    "# inferred from a, b, c and 2 more (5 documents)\nx\n");
});

test("errors name the input and position", () => {
  const error = { input: 1, line: 2, character: 4, message: "unexpected end" };
  assert.equal(errorMessage(error, ["a.yaml", "b.yaml"]), "b.yaml:3:5: unexpected end");
  assert.equal(errorMessage({ ...error, input: 2 }, ["a.yaml"]), "input 3:3:5: unexpected end");
});
