// Hover transformers: other extensions change yamllsp's hovers before VS
// Code shows them, e.g. to render math or diagrams in schema descriptions,
// after redhat-developer/vscode-yaml#1304.
//
// They run in the client's hover middleware, so they see yamllsp's hovers
// only; the hovers of embedded languages (embedded/providers.js) come from
// the extensions of those languages and are left alone. Nothing here needs
// VS Code, so it is tested on its own.

class HoverTransformers {
  /** `onError(error)` is told about a transformer that threw. */
  constructor(onError = (e) => console.error("yaml+lsp: hover transformer failed", e)) {
    this.transformers = [];
    this.onError = onError;
  }

  /**
   * Adds `transformer(hover, document, position, token)`, which returns the
   * hover to show, or `undefined` to keep the one it was given (which it may
   * have changed in place). Returns a disposable that removes it.
   */
  register(transformer) {
    if (typeof transformer !== "function") throw new TypeError("a hover transformer must be a function");
    // a wrapper, so that registering one function twice is two registrations
    const entry = { transformer };
    this.transformers.push(entry);
    return { dispose: () => { this.transformers = this.transformers.filter((e) => e !== entry); } };
  }

  /**
   * The `provideHover` middleware: yamllsp's hover, passed through the
   * transformers in registration order. They are not called when there is
   * no hover or the request was cancelled; one that throws is reported and
   * skipped.
   */
  provideHover = async (document, position, token, next) => {
    let hover = await next(document, position, token);
    // a copy, so that a transformer disposing itself or another does not
    // change this run
    for (const { transformer } of [...this.transformers]) {
      if (!hover || token.isCancellationRequested) break;
      try {
        hover = (await transformer(hover, document, position, token)) ?? hover;
      } catch (e) {
        this.onError(e);
      }
    }
    return hover;
  };
}

module.exports = { HoverTransformers };
