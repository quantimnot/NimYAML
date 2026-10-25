// Comments: Enter in a comment continues it on the next line (see
// rules.js).

const vscode = require("vscode");
const { commentOnEnterRules } = require("./rules");

/**
 * Adds the rules to YAML's language configuration. VS Code keeps the rest
 * of it; what is set here takes precedence. Returns the disposable.
 */
function registerComments() {
  return vscode.languages.setLanguageConfiguration("yaml", {
    onEnterRules: commentOnEnterRules(vscode.IndentAction.None),
  });
}

module.exports = { registerComments };
