// Diagnostics of regions: what the embedded languages' servers publish for
// the projections, mirrored onto the YAML document.
//
// Every other feature is a request that can be forwarded; diagnostics are
// pushed by their owner, so the only way to get them is to read what was
// published for a projection, which therefore has to exist and be open
// before anyone looks (eager projection, see extension.js).

const vscode = require("vscode");
const { remapDiagnostic } = require("./providers");
const { readConfig } = require("./config");

class DiagnosticBridge {
  constructor(store) {
    this.store = store;
    this.collection = vscode.languages.createDiagnosticCollection("yaml-embedded");
    this.disposables = [
      this.collection,
      vscode.languages.onDidChangeDiagnostics((e) => {
        const hosts = new Set();
        for (const uri of e.uris) {
          const owner = store.hostOf(uri);
          if (owner) hosts.add(owner.hostUri.toString());
        }
        for (const key of hosts) this.republish(vscode.Uri.parse(key));
      }),
      store.onDidReproject.event((hostUri) => this.republish(hostUri)),
    ];
  }

  republish(hostUri) {
    const cfg = readConfig();
    const out = [];
    if (cfg.projecting && cfg.diagnosticsEnabled) {
      for (const p of this.store.projectionsOf(hostUri)) {
        for (const d of vscode.languages.getDiagnostics(p.uri)) out.push(remapDiagnostic(p, d));
      }
    }
    if (cfg.projecting && cfg.warnOnFoldedScalars) {
      for (const f of this.store.foldedOf(hostUri)) {
        const d = new vscode.Diagnostic(
          new vscode.Range(f.headerLine, 0, f.headerLine, Number.MAX_SAFE_INTEGER),
          `This folded block scalar (>) names the language '${f.languageId}', but folding ` +
            "joins its lines, so its value is not the text shown. Language features are " +
            "only provided in literal block scalars (|).",
          vscode.DiagnosticSeverity.Warning);
        d.source = "yaml-embedded";
        out.push(d);
      }
    }
    this.collection.set(hostUri, out);
  }

  clear(hostUri) {
    this.collection.delete(hostUri);
  }

  dispose() {
    this.disposables.forEach((d) => d.dispose());
  }
}

module.exports = { DiagnosticBridge };
