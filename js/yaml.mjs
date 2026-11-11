// NimYAML for JavaScript: YAML in and out of JavaScript values, and what
// the library does with documents — lint, JSON Schema validation, JSONPath,
// JSON Patch and Merge Patch, semantic diff, schema inference,
// canonical JSON, directive expansion and text-preserving edits.
//
// Each function is a thin wrapper of an export of the compiled library
// (dist/nimyaml.mjs, built from js/nimyaml_js.nim by js/build.mjs). The
// compiled code takes and returns strings only: values cross as JSON text,
// and every result comes back as an envelope, {ok} or {error}. Here the
// values are stringified and parsed, and an error becomes a YamlError,
// which keeps the position of an error in the input. So a value is what
// JSON can say: YAML's other scalars (timestamps, binary) arrive as the
// strings or numbers that JSON makes of them, and an anchored node that
// is aliased arrives as copies.
//
// Files: the library reads files only for what names one (a schema by a
// `file:` URI, say). It reads them through the host installed with
// installHost; until one is, an empty in-memory host is installed, so the
// functions over values need no setup. See hosts/memory.mjs and
// hosts/node.mjs.

import * as nimyaml from "./dist/nimyaml.mjs";
import { memoryHost } from "./hosts/memory.mjs";

/** An error of NimYAML, with the position in the input for a parse error. */
export class YamlError extends Error {
  constructor({ kind, message, line, column, lineContent }) {
    super(line ? `${message} (line ${line}, column ${column})` : message);
    this.name = "YamlError";
    /** The Nim exception type, like "YamlParserError". */
    this.kind = kind;
    /** 1-based; undefined for errors that are not in the input. */
    this.line = line;
    this.column = column;
    /** The line, and under it a ^ at the column. */
    this.lineContent = lineContent;
  }
}

function unwrap(envelope) {
  const { ok, error } = JSON.parse(envelope);
  if (error) throw new YamlError(error);
  return ok;
}

const json = (value) => {
  const text = JSON.stringify(value);
  if (text === undefined) throw new TypeError("not a JSON value");
  return text;
};

/** Installs the host the library reads and writes files with. */
export function installHost(host) {
  nimyaml.installHost(host);
}
installHost(memoryHost());

/** The documents of a YAML (or JSON) text, as JavaScript values. */
export function loadAll(text) {
  return unwrap(nimyaml.loadAll(text));
}

/** The only document of a YAML text; an error if it has another number. */
export function load(text) {
  const documents = loadAll(text);
  if (documents.length !== 1) {
    throw new YamlError({ kind: "ValueError",
      message: `expected one document, found ${documents.length}` });
  }
  return documents[0];
}

/**
 * A value as YAML. `style` is one of "default", "block" (no flow
 * collections), "minimal", "canonical", "explanatory" or "json".
 */
export function dump(value, { style = "default" } = {}) {
  return unwrap(nimyaml.dump(json(value), style));
}

/**
 * The lint diagnostics of a YAML text: [{rule, severity, message,
 * start: {line, column}, end}], positions 1-based and the end exclusive.
 * `config` is the text of a lint config (.nimyaml-lint.yaml); `uri` is
 * the text's location, against which relative references resolve.
 */
export function lint(text, { config = "", uri = "" } = {}) {
  return unwrap(nimyaml.lint(text, config, uri));
}

/**
 * Validates a value against a JSON Schema (2020-12 unless it says
 * otherwise) and returns the JSON Schema output in `format`: "flag",
 * "basic", "detailed" or "verbose". Its `valid` is the verdict.
 */
export function validate(instance, schema, { format = "basic" } = {}) {
  return unwrap(nimyaml.validate(json(instance), json(schema), format));
}

/** The nodes a JSONPath (RFC 9535) selects: [{path, value}]. */
export function query(value, path) {
  return unwrap(nimyaml.query(json(value), path));
}

/** A value changed by a JSON Patch (RFC 6902). */
export function applyPatch(value, patch) {
  return unwrap(nimyaml.applyPatch(json(value), json(patch)));
}

/** A value changed by a JSON Merge Patch (RFC 7396). */
export function applyMergePatch(value, patch) {
  return unwrap(nimyaml.applyMergePatch(json(value), json(patch)));
}

/** The JSON Merge Patch that turns `source` into `target`. */
export function createMergePatch(source, target) {
  return unwrap(nimyaml.createMergePatch(json(source), json(target)));
}

/** The JSON Patch that turns `oldValue` into `newValue`, by meaning. */
export function diff(oldValue, newValue) {
  return unwrap(nimyaml.diff(json(oldValue), json(newValue)));
}

/** The JSON Schema that describes all of `documents`. */
export function inferSchema(documents) {
  return unwrap(nimyaml.inferSchema(json(documents)));
}

/** The JSON Canonicalization Scheme (RFC 8785) text of a value. */
export function canonicalize(value) {
  return unwrap(nimyaml.canonicalize(json(value)));
}

/**
 * A YAML text with NimYAML's %GLOBAL and %SCHEMA directives expanded, so
 * that any YAML processor reads it as NimYAML does.
 */
export function expandDirectives(text, { uri = "" } = {}) {
  return unwrap(nimyaml.expandDirectives(text, uri));
}

/**
 * A YAML text with each node that the JSONPath `path` selects replaced by
 * the YAML `value`, the rest of the text — comments, styles, order — kept
 * as it is: {text, count}.
 */
export function assign(text, path, value) {
  return unwrap(nimyaml.assign(text, path, value));
}

const memberPath = (path) => {
  if (Array.isArray(path)) return JSON.stringify(path.map(String));
  if (typeof path === "string") return path;
  throw new TypeError("a path is an array of keys or a JSONPath");
};

/**
 * A YAML text with the member at `path` set to the JavaScript (JSON)
 * value `value`. `path` is an array of keys, like ["files", "save-delay"],
 * or a JSONPath of member names, like "$.files['save-delay']". A member
 * that is there gets the value in place, keeping its trailing comment; one
 * that is not is added after the last member of its mapping, with the
 * mappings it needs, in block style. The rest of the text — comments,
 * blank lines, order, styles — is kept as it is. A text that does not
 * parse (or has a duplicate key) is a YamlError with its position.
 *
 *   set("# head\n", ["files", "save-delay"], 10)
 *   // "# head\nfiles:\n  save-delay: 10\n"
 */
export function set(text, path, value) {
  return unwrap(nimyaml.set(text, memberPath(path), json(value)));
}

/**
 * A YAML text without the member at `path` (as for set): its lines go,
 * with the comment block directly above it, but not the comments above
 * the root's first member, which may be the file's head. A mapping left
 * empty goes too. A path that is not there gives the text unchanged.
 */
export function remove(text, path) {
  return unwrap(nimyaml.remove(text, memberPath(path)));
}
