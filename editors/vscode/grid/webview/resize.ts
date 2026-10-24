// Dragging column borders.
//
// A column is resized by dragging its right border anywhere in the table,
// not just in the header, as in the upstream viewer: the header row of an
// object's table is collapsed to nothing, so a handle there could not be
// grabbed. The table therefore watches the pointer and treats any point
// within a few pixels of a resizable header cell's right edge as that
// column's border. Double-clicking a border forgets the width again.
//
// Tables nest. The innermost table under the pointer sees an event first
// and claims it, so that the tables around it do not resize their own
// columns whose borders happen to be close.

import type { ViewState } from "./state";

const THRESHOLD = 6;
const MIN_WIDTH = 80;
const claimed = new WeakSet<Event>();

/**
 * Makes the header cells of `table` that have `data-column` resizable;
 * their widths are kept in `state` under `key`.
 */
export function makeResizable(table: HTMLTableElement, key: string, state: ViewState): void {
  const borderAt = (event: MouseEvent): HTMLTableCellElement | undefined => {
    if (claimed.has(event)) return undefined;
    const bounds = table.getBoundingClientRect();
    if (event.clientY < bounds.top || event.clientY > bounds.bottom) return undefined;
    let closest: HTMLTableCellElement | undefined;
    let distance = THRESHOLD + 1;
    for (const cell of table.tHead?.rows[0]?.cells ?? []) {
      if (cell.dataset.column === undefined) continue;
      const d = Math.abs(event.clientX - cell.getBoundingClientRect().right);
      if (d <= THRESHOLD && d < distance) [closest, distance] = [cell, d];
    }
    if (closest) claimed.add(event);
    return closest;
  };

  table.addEventListener("pointermove", (event) => {
    table.classList.toggle("resize-hover", borderAt(event) !== undefined);
  });
  table.addEventListener("pointerleave", () => table.classList.remove("resize-hover"));

  table.addEventListener("pointerdown", (event) => {
    if (event.button !== 0) return;
    const cell = borderAt(event);
    if (!cell) return;
    event.preventDefault();
    const startX = event.clientX;
    const startWidth = cell.getBoundingClientRect().width;
    table.setPointerCapture(event.pointerId);
    document.body.classList.add("resizing");
    const move = (e: PointerEvent) => {
      cell.style.width = `${Math.max(MIN_WIDTH, Math.round(startWidth + e.clientX - startX))}px`;
    };
    const end = () => {
      table.removeEventListener("pointermove", move);
      table.removeEventListener("lostpointercapture", end);
      document.body.classList.remove("resizing");
      state.setColumnWidth(key, cell.dataset.column!, cell.style.width);
    };
    table.addEventListener("pointermove", move);
    table.addEventListener("lostpointercapture", end);
  });

  table.addEventListener("dblclick", (event) => {
    const cell = borderAt(event);
    if (!cell) return;
    state.setColumnWidth(key, cell.dataset.column!, undefined);
    cell.style.width = cell.dataset.defaultWidth ?? "";
  });
}
