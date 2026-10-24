// The grid webview: receives the documents of a file from the extension
// host (grid/index.js) and draws them (render.ts); edits go back to the
// host, which has yamllsp apply them to the text.
//
// While the text does not load, as it does not halfway through typing, the
// grid keeps showing the last version that did, under a banner that says
// where the text stopped making sense. The upstream viewer kept the old
// version too, but silently.

import { h } from "./dom";
import type { GridError, GridNode, HostMessage, Segment, ViewMessage } from "./protocol";
import { renderDocuments, type Actions } from "./render";
import { ViewState } from "./state";

declare function acquireVsCodeApi(): {
  postMessage(message: ViewMessage): void;
  getState(): unknown;
  setState(state: unknown): void;
};

const vscode = acquireVsCodeApi();
const root = document.getElementById("grid")!;

// the last documents that loaded, and why the current text does not
let shown: GridNode[] | undefined;
let error: GridError | undefined;
let serverMissing = false;

// edits waiting for the host's answer, by request id
const pending = new Map<number, (error?: string) => void>();
let nextId = 1;

function request(message: DistributiveOmit<ViewMessage & { id: number }, "id">): Promise<string | undefined> {
  const id = nextId++;
  vscode.postMessage({ ...message, id } as ViewMessage);
  return new Promise((resolve) => pending.set(id, resolve));
}

type DistributiveOmit<T, K extends keyof T> = T extends unknown ? Omit<T, K> : never;

const actions: Actions = {
  state: new ViewState(vscode),
  redraw,
  assign: (document: number, path: Segment[], value: string) =>
    request({ type: "assign", document, path, value }),
  rename: (document: number, path: Segment[], name: string) =>
    request({ type: "rename", document, path, name }),
};

function redraw(): void {
  // a redraw replaces every element, so the scroll position is restored
  const { scrollX, scrollY } = window;
  const banner = error && h("div", { class: "error-banner", role: "status" },
    serverMissing ? error.message
    : `Line ${error.line + 1}, column ${error.character + 1}: ${error.message}` +
      (shown ? " The grid shows the last version that loaded." : ""));
  root.replaceChildren(...[
    banner,
    shown ? renderDocuments(shown, actions)
    : !error && h("p", { class: "empty" }, "Loading…"),
  ].filter((n): n is HTMLElement => n instanceof Node));
  window.scrollTo(scrollX, scrollY);
}

window.addEventListener("message", (event: MessageEvent<HostMessage>) => {
  const message = event.data;
  switch (message.type) {
    case "update":
      serverMissing = message.documents === null;
      error = message.error;
      // documents that do not load come without documents
      if (message.documents !== null && !(error && message.documents.length === 0)) {
        shown = message.documents;
      }
      redraw();
      break;
    case "editResult":
      pending.get(message.id)?.(message.error);
      pending.delete(message.id);
      break;
  }
});

redraw();
vscode.postMessage({ type: "ready" });
