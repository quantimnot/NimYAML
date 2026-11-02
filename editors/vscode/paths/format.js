// The pure parts of paths/: how a node's JSON Pointer, JSON Path or URL
// fragment is shown in the status bar and the items of "Go to Path…". The
// paths themselves come from yamllsp (`nimyaml/pathAt`, `nimyaml/paths`),
// tested in test/tlsp.nim.

const FORMATS = {
  pointer: { name: "JSON Pointer", key: "pointer" },
  path: { name: "JSON Path", key: "path" },
  fragment: { name: "URL Fragment", key: "fragment" },
};

function formatOf(name) {
  return FORMATS[name] ?? FORMATS.pointer;
}

// what encodeURIComponent escapes but a URI fragment may hold (RFC 3986:
// fragment = *( pchar / "/" / "?" ))
const FRAGMENT_CHARS = /%(24|26|2B|2C|3B|3D|3A|40|2F|3F)/g;

/**
 * The URI fragment identifier of the JSON Pointer `pointer` (RFC 6901,
 * section 6, and RFC 9512 for YAML): `#` and the pointer, UTF-8
 * percent-encoded where a fragment may not hold it, e.g. `#/a%20b/0`.
 */
function fragmentOf(pointer) {
  return "#" + encodeURIComponent(pointer).replace(FRAGMENT_CHARS, decodeURIComponent);
}

// what encodeURIComponent escapes but the first segment of a relative
// reference may hold: pchar without ":" (RFC 3986, section 4.2)
const SEGMENT_CHARS = /%(24|26|2B|2C|3B|3D|40)/g;

/**
 * The relative URL of the file named `name` from its own directory, e.g.
 * `my%20config.yaml`; empty for a file without a name, as an untitled one,
 * whose fragments refer into the same document.
 */
function fileReference(name) {
  return encodeURIComponent(name ?? "").replace(SEGMENT_CHARS, decodeURIComponent);
}

/**
 * The text of `node` in the format `name`, as it is copied. A fragment
 * follows `file`: the document's `fileReference` for a relative URL, its
 * URI for an absolute one.
 */
function pathText(node, name, file) {
  const format = formatOf(name);
  if (format.key === "fragment") return (file ?? "") + fragmentOf(node.pointer);
  return node[format.key];
}

/**
 * How `node` is shown: the root's empty JSON Pointer as `(root)`, a
 * fragment after `file`, and the number of its document when there are
 * several.
 */
function displayText(node, name, file) {
  const text = pathText(node, name, file) || "(root)";
  return node.documents > 1 ? `#${node.document + 1} ${text}` : text;
}

/** A scalar's value on one line, line breaks shown as ↵. */
function previewValue(value) {
  return value === undefined ? "" : value.replace(/\r?\n/g, "↵");
}

/**
 * The quick pick items of `nodes`, the answer to `nimyaml/paths`: one per
 * node, labelled in the format `name` (fragments after `file`), and a
 * separator before each document when there are several. Each item keeps
 * its node.
 */
function pickItems(nodes, name, file) {
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
      label: pathText(node, name, file) || "(root)",
      description: previewValue(node.value),
      node,
    });
  }
  return items;
}

module.exports = {
  FORMATS, formatOf, fragmentOf, fileReference, pathText, displayText, previewValue, pickItems,
};
