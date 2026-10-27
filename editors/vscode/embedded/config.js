// The `yaml+lsp.embedded` settings, read on every use so that changes apply
// without a restart.
//
// `enabled` is the setting; `projecting` is whether regions are written to
// projection files, which every language feature rests on. They differ in
// a workspace the user has not trusted (Workspace Trust): projections are
// files written into the workspace and `files.exclude` edits of its
// settings, and the servers of other extensions are asked to analyze its
// code, so nothing is projected until trust is granted. The injection
// grammar follows the setting alone: colours are harmless, and a grammar
// change asks for a window reload, which trust must not.

const vscode = require("vscode");

function readConfig() {
  const c = vscode.workspace.getConfiguration("yaml+lsp.embedded");
  const enabled = c.get("enabled", true);
  return {
    enabled,
    projecting: enabled && vscode.workspace.isTrusted,
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
    grammars: c.get("grammars", {}),
    keyRules: c.get("keyRules", []),
  };
}

module.exports = { readConfig };
