// The installed languages: what names comments may use for them and which
// grammar colours them (grammar.js: `languageTable`), and the file
// extension their projections get. All read from the `contributes` of the
// installed extensions' manifests rather than from a table here, so it is
// right for whatever is installed. A language without a file extension is
// one no server would pick up a projection of, so the same lookup answers
// whether a block can be served.

const vscode = require("vscode");
const { languageTable, languageOf, emptyTable } = require("./grammar");
const { readConfig } = require("./config");

class LanguageRegistry {
  constructor() {
    this.known = new Set();
    this.extensions = new Map();
    this.table = emptyTable();
  }

  async refresh() {
    this.known = new Set(await vscode.languages.getLanguages());
    // a manifest, not a typed API: grammar.js reads it defensively
    const contributions = vscode.extensions.all.map((e) => e.packageJSON?.contributes);
    const cfg = readConfig();
    this.table = languageTable(contributions, cfg.aliases, cfg.grammars);

    const candidates = new Map();
    for (const c of contributions) {
      for (const l of Array.isArray(c?.languages) ? c.languages : []) {
        if (typeof l?.id !== "string" || !Array.isArray(l.extensions)) continue;
        const list = candidates.get(l.id) ?? [];
        list.push(...l.extensions.filter((e) => typeof e === "string" && e.startsWith(".")));
        candidates.set(l.id, list);
      }
    }
    // Other extensions add their own file types to a language (`json` has
    // `.code-profile`), which its server may treat differently; the
    // language's own name wins if it is a file extension.
    this.extensions.clear();
    for (const [id, list] of candidates) {
      const own = list.find((e) => e.toLowerCase() === `.${id}`);
      if (own ?? list[0]) this.extensions.set(id, own ?? list[0]);
    }
  }

  /** The language ID a comment's `name` means, or undefined. */
  languageOf(name) {
    return languageOf(this.table, name);
  }

  /** The file extension of `id`, or undefined if it cannot be projected. */
  fileExtension(id) {
    return this.extensions.get(id);
  }

  isProjectable(id) {
    return this.known.has(id) && this.extensions.has(id);
  }
}

module.exports = { LanguageRegistry };
