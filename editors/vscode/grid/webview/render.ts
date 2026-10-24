// Drawing the documents as nested tables.
//
// This is the port of the upstream viewer's Vue components (Cell,
// ObjectTable, ArrayTable, ArrayRow, ResizableTable), one function each:
//
// * A collection is a badge, `Object[3]` or `Array[5]`, with a button that
//   expands it into a table below. Roots start expanded.
// * An object's table has a row per member: the key, then the value, drawn
//   by the same rules.
// * An array with object items is a table whose columns are the members
//   of those items, so that a list of records reads as rows; other items
//   span the row. It can be switched to a plain list of items, which is
//   all an array without object items has.
// * The first column of an array's rows is the index, badged with the type
//   of the item.
// * Scalars are coloured by type. Hovering one shows a pencil that edits
//   it in place, and hovering a key one that renames it.
//
// Instead of components that update themselves, everything is redrawn from
// the documents and the view state whenever either changes. A grid shows
// what is expanded, which stays small however large the file is, so this
// is cheap, and there is no second copy of the state in the DOM to keep in
// sync. The one thing the DOM held that a redraw would lose is an editor
// being typed into; its draft is kept here (`editing`) and the editor is
// drawn again with it.

import { h, icon } from "./dom";
import {
  columnsOf, displayText, draftLines, isMultiline, memberOf, stateKey, valueOfDraft,
} from "./model";
import type { GridArray, GridNode, GridObject, Scalar, Segment } from "./protocol";
import { makeResizable } from "./resize";
import type { ViewState } from "./state";

export interface Actions {
  state: ViewState;
  redraw(): void;
  /** Resolves to why the edit failed, or `undefined` once it is applied. */
  assign(document: number, path: Segment[], value: string): Promise<string | undefined>;
  rename(document: number, path: Segment[], name: string): Promise<string | undefined>;
}

interface Context {
  document: number;
  actions: Actions;
}

// The editor that is open, if any: what it edits, the draft so far and the
// outcome of saving it.
interface Editing {
  key: string;
  draft: string;
  busy: boolean;
  error?: string;
  selection?: [number, number];
}

let editing: Editing | undefined;
let editorDrawn = false;

export function renderDocuments(documents: GridNode[], actions: Actions): Node {
  editorDrawn = false;
  const content: Node =
    documents.length === 0 ? h("p", { class: "empty" }, "The file has no documents.")
    : documents.length === 1 ? renderNode(documents[0], { document: 0, actions }, [])
    : h("div", null, documents.map((root, i) =>
        h("section", { class: "document" },
          h("h2", { class: "document-header" }, `Document ${i + 1}`),
          renderNode(root, { document: i, actions }, []))));
  // an editor whose node is gone is closed rather than revived when a later
  // version has a node at its path again
  if (!editorDrawn) editing = undefined;
  return content;
}

function renderNode(node: GridNode, ctx: Context, path: Segment[]): Node {
  switch (node.kind) {
    case "cycle":
      return h("span", { class: "value cycle", title: "An alias of a node that contains it" }, "↻ cycle");
    case "array":
    case "object":
      return collection(node, ctx, path);
    default:
      return scalarCell(node, ctx, path);
  }
}

// collections

const icons = {
  expand: { rects: [[2.5, 2.5, 11, 11, 1.5]], paths: ["M5 8h6", "M8 5v6"] },
  collapse: { rects: [[2.5, 2.5, 11, 11, 1.5]], paths: ["M5 8h6"] },
  table: { rects: [[2.5, 3, 11, 10, 1.2]], paths: ["M2.5 6.5h11", "M2.5 10h11", "M6 3v10", "M10 3v10"] },
  list: { rects: [[2.5, 3, 11, 2.2, 1], [2.5, 6.9, 11, 2.2, 1], [2.5, 10.8, 11, 2.2, 1]] },
  edit: { paths: ["m11.8 1.8 2.4 2.4-8.1 8.1-3.3.9.9-3.3 8.1-8.1ZM10.7 2.9 4.6 9l-.4 1.4 1.4-.4 6.1-6.1-1-1Z"] },
};

function collection(node: GridArray | GridObject, ctx: Context, path: Segment[]): Node {
  const { state, redraw } = ctx.actions;
  const expanded = state.isExpanded(ctx.document, path);
  const isArray = node.kind === "array";
  const count = isArray ? node.items.length : node.members.length;
  const mode = state.arrayMode(ctx.document, path);
  const summary = h("span", { class: [node.kind, "collapsed"] },
    h("span", { class: [node.kind, "badge"] }, `${isArray ? "Array" : "Object"}[${count}]`),
    h("button", {
      class: "icon-button toggle-button",
      title: expanded ? "Collapse" : "Expand",
      "aria-expanded": String(expanded),
      onclick: () => { state.toggleExpanded(ctx.document, path); redraw(); },
    }, icon(expanded ? icons.collapse : icons.expand)),
    isArray && columnsOf(node.items).length > 0 && h("button", {
      class: "icon-button toggle-button",
      title: mode === "table" ? "Switch to list mode" : "Switch to table mode",
      onclick: () => { state.toggleArrayMode(ctx.document, path); redraw(); },
    }, icon(mode === "table" ? icons.table : icons.list)));
  if (!expanded) return summary;
  const both = document.createDocumentFragment();
  both.append(summary, isArray ? arrayTable(node, ctx, path) : objectTable(node, ctx, path));
  return both;
}

interface Column {
  id: string;
  label: string;
  class: string;
  resizable: boolean;
  defaultWidth?: string;
  minWidth?: string;
}

/** A table with a header row of `columns`; widths are kept under `key`. */
function table(key: string, tableClass: string, headerClass: string,
    columns: Column[], rows: Node[], state: ViewState): HTMLTableElement {
  const header = columns.map((column) => {
    const cell = h("th", {
      class: column.class,
      "data-column": column.resizable ? column.id : undefined,
      "data-default-width": column.defaultWidth,
    }, column.label);
    cell.style.minWidth = column.minWidth ?? (column.resizable ? "80px" : "");
    cell.style.width = state.columnWidth(key, column.id) ?? column.defaultWidth ?? "";
    return cell;
  });
  const element = h("table", { class: tableClass },
    h("thead", null, h("tr", { class: headerClass }, header)),
    h("tbody", null, rows));
  makeResizable(element, key, state);
  return element;
}

function objectTable(node: GridObject, ctx: Context, path: Segment[]): Node {
  const columns: Column[] = [
    { id: "key", label: "", class: "object key", resizable: true, defaultWidth: "10rem", minWidth: "6rem" },
    { id: "value", label: "", class: "object value", resizable: true },
  ];
  const rows = node.members.map(([name, value]) => {
    const member = [...path, name];
    return h("tr", { class: "object member" },
      h("th", { class: "object key" }, keyCell(name, ctx, member)),
      h("td", { class: "object element" }, renderNode(value, ctx, member)));
  });
  return table(`object:${stateKey(ctx.document, path)}`, "object expanded", "object-hdr",
    columns, rows, ctx.actions.state);
}

function arrayTable(node: GridArray, ctx: Context, path: Segment[]): Node {
  const names = columnsOf(node.items);
  const mode = names.length > 0 ? ctx.actions.state.arrayMode(ctx.document, path) : "list";
  const index = (i: number, item: GridNode) => h("td", { class: ["index", item.kind] }, String(i));
  let columns: Column[];
  let rows: Node[];
  if (mode === "table") {
    columns = [
      { id: "#", label: "", class: "index", resizable: false },
      ...names.map((name) => ({ id: `member:${name}`, label: name, class: "array member", resizable: true })),
    ];
    rows = node.items.map((item, i) => {
      if (item.kind !== "object") {
        return h("tr", { class: ["array-el", item.kind] }, index(i, item),
          h("td", { class: "value", colspan: names.length }, renderNode(item, ctx, [...path, i])));
      }
      // a member an item does not have is an empty cell, since there is no
      // node to edit there
      return h("tr", { class: "array-el object" }, index(i, item), names.map((name) => {
        const value = memberOf(item, name);
        return h("td", { class: "member" }, value && renderNode(value, ctx, [...path, i, name]));
      }));
    });
  } else {
    columns = [
      { id: "#", label: "index", class: "index", resizable: false },
      { id: "value", label: "value", class: "array member", resizable: true },
    ];
    rows = node.items.map((item, i) =>
      h("tr", { class: ["array-el", "list-mode", item.kind] }, index(i, item),
        h("td", { class: "value" }, renderNode(item, ctx, [...path, i]))));
  }
  return table(`array:${mode}:${stateKey(ctx.document, path)}`, "array expanded", "array-hdr",
    columns, rows, ctx.actions.state);
}

// cells that edit

function scalarCell(node: Scalar, ctx: Context, path: Segment[]): Node {
  const key = `value:${stateKey(ctx.document, path)}`;
  if (editing?.key === key) {
    return editor(editing, isMultiline(node), ctx.actions,
      (draft) => ctx.actions.assign(ctx.document, path, valueOfDraft(node, draft)));
  }
  return h("span", { class: "value-inline hover-edit-anchor" },
    h("span", { class: ["value", node.kind] }, displayText(node)),
    editButton("Edit value", () => openEditor(key, node.text, ctx.actions)));
}

function keyCell(name: string, ctx: Context, path: Segment[]): Node {
  const key = `key:${stateKey(ctx.document, path)}`;
  if (editing?.key === key) {
    return editor(editing, false, ctx.actions, async (draft) => {
      const next = draft.trim();
      if (next === "") return "A property name cannot be empty.";
      if (next === name) return undefined;
      return ctx.actions.rename(ctx.document, path, next);
    }, "key-input");
  }
  return h("span", { class: "key-inline hover-edit-anchor" },
    h("span", null, name),
    editButton("Rename property", () => openEditor(key, name, ctx.actions)));
}

function editButton(title: string, onclick: () => void): Node {
  return h("button", { class: "icon-button hover-edit-button", title, onclick }, icon(icons.edit));
}

function openEditor(key: string, draft: string, actions: Actions): void {
  editing = { key, draft, busy: false, selection: [draft.length, draft.length] };
  actions.redraw();
}

/**
 * The editor of `current`: a line, or for multi-line strings a text area
 * over a copy of the draft that marks each line break with ↵, since a
 * trailing break is otherwise invisible. Enter saves a line,
 * Ctrl/Cmd+Enter a text area, and Escape cancels. An edit that fails keeps
 * the editor open with the reason, so that the draft is not lost.
 */
function editor(current: Editing, multiline: boolean, actions: Actions,
    save: (draft: string) => Promise<string | undefined>, inputClass = ""): Node {
  editorDrawn = true;
  const commit = async () => {
    if (current.busy) return;
    current.busy = true;
    current.error = undefined;
    actions.redraw();
    const error = await save(current.draft);
    current.busy = false;
    if (error === undefined) {
      if (editing === current) editing = undefined;
    } else {
      current.error = error;
    }
    actions.redraw();
  };
  const cancel = () => {
    editing = undefined;
    actions.redraw();
  };

  const input = multiline
    ? h("textarea", { class: "yaml-textarea yaml-textarea-overlay", spellcheck: "false" })
    : h("input", { class: ["yaml-input", inputClass], spellcheck: "false" });
  input.value = current.draft;
  input.disabled = current.busy;
  const remember = () => {
    current.draft = input.value;
    current.selection = [input.selectionStart ?? 0, input.selectionEnd ?? 0];
  };
  for (const event of ["input", "keyup", "pointerup", "select"]) input.addEventListener(event, remember);
  input.onkeydown = (event) => {
    if (event.key === "Escape") {
      event.preventDefault();
      cancel();
    } else if (event.key === "Enter" && (!multiline || event.ctrlKey || event.metaKey)) {
      event.preventDefault();
      remember();
      commit();
    }
  };

  let field: Node = input;
  if (multiline) {
    const preview = h("pre", { class: "yaml-textarea-preview", "aria-hidden": "true" });
    const fill = () => preview.replaceChildren(...draftLines(current.draft).map((line) =>
      // an empty line still needs a line's height
      h("span", { class: "preview-line" }, line.text || "\u200b",
        line.hasBreak && h("span", { class: "hard-break-marker" }, "↵"))));
    fill();
    input.addEventListener("input", fill);
    field = h("span", { class: "textarea-overlay" }, preview, input);
  }

  // the new editor takes the focus and caret of the one it replaces
  requestAnimationFrame(() => {
    if (!input.isConnected || current.busy) return;
    input.focus({ preventScroll: true });
    const [start, end] = current.selection ?? [current.draft.length, current.draft.length];
    input.setSelectionRange(start, end);
  });

  return h("span", { class: ["inline-editor", multiline && "multiline", "editing"] },
    field,
    h("span", { class: ["editor-actions", multiline && "multiline"] },
      h("button", { class: "cell-action", disabled: current.busy, onclick: () => { remember(); commit(); } },
        current.busy ? "saving…" : "save"),
      h("button", { class: "cell-action subtle-action", onclick: cancel }, "cancel"),
      multiline && h("span", { class: "editor-hint" }, "Ctrl/Cmd+Enter saves"),
      current.error && h("span", { class: "edit-error", role: "alert" }, current.error)));
}
