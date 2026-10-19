// The `nimyaml.embedded` settings, read on every use so that changes apply
// without a restart.

const vscode = require("vscode");

function readConfig() {
  const c = vscode.workspace.getConfiguration("nimyaml.embedded");
  return {
    enabled: c.get("enabled", true),
    diagnosticsEnabled: c.get("diagnostics.enabled", true),
    debounceMs: c.get("diagnostics.debounceMs", 400),
    projectionRoot: c.get("projection.root", "workspace"),
    projectionDirectory: c.get("projection.directory", ".yaml-embedded"),
    manageExcludes: c.get("projection.manageExcludes", true),
    semanticTokensEnabled: c.get("semanticTokens.enabled", true),
    warnOnFoldedScalars: c.get("warnOnFoldedScalars", true),
    stickyDirective: c.get("stickyDirective", "yaml-lsp"),
    compatDirective: c.get("compat.yamlEmbeddedLanguagesDirective", true),
    aliases: c.get("aliases", {}),
    keyRules: c.get("keyRules", []),
  };
}

module.exports = { readConfig };
