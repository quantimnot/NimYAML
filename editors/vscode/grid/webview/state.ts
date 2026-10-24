// What the view remembers about a file besides its content: which nodes are
// expanded, which arrays are shown as lists instead of tables, and the
// widths columns were dragged to.
//
// It is kept with the webview's `setState`, which VS Code hands back when
// the editor is shown again after being hidden or after a reload, so the
// grid does not have to stay alive in the background
// (`retainContextWhenHidden`, which the upstream viewer used) to come back
// as it was left. Nodes are named by `stateKey` (model.ts): document index
// and path. That a node is remembered by its path means an expanded `a[3]`
// stays expanded when an item is inserted before it, and now shows the
// item that moved there; following nodes across edits would need an
// identity the text does not have.

import { stateKey } from "./model";
import type { Segment } from "./protocol";

export type ArrayMode = "table" | "list";

interface Saved {
  expanded: Record<string, boolean>;
  modes: Record<string, ArrayMode>;
  // table key -> column -> CSS width
  widths: Record<string, Record<string, string>>;
}

export interface Persistence {
  getState(): unknown;
  setState(state: unknown): void;
}

export class ViewState {
  private saved: Saved;

  constructor(private readonly persistence: Persistence) {
    const restored = persistence.getState() as Partial<Saved> | undefined;
    this.saved = {
      expanded: restored?.expanded ?? {},
      modes: restored?.modes ?? {},
      widths: restored?.widths ?? {},
    };
  }

  /** Roots start expanded, everything else collapsed, as upstream. */
  isExpanded(document: number, path: Segment[]): boolean {
    return this.saved.expanded[stateKey(document, path)] ?? path.length === 0;
  }

  toggleExpanded(document: number, path: Segment[]): void {
    this.saved.expanded[stateKey(document, path)] = !this.isExpanded(document, path);
    this.save();
  }

  arrayMode(document: number, path: Segment[]): ArrayMode {
    return this.saved.modes[stateKey(document, path)] ?? "table";
  }

  toggleArrayMode(document: number, path: Segment[]): void {
    const key = stateKey(document, path);
    this.saved.modes[key] = this.arrayMode(document, path) === "table" ? "list" : "table";
    this.save();
  }

  columnWidth(table: string, column: string): string | undefined {
    return this.saved.widths[table]?.[column];
  }

  /** Sets or, with `undefined`, forgets the width of a column. */
  setColumnWidth(table: string, column: string, width: string | undefined): void {
    const widths = (this.saved.widths[table] ??= {});
    if (width === undefined) delete widths[column];
    else widths[column] = width;
    this.save();
  }

  private save(): void {
    this.persistence.setState(this.saved);
  }
}
