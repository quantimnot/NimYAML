// The pure parts of diff/: how the changes of a semantic diff are listed.
// The changes come from yamllsp (`nimyaml/diff`), tested in test/tlsp.nim.

const ICONS = { added: "$(diff-added)", removed: "$(diff-removed)", changed: "$(diff-modified)" };

/** The side a change is shown on: where its node is, the new one if both. */
function sideOf(change) {
  return change.kind === "removed" ? "old" : "new";
}

/**
 * The path of `change` on its side, as a JSON Pointer or (`format` "path")
 * a JSON Path: the root's empty pointer as `(root)`, and the number of its
 * document when a text has several.
 */
function changePath(change, format, documents) {
  const side = sideOf(change);
  const text = change[side + (format === "path" ? "Path" : "Pointer")];
  if (Math.max(...(documents ?? [1])) > 1) {
    return `#${change.document + 1}` + (text ? ` ${text}` : "");
  }
  return text || "(root)";
}

/** The values of `change`, on one line: the new one, the old one, or both. */
function changeValues(change) {
  switch (change.kind) {
    case "added": return change.new ?? "";
    case "removed": return change.old ?? "";
    default: return `${change.old} → ${change.new}`;
  }
}

/** The numbers of changes by kind, e.g. "2 changed, 1 added". */
function summary(changes) {
  const counts = { changed: 0, added: 0, removed: 0 };
  for (const change of changes) counts[change.kind]++;
  const parts = Object.entries(counts).filter(([, n]) => n > 0).map(([kind, n]) => `${n} ${kind}`);
  return parts.length ? parts.join(", ") : "no changes";
}

/** The quick pick items of the answer to `nimyaml/diff`; each keeps its change. */
function pickItems(result, format) {
  return result.changes.map((change) => ({
    label: `${ICONS[change.kind]} ${changePath(change, format, result.documents)}`,
    description: changeValues(change),
    change,
  }));
}

/** Whether a file or language is read as JSON (with comments) rather than YAML. */
function isJson(languageIdOrPath) {
  return /^(json|jsonc)$/.test(languageIdOrPath) || /\.jsonc?$/i.test(languageIdOrPath);
}

/** Why `nimyaml/diff` could not compare, from its `error` and the sides' labels. */
function errorMessage(error, labels) {
  return `${labels[error.side] ?? error.side}:${error.line + 1}:${error.character + 1}: ${error.message}`;
}

module.exports = { sideOf, changePath, changeValues, summary, pickItems, isJson, errorMessage };
