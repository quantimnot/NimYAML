#!/usr/bin/env node
// Which languages can be embedded, under which names, and the TextMate
// grammar that colours them. Nothing is listed here: the languages are the
// ones installed extensions contribute, so a newly installed language works
// without a change to this extension, and the user adds names and grammars
// in settings. Like core.js this does not touch the `vscode` module.
//
// The grammar is injected into VS Code's YAML grammar and takes over at the
// `|` of a literal block scalar whose header comment names a language:
//
//   setup: | # python
//
// Like that grammar's own block scalar rule its `while` is just `\G`, which
// holds as long as the enclosing mapping or sequence rule accepted the
// line's indentation, so where the block ends is YAML's decision and not
// re-implemented here. The content is tokenized by the language's grammar.
// VS Code reads grammars and their `embeddedLanguages` from the extension's
// files when a window starts, so they are rewritten when the languages
// change and take effect after a reload (see index.js).
//
// Run as a script, it writes the grammar for no languages, the placeholder
// a package needs before its first activation.

const fs = require("fs");
const path = require("path");

const SCOPE_NAME = "nimyaml.embedded.injection";
// the `path` of the grammar's contribution in package.yaml
const GRAMMAR_PATH = path.join(__dirname, "..", "syntaxes", "yaml-embedded.tmLanguage.json");

const normal = (name) => (typeof name === "string" ? name.trim().toLowerCase() : "");

/**
 * The embeddable languages and the names comments may use for them.
 *
 * `contributions` are the `contributes` sections of the installed
 * extensions' manifests, in extension order. A language is known by its ID
 * and by the aliases and file extensions it declares (`Python`, `py`);
 * `aliases` (name -> language ID) and `grammars` from the settings come
 * first. A grammar setting maps a name to a TextMate scope, or to
 * `{scopeName, language}` to colour a language with another grammar or to
 * add one that is not a VS Code language. A name means the first language
 * it is found for, in this order: grammar settings, alias settings, IDs,
 * declared aliases, file extensions.
 *
 * Returns `{entries, names}`: `entries` maps an entry key (a language ID,
 * or the name of a grammar setting without a language) to `{key,
 * languageId, scopeName}`, `names` maps lower-case names to entry keys.
 */
function languageTable(contributions, aliases = {}, grammars = {}) {
  const entries = new Map();
  const declared = [];
  for (const c of contributions) {
    for (const g of Array.isArray(c?.grammars) ? c.grammars : []) {
      if (typeof g?.language !== "string" || typeof g.scopeName !== "string") continue;
      if (!entries.has(g.language)) {
        entries.set(g.language, { key: g.language, languageId: g.language, scopeName: g.scopeName });
      }
    }
    for (const l of Array.isArray(c?.languages) ? c.languages : []) {
      if (typeof l?.id === "string") declared.push(l);
    }
  }
  for (const l of declared) {
    if (!entries.has(l.id)) entries.set(l.id, { key: l.id, languageId: l.id, scopeName: undefined });
  }

  const names = new Map();
  const add = (name, key) => {
    const n = normal(name);
    if (n && !/[\r\n]/.test(n) && !names.has(n)) names.set(n, key);
  };
  for (const [name, spec] of Object.entries(grammars ?? {})) {
    const { scopeName, language } = typeof spec === "string" ? { scopeName: spec } : spec ?? {};
    if (typeof scopeName !== "string" || !scopeName) continue;
    const key = typeof language === "string" && language ? language : name;
    const entry = entries.get(key) ?? { key, languageId: key === language ? language : undefined };
    entries.set(key, { ...entry, scopeName });
    add(name, key);
  }
  for (const [name, id] of Object.entries(aliases ?? {})) {
    if (typeof id === "string" && entries.has(id)) add(name, id);
  }
  for (const key of entries.keys()) add(key, key);
  for (const l of declared) {
    for (const a of Array.isArray(l.aliases) ? l.aliases : []) add(a, l.id);
  }
  for (const l of declared) {
    for (const e of Array.isArray(l.extensions) ? l.extensions : []) {
      if (typeof e === "string" && e.startsWith(".")) add(e.slice(1), l.id);
    }
  }
  return { entries, names };
}

/** The language ID `name` means, or undefined. */
function languageOf(table, name) {
  return table.entries.get(table.names.get(normal(name)))?.languageId;
}

const escapeRe = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const scopeSegment = (key) => key.replace(/[^\w-]/g, "_");

/** The entries with a grammar and the names that select them. */
function colouredEntries(table) {
  const byKey = new Map();
  for (const [name, key] of table.names) {
    const entry = table.entries.get(key);
    if (!entry?.scopeName) continue;
    if (!byKey.has(key)) byKey.set(key, { ...entry, names: [] });
    byKey.get(key).names.push(name);
  }
  return [...byKey.values()];
}

/**
 * The injection grammar for `table` (see the top of this file). The header
 * comment may also be written like the sticky directive, `| # yaml-lsp:
 * python`, for each of the `directives`' names.
 */
function injectionGrammar(table, directives = []) {
  const entries = colouredEntries(table);
  const directive = directives.length
    ? `(?:(?:${directives.map(escapeRe).join("|")})[ \\t]*:[ \\t]*)?`
    : "";
  const rule = (e) => ({
    // longer names first, so that `c++` is not read as `c`
    begin: `(\\|)([1-9])?([+-])?([1-9])?[ \\t]+((#)[ \\t]*${directive}(?i:${
      [...e.names].sort((a, b) => b.length - a.length).map(escapeRe).join("|")}))[ \\t]*$`,
    while: "\\G",
    beginCaptures: {
      1: { name: "keyword.control.flow.block-scalar.literal.yaml" },
      2: { name: "constant.numeric.indentation-indicator.yaml" },
      3: { name: "storage.modifier.chomping-indicator.yaml" },
      4: { name: "constant.numeric.indentation-indicator.yaml" },
      5: { name: "comment.line.number-sign.yaml" },
      6: { name: "punctuation.definition.comment.yaml" },
    },
    name: "meta.scalar.yaml",
    patterns: [{
      begin: "$",
      while: "\\G",
      contentName: `meta.embedded.block.${scopeSegment(e.key)}`,
      patterns: [{ include: e.scopeName }],
    }],
  });
  return {
    "//": "Generated by the extension from the installed languages; do not edit.",
    scopeName: SCOPE_NAME,
    injectionSelector: "L:source.yaml -string -comment",
    patterns: entries.map((e) => ({ include: `#${scopeSegment(e.key)}` })),
    repository: Object.fromEntries(entries.map((e) => [scopeSegment(e.key), rule(e)])),
  };
}

/**
 * The `embeddedLanguages` of the grammar's contribution: the language of
 * each embedded scope, for comment toggling, brackets and the like.
 */
function embeddedLanguages(table) {
  return Object.fromEntries(colouredEntries(table)
    .filter((e) => e.languageId)
    .map((e) => [`meta.embedded.block.${scopeSegment(e.key)}`, e.languageId]));
}

const emptyTable = () => ({ entries: new Map(), names: new Map() });
const grammarText = (table, directives) =>
  JSON.stringify(injectionGrammar(table, directives), null, 2) + "\n";

/** Writes `text` as the grammar unless it is that already; whether it wrote. */
function writeGrammar(text) {
  if (fs.existsSync(GRAMMAR_PATH) && fs.readFileSync(GRAMMAR_PATH, "utf8") === text) return false;
  fs.mkdirSync(path.dirname(GRAMMAR_PATH), { recursive: true });
  fs.writeFileSync(GRAMMAR_PATH, text);
  return true;
}

if (require.main === module) writeGrammar(grammarText(emptyTable()));

module.exports = {
  SCOPE_NAME,
  GRAMMAR_PATH,
  languageTable,
  languageOf,
  injectionGrammar,
  embeddedLanguages,
  grammarText,
  writeGrammar,
  emptyTable,
};
