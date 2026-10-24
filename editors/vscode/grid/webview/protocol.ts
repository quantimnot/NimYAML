// The messages between the grid webview and the extension host, and the
// documents they carry.
//
// The documents are trees that yamllsp's `nimyaml/grid` builds
// (tools/yamllsp.nim, "Grid"): the JSON data model of each YAML document,
// but with mappings as lists of pairs, so that the order of the source
// survives (a JavaScript object would move a key like "1" to the front),
// and scalars as their kind and their text as written, so that `~` and
// `1e3` are shown as the author wrote them rather than as JavaScript reads
// them. The host forwards these trees unchanged; it is plain JavaScript and
// these types are for the webview alone.

export type ScalarKind = "string" | "number" | "boolean" | "null";

export interface Scalar {
  kind: ScalarKind;
  text: string;
}

export interface GridArray {
  kind: "array";
  items: GridNode[];
}

export interface GridObject {
  kind: "object";
  members: [name: string, value: GridNode][];
}

/** Where an alias would repeat a node that contains it. */
export interface Cycle {
  kind: "cycle";
}

export type GridNode = Scalar | GridArray | GridObject | Cycle;

/** A member name or an item index on the way from a document's root. */
export type Segment = string | number;

export interface GridError {
  message: string;
  /** 0-based, as LSP positions are */
  line: number;
  character: number;
}

export type HostMessage =
  // `documents` is null when the server cannot be asked; `error` then says
  // why. A document that does not load gives an error and no documents.
  | { type: "update"; documents: GridNode[] | null; error?: GridError }
  | { type: "editResult"; id: number; error?: string };

export type ViewMessage =
  | { type: "ready" }
  // `value` is YAML: a string cell's draft is sent quoted, so that it stays
  // a string, and other drafts as typed, so that `[1, 2]` becomes a list
  | { type: "assign"; id: number; document: number; path: Segment[]; value: string }
  | { type: "rename"; id: number; document: number; path: Segment[]; name: string };
