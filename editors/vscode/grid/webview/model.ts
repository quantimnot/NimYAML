// What the grid decides about a document before any of it is drawn: which
// columns an array's table has, how a scalar reads and what editing it
// sends. These are pure functions, kept apart from the DOM so that
// test/grid.test.js can check them without a browser.

import type { GridNode, Scalar, Segment } from "./protocol";

/**
 * The columns of the table of an array: the member names of its object
 * items, in the order they first appear. An array without object items has
 * none and is shown as a list.
 */
export function columnsOf(items: GridNode[]): string[] {
  const columns = new Set<string>();
  for (const item of items) {
    if (item.kind === "object") for (const [name] of item.members) columns.add(name);
  }
  return [...columns];
}

/** The value of the member `name` of an object node, if it has one. */
export function memberOf(node: GridNode, name: string): GridNode | undefined {
  if (node.kind !== "object") return undefined;
  return node.members.find(([n]) => n === name)?.[1];
}

/** The text a scalar is shown with; an empty null reads `null`. */
export function displayText(scalar: Scalar): string {
  return scalar.kind === "null" && scalar.text === "" ? "null" : scalar.text;
}

/** Whether a scalar is edited in a text area rather than a line. */
export function isMultiline(scalar: Scalar): boolean {
  return scalar.kind === "string" && scalar.text.includes("\n");
}

/**
 * The YAML an edited draft is assigned as. A string stays a string however
 * the draft reads, so it is sent quoted; any other scalar is sent as typed,
 * which lets `42` become a number, `[1, 2]` a list and `abc` a string. An
 * empty draft is null, which an empty YAML document would not be.
 */
export function valueOfDraft(scalar: Scalar, draft: string): string {
  if (scalar.kind === "string") return JSON.stringify(draft);
  return draft.trim() === "" ? "~" : draft;
}

/**
 * The key under which the view state of a node is remembered: its document
 * and path, so that expanding `a` in one document does not expand it in
 * another.
 */
export function stateKey(document: number, path: Segment[]): string {
  return JSON.stringify([document, ...path]);
}

/** The draft text split into lines, for the overlay that marks line breaks. */
export function draftLines(draft: string): { text: string; hasBreak: boolean }[] {
  const lines = draft.split("\n");
  return lines.map((text, i) => ({ text, hasBreak: i < lines.length - 1 }));
}
