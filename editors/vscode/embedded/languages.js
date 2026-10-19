// Which languages can be embedded, and the file extension their projections
// get. Read from the `contributes.languages` of every installed extension
// rather than from a table here: it is right for whatever is installed, and
// a language without a file extension is one no server would pick up a
// projection of, so the same lookup answers whether a block can be served.

const vscode = require("vscode");

class LanguageRegistry {
  constructor() {
    this.known = new Set();
    this.extensions = new Map();
  }

  async refresh() {
    this.known = new Set(await vscode.languages.getLanguages());
    const candidates = new Map();
    for (const ext of vscode.extensions.all) {
      // a manifest, not a typed API: read defensively
      const languages = ext.packageJSON?.contributes?.languages;
      if (!Array.isArray(languages)) continue;
      for (const l of languages) {
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

  /** The file extension of `id`, or undefined if it cannot be projected. */
  fileExtension(id) {
    return this.extensions.get(id);
  }

  isProjectable(id) {
    return this.known.has(id) && this.extensions.has(id);
  }
}

module.exports = { LanguageRegistry };
