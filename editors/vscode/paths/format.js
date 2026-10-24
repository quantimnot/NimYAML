// The pure parts of paths/: how a node's JSON Pointer or JSON Path is shown
// in the status bar and the items of "Go to Path…". The paths themselves
// come from yamllsp (`nimyaml/pathAt`, `nimyaml/paths`), tested in
// test/tlsp.nim.

const FORMATS = {
  pointer: { name: "JSON Pointer", key: "pointer" },
  path: { name: "JSON Path", key: "path" },
};

function formatOf(name) {
  return FORMATS[name] ?? FORMATS.pointer;
}

/** The text of `node` in the format `name`, as it is copied. */
function pathText(node, name) {
  return node[formatOf(name).key];
}

/**
 * How `node` is shown: the root's empty JSON Pointer as `(root)`, and the
 * number of its document when there are several.
 */
function displayText(node, name) {
  const text = pathText(node, name) || "(root)";
  return node.documents > 1 ? `#${node.document + 1} ${text}` : text;
}

/** A scalar's value on one line, line breaks shown as ↵. */
function previewValue(value) {
  return value === undefined ? "" : value.replace(/\r?\n/g, "↵");
}

/**
 * The quick pick items of `nodes`, the answer to `nimyaml/paths`: one per
 * node, labelled in the format `name`, and a separator before each document
 * when there are several. Each item keeps its node.
 */
function pickItems(nodes, name) {
  const items = [];
  const several = nodes.some((node) => node.document > 0);
  let document = -1;
  for (const node of nodes) {
    if (several && node.document !== document) {
      document = node.document;
      // -1 is vscode.QuickPickItemKind.Separator
      items.push({ label: `Document ${document + 1}`, kind: -1 });
    }
    items.push({
      label: pathText(node, name) || "(root)",
      description: previewValue(node.value),
      node,
    });
  }
  return items;
}

module.exports = { FORMATS, formatOf, pathText, displayText, previewValue, pickItems };
