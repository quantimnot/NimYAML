// The pure parts of infer/: which texts can be inferred from, how they are
// sent to yamllsp, and how its answer is shown. The schema itself comes
// from yamllsp (`nimyaml/inferSchema`), tested in test/tlsp.nim.

/**
 * How a file or language is read: `{json, lines}` as `nimyaml/inferSchema`
 * takes them, or undefined for what it cannot read (CBOR is binary, and
 * an editor's text of it is not the data).
 */
function inputFormat(languageIdOrPath) {
  const id = languageIdOrPath.toLowerCase();
  if (id === "yaml" || /\.ya?ml$/.test(id)) return { json: false, lines: false };
  if (id === "json" || id === "jsonc" || /\.jsonc?$/.test(id)) return { json: true, lines: false };
  if (id === "jsonl" || /\.(jsonl|ndjson)$/.test(id)) return { json: false, lines: true };
  return undefined;
}

/**
 * The `options` of `nimyaml/inferSchema` from the `yaml+lsp.infer`
 * settings; `get(name, default)` is a WorkspaceConfiguration's.
 */
function inferOptions(get) {
  return {
    required: get("required", true),
    additionalProperties: get("additionalProperties", true),
    enumLimit: Math.max(0, Math.floor(Number(get("enumLimit", 0)) || 0)),
    formats: get("formats", true),
    integers: get("integers", true),
  };
}

/** The params of `nimyaml/inferSchema` for `inputs` (each `{text, json, lines}`). */
function requestParams(inputs, options) {
  return {
    inputs: inputs.map(({ text, json, lines }) => ({ text, json, lines })),
    options,
  };
}

/**
 * The text of the editor the schema opens in: a comment that says where it
 * comes from, then the schema.
 */
function schemaDocument(schema, labels, documents) {
  const sources = labels.length <= 3
    ? labels.join(", ")
    : `${labels.slice(0, 3).join(", ")} and ${labels.length - 3} more`;
  const counted = documents === 1 ? "1 document" : `${documents} documents`;
  return `# inferred from ${sources} (${counted})\n${schema}`;
}

/** Why `nimyaml/inferSchema` could not infer, from its `error` and the inputs' labels. */
function errorMessage(error, labels) {
  const label = labels[error.input] ?? `input ${error.input + 1}`;
  return `${label}:${error.line + 1}:${error.character + 1}: ${error.message}`;
}

module.exports = { inputFormat, inferOptions, requestParams, schemaDocument, errorMessage };
