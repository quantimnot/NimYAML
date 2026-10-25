// Enter in a comment continues it: the new line starts with the comment's
// indentation and its `#` followed by as many spaces as the comment has,
// so `  #   text` continues as `  #   `. This is VS Code's language
// configuration, not something yamllsp could send: LSP's only hook,
// on-type formatting of "\n", is off by default (`editor.formatOnType`)
// and edits only after the newline is typed.
//
// An `appendText` is fixed, so there is a rule per count of spaces; a
// comment with more spaces than that continues with the most there is a
// rule for. A `#!` line is a shebang and is not continued.

// the most spaces after `#` that are kept
const MAX_SPACES = 16;

/**
 * The `onEnterRules` of YAML. `indentNone` is `vscode.IndentAction.None`:
 * the new line keeps the indentation of the comment's line.
 */
function commentOnEnterRules(indentNone) {
  const rules = [];
  for (let n = 0; n <= MAX_SPACES; n++) {
    const spaces = " ".repeat(n);
    const end = n < MAX_SPACES ? "(?! )" : "";
    rules.push({
      beforeText: new RegExp(`^\\s*#(?!!)${spaces}${end}`),
      action: { indentAction: indentNone, appendText: `#${spaces}` },
    });
  }
  return rules;
}

module.exports = { commentOnEnterRules, MAX_SPACES };
