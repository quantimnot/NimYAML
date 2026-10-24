// Building elements without a framework.
//
// The upstream viewer (greenflute/yaml-grid-viewer) was a Vue app; this
// port draws with the DOM directly. Everything is redrawn from the document
// and the view state whenever either changes (see render.ts), so the only
// helper needed is one that writes an element, its attributes, its event
// handlers and its children in one expression, which keeps the shape of
// each table readable in the code that builds it.

type Child = Node | string | null | undefined | false;

type Props = {
  class?: string | (string | false | null | undefined)[];
  title?: string;
  // event handlers, e.g. `onclick`
  [event: `on${string}`]: ((event: any) => void) | undefined;
} & { [attribute: string]: unknown };

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K, props: Props | null = null, ...children: (Child | Child[])[]
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  for (const [name, value] of Object.entries(props ?? {})) {
    if (value === undefined || value === null || value === false) continue;
    if (name === "class") {
      element.className = Array.isArray(value) ? value.filter(Boolean).join(" ") : String(value);
    } else if (name.startsWith("on")) {
      element.addEventListener(name.slice(2), value as EventListener);
    } else {
      element.setAttribute(name, value === true ? "" : String(value));
    }
  }
  append(element, children);
  return element;
}

function append(parent: Node, children: (Child | Child[])[]): void {
  for (const child of children) {
    if (Array.isArray(child)) append(parent, child);
    else if (child instanceof Node) parent.appendChild(child);
    else if (typeof child === "string") parent.appendChild(document.createTextNode(child));
  }
}

const SVG = "http://www.w3.org/2000/svg";

/**
 * A 16×16 stroked icon from SVG path data (the icons of the upstream
 * viewer); `rect` entries are `x y width height radius`.
 */
export function icon(shapes: { paths?: string[]; rects?: number[][] }): SVGSVGElement {
  const svg = document.createElementNS(SVG, "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("class", "icon");
  svg.setAttribute("aria-hidden", "true");
  for (const [x, y, width, height, rx] of shapes.rects ?? []) {
    const rect = document.createElementNS(SVG, "rect");
    for (const [k, v] of Object.entries({ x, y, width, height, rx })) rect.setAttribute(k, String(v));
    svg.appendChild(rect);
  }
  for (const d of shapes.paths ?? []) {
    const path = document.createElementNS(SVG, "path");
    path.setAttribute("d", d);
    svg.appendChild(path);
  }
  return svg;
}
