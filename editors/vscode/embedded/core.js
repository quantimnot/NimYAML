// The editor-independent part of embedded languages: which block scalars
// hold which language, how positions map between a block and its
// projection, and how embedded semantic tokens join yamllsp's. Nothing here
// touches the `vscode` module, so `bun --test` runs it directly.
//
// Positions are plain `{line, character}` objects and ranges
// `{start, end}`, 0-based; the VS Code side converts them.

// Where a block's language comes from, in order of precedence.
const PROVENANCE = ["inline-comment", "sticky-directive", "key-rule"];

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Minimal glob to regular expression: `**`, `*` and `?`. */
function globToRe(glob) {
  const body = glob
    .replace(/[.+^${}()|[\]\\]/g, "\\$&")
    .replace(/\*\*\//g, "\u0000")
    .replace(/\*\*/g, "\u0001")
    .replace(/\*/g, "[^/]*")
    .replace(/\?/g, "[^/]")
    .replace(/\u0000/g, "(?:.*/)?")
    .replace(/\u0001/g, ".*");
  return new RegExp(`^${body}$`);
}

/**
 * The language a comment names (`languageOf`, see grammar.js), or
 * undefined if `isKnownLanguage` rejects it.
 */
function resolveLanguage(name, options) {
  const id = options.languageOf(name.trim());
  return id && options.isKnownLanguage(id) ? id : undefined;
}

/** The names of the sticky directive: `yaml-lsp` and the compatible one. */
function directiveNames(options) {
  const names = [options.stickyDirective];
  if (options.compatDirective) names.push("yaml-embedded-languages");
  return names.filter(Boolean);
}

/**
 * The language name in a block's header comment: `python`, or the same
 * written like the directive, `yaml-lsp: python`.
 */
function headerName(comment, options) {
  const alternatives = directiveNames(options).map(escapeRe).join("|");
  const directive = alternatives && new RegExp(`^\\s*(?:${alternatives})\\s*:\\s*(\\S.*)$`).exec(comment);
  return directive ? directive[1] : comment;
}

/**
 * The language a sticky directive sets for each line: `# yaml-lsp: python`
 * sets it for the blocks below, a bare `# yaml-lsp` clears it. Lines inside
 * block scalars are content, not comments, and are skipped.
 */
function stickyLanguages(lines, blocks, options) {
  const alternatives = directiveNames(options).map(escapeRe).join("|");
  const setRe = new RegExp(`^\\s*#\\s*(?:${alternatives})\\s*:\\s*(\\S+)\\s*$`);
  const clearRe = new RegExp(`^\\s*#\\s*(?:${alternatives})\\s*$`);
  const content = new Uint8Array(lines.length);
  for (const b of blocks) content.fill(1, b.start, b.end + 1);
  const table = new Array(lines.length);
  let current;
  for (let l = 0; l < lines.length; l++) {
    if (!content[l] && alternatives) {
      const set = setRe.exec(lines[l]);
      if (set) current = set[1];
      else if (clearRe.test(lines[l])) current = undefined;
    }
    table[l] = current;
  }
  return table;
}

function keyRuleLanguage(key, options) {
  for (const rule of options.keyRules) {
    if (rule.filePattern && !globToRe(rule.filePattern).test(options.docPath)) continue;
    let re;
    try {
      re = new RegExp(rule.keyPattern);
    } catch (_) {
      continue;
    }
    if (re.test(key) && options.isKnownLanguage(rule.language)) return rule.language;
  }
  return undefined;
}

/**
 * Decides the language of each block scalar yamllsp reported
 * (`nimyaml/blockScalars`). Precedence: the comment on the header, then a
 * sticky directive, then a key rule. Only literal (`|`) blocks become
 * regions: folding joins lines, so a folded block's value is not the text
 * on screen and positions cannot be mapped; folded blocks that name a
 * language are returned separately so they can be reported.
 *
 * `lines` are the document's lines without line breaks. `options` holds
 * `languageOf(name)`, `stickyDirective`, `compatDirective`, `keyRules`,
 * `isKnownLanguage(id)` and `docPath` (for key rules' `filePattern`).
 * Key rules name language IDs, not names.
 */
function resolveRegions(blocks, lines, options) {
  const sticky = stickyLanguages(lines, blocks, options);
  const regions = [];
  const folded = [];
  for (const b of blocks) {
    let languageId;
    let provenance;
    if (b.comment) {
      languageId = resolveLanguage(headerName(b.comment, options), options);
      provenance = PROVENANCE[0];
    }
    if (!languageId && sticky[b.line]) {
      languageId = resolveLanguage(sticky[b.line], options);
      provenance = PROVENANCE[1];
    }
    if (!languageId && b.key) {
      languageId = keyRuleLanguage(b.key, options);
      provenance = PROVENANCE[2];
    }
    if (!languageId) continue;
    if (b.style === "folded") {
      folded.push({ headerLine: b.line, languageId });
      continue;
    }
    const content = [];
    for (let l = b.start; l <= b.end; l++) content.push(lines[l].slice(b.indent));
    regions.push({
      ordinal: regions.length,
      languageId,
      provenance,
      key: b.key,
      headerLine: b.line,
      start: b.start,
      end: b.end,
      indent: b.indent,
      content: content.join("\n") + "\n",
    });
  }
  return { regions, folded };
}

/**
 * Maps positions between a host document and the projection of one of its
 * regions. A literal block's value is its lines minus the indentation and
 * nothing else, so the map is an offset in both directions, exact and
 * invertible; that is what lets edits computed on the projection (rename,
 * formatting, code actions) apply to the host unchanged.
 */
class RegionMap {
  constructor(region) {
    this.start = region.start;
    this.end = region.end;
    this.indent = region.indent;
  }

  /** Whether `line` of the host is content of the region. */
  containsLine(line) {
    return line >= this.start && line <= this.end;
  }

  /** Columns in the indentation map to the start of the line. */
  toProjection(p) {
    return {
      line: Math.max(0, p.line - this.start),
      character: Math.max(0, p.character - this.indent),
    };
  }

  toHost(p) {
    return { line: p.line + this.start, character: p.character + this.indent };
  }

  toProjectionRange(r) {
    return { start: this.toProjection(r.start), end: this.toProjection(r.end) };
  }

  /** Maps back and clamps to the region's lines, so an edit stays inside. */
  toHostRange(r) {
    const clamp = (p) => ({
      line: Math.min(Math.max(p.line, this.start), this.end),
      character: p.character,
    });
    return { start: clamp(this.toHost(r.start)), end: clamp(this.toHost(r.end)) };
  }

  /**
   * Indents text computed against the projection so it stays inside the
   * block. The first line is placed at the indentation by `toHostRange`
   * already; empty lines stay empty rather than gaining trailing spaces,
   * which YAML allows inside a block scalar.
   */
  reindent(text) {
    if (this.indent === 0 || !text.includes("\n")) return text;
    const pad = " ".repeat(this.indent);
    return text
      .split("\n")
      .map((l, i) => (i === 0 || l.length === 0 ? l : pad + l))
      .join("\n");
  }
}

/** Absolute `{line, character, length, type, modifiers}` tokens of LSP data. */
function decodeTokens(data) {
  const out = [];
  let line = 0;
  let character = 0;
  for (let i = 0; i + 4 < data.length; i += 5) {
    line += data[i];
    character = data[i] === 0 ? character + data[i + 1] : data[i + 1];
    out.push({ line, character, length: data[i + 2], type: data[i + 3], modifiers: data[i + 4] });
  }
  return out;
}

function encodeTokens(tokens) {
  const data = new Uint32Array(tokens.length * 5);
  let line = 0;
  let character = 0;
  tokens.forEach((t, i) => {
    data[i * 5] = t.line - line;
    data[i * 5 + 1] = t.line === line ? t.character - character : t.character;
    data[i * 5 + 2] = t.length;
    data[i * 5 + 3] = t.type;
    data[i * 5 + 4] = t.modifiers;
    line = t.line;
    character = t.character;
  });
  return data;
}

/**
 * yamllsp's semantic tokens with the embedded languages' in place of its
 * own on the regions' content lines, where it reports the block as one
 * string and so would hide the embedded grammar's colours.
 *
 * `legend` is yamllsp's `{tokenTypes, tokenModifiers}`; each of `embedded`
 * is `{map, legend, data}` for one region's projection. A provider declares
 * one legend for all documents, so embedded types and modifiers are carried
 * over by name and those yamllsp's legend lacks are dropped: those tokens
 * keep the colour of the TextMate grammar.
 */
function mergeSemanticTokens(hostData, legend, embedded) {
  const tokens = decodeTokens(hostData).filter(
    (t) => !embedded.some((e) => e.map.containsLine(t.line)),
  );
  for (const e of embedded) {
    const types = e.legend.tokenTypes.map((t) => legend.tokenTypes.indexOf(t));
    const modifiers = e.legend.tokenModifiers.map((m) => legend.tokenModifiers.indexOf(m));
    for (const t of decodeTokens(e.data)) {
      const type = types[t.type] ?? -1;
      if (type < 0) continue;
      let mods = 0;
      modifiers.forEach((m, bit) => {
        if (m >= 0 && t.modifiers & (1 << bit)) mods |= 1 << m;
      });
      const host = e.map.toHost(t);
      if (!e.map.containsLine(host.line)) continue;
      tokens.push({ ...host, length: t.length, type, modifiers: mods });
    }
  }
  tokens.sort((a, b) => a.line - b.line || a.character - b.character);
  return encodeTokens(tokens);
}

module.exports = {
  directiveNames,
  globToRe,
  resolveRegions,
  RegionMap,
  decodeTokens,
  encodeTokens,
  mergeSemanticTokens,
};
