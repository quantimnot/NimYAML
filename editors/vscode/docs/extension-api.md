# Extension API

`activate` returns an API that other extensions reach through
`vscode.extensions.getExtension("nimyaml.yaml-plus-lsp")`.

## Hover Transformer

A hover transformer changes the hovers of YAML documents before VS Code
shows them, for example to render math or diagrams in schema descriptions
(after [redhat-developer/vscode-yaml#1304](https://github.com/redhat-developer/vscode-yaml/pull/1304)).
It receives each hover once yamllsp has computed it:

```typescript
const yaml = await vscode.extensions.getExtension("nimyaml.yaml-plus-lsp")?.activate();
if (yaml?.registerHoverTransformer) {
  context.subscriptions.push(
    yaml.registerHoverTransformer((hover, document, position, token) =>
      new vscode.Hover([...hover.contents, new vscode.MarkdownString("*Shown by my extension*")], hover.range)),
  );
}
```

```typescript
type HoverTransformer = (
  hover: vscode.Hover,
  document: vscode.TextDocument,
  position: vscode.Position,
  token: vscode.CancellationToken,
) => vscode.ProviderResult<vscode.Hover>;

registerHoverTransformer(transformer: HoverTransformer): vscode.Disposable;
```

- A transformer returns a new hover, or `undefined` (or `null`) to keep the
  hover it received, which it may have changed in place. It may be async.
- Transformers run in registration order; each receives the hover as the
  previous one left it.
- One that throws or rejects is logged to the extension host's console and
  skipped; the rest still run.
- They are not called when yamllsp has no hover or the request is cancelled.
- They stay registered when yamllsp restarts. The returned disposable
  unregisters the transformer.
- They see yamllsp's hovers only. Hovers inside embedded-language block
  scalars come from the extensions of those languages, and hovers of other
  YAML extensions come from those; VS Code shows them all side by side.

Older versions of this extension do not have the API, so check that
`registerHoverTransformer` exists before calling it.
