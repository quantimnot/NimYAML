// Language features inside regions, forwarded to the projections through
// VS Code's `vscode.execute*Provider` commands, which run whatever
// providers the projection's language has, and mapped back.
//
// Positions in an answer are projection positions only where the answer
// points at the projection itself; a definition in a library comes back
// with its own file and needs no mapping. Hence every remap below rewrites
// a location if and only if its URI is the projection's.
//
// Every provider here is additive, VS Code merges them with yamllsp's and
// other YAML extensions'. Formatting is the exception, a formatter competes
// for the whole document, so it is a command instead (see extension.js).
// Semantic tokens are not a provider either, VS Code uses one provider per
// document; they are merged into yamllsp's in its client's middleware.

const vscode = require("vscode");

const isSelf = (p, uri) => uri.toString() === p.uri.toString();

function remapLocation(p, loc) {
  if ("targetUri" in loc) {
    if (!isSelf(p, loc.targetUri)) return loc;
    return {
      originSelectionRange: loc.originSelectionRange && p.map.toHostRange(loc.originSelectionRange),
      targetUri: p.hostUri,
      targetRange: p.map.toHostRange(loc.targetRange),
      targetSelectionRange: loc.targetSelectionRange && p.map.toHostRange(loc.targetSelectionRange),
    };
  }
  if (!isSelf(p, loc.uri)) return loc;
  return new vscode.Location(p.hostUri, p.map.toHostRange(loc.range));
}

function remapWorkspaceEdit(p, edit) {
  const out = new vscode.WorkspaceEdit();
  for (const [uri, edits] of edit.entries()) {
    if (isSelf(p, uri)) out.set(p.hostUri, edits.map((e) => p.map.toHostEdit(e)));
    else out.set(uri, edits);
  }
  return out;
}

function remapCompletionItem(p, item) {
  const out = Object.assign(new vscode.CompletionItem(item.label, item.kind), item);
  if (item.range) {
    out.range = "inserting" in item.range
      ? { inserting: p.map.toHostRange(item.range.inserting),
          replacing: p.map.toHostRange(item.range.replacing) }
      : p.map.toHostRange(item.range);
  }
  if (item.textEdit) out.textEdit = p.map.toHostEdit(item.textEdit);
  if (item.additionalTextEdits) {
    out.additionalTextEdits = item.additionalTextEdits.map((e) => p.map.toHostEdit(e));
  }
  // a command (an auto-import follow-up, say) would run against the
  // projection, and its arguments cannot be rewritten
  out.command = undefined;
  return out;
}

function remapSymbols(p, symbols) {
  return symbols.map((s) => {
    const out = new vscode.DocumentSymbol(s.name, s.detail, s.kind,
      p.map.toHostRange(s.range), p.map.toHostRange(s.selectionRange));
    out.children = remapSymbols(p, s.children ?? []);
    return out;
  });
}

function remapDiagnostic(p, d) {
  const out = new vscode.Diagnostic(p.map.toHostRange(d.range), d.message, d.severity);
  out.code = d.code;
  out.tags = d.tags;
  // a YAML line with an error yamllsp did not report needs its origin
  const language = p.region.languageId;
  out.source = d.source ? `${d.source} (${language})` : language;
  if (d.relatedInformation) {
    out.relatedInformation = d.relatedInformation.map((ri) =>
      new vscode.DiagnosticRelatedInformation(remapLocation(p, ri.location), ri.message));
  }
  return out;
}

const forwardAt = (command, p, position, ...rest) =>
  vscode.commands.executeCommand(command, p.uri, p.map.toProjection(position), ...rest);

function registerProviders(store, selector) {
  const at = (doc, pos) => store.at(doc, pos);
  const out = [];

  out.push(vscode.languages.registerHoverProvider(selector, {
    async provideHover(doc, pos) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      const hovers = await forwardAt("vscode.executeHoverProvider", p, pos);
      if (!hovers?.length) return undefined;
      const range = hovers.find((h) => h.range)?.range;
      return new vscode.Hover(hovers.flatMap((h) => h.contents),
        range && p.map.toHostRange(range));
    },
  }));

  out.push(vscode.languages.registerCompletionItemProvider(selector, {
    async provideCompletionItems(doc, pos, _token, context) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      // resolve enough items to have documentation without stalling
      const list = await forwardAt("vscode.executeCompletionItemProvider", p, pos,
        context.triggerCharacter, 50);
      if (!list) return undefined;
      return new vscode.CompletionList(list.items.map((i) => remapCompletionItem(p, i)),
        list.isIncomplete);
    },
  // the trigger characters of all embedded languages cannot be known when
  // registering, so these are the common ones
  }, ...".:$@<\"'/(,=&#*[{|"));

  out.push(vscode.languages.registerSignatureHelpProvider(selector, {
    async provideSignatureHelp(doc, pos, _token, context) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      // signature help has no positions to map
      return forwardAt("vscode.executeSignatureHelpProvider", p, pos, context.triggerCharacter);
    },
  }, "(", ","));

  const locationProviders = [
    ["registerDefinitionProvider", "provideDefinition", "vscode.executeDefinitionProvider"],
    ["registerTypeDefinitionProvider", "provideTypeDefinition", "vscode.executeTypeDefinitionProvider"],
    ["registerDeclarationProvider", "provideDeclaration", "vscode.executeDeclarationProvider"],
    ["registerImplementationProvider", "provideImplementation", "vscode.executeImplementationProvider"],
    ["registerReferenceProvider", "provideReferences", "vscode.executeReferenceProvider"],
  ];
  for (const [register, method, command] of locationProviders) {
    out.push(vscode.languages[register](selector, {
      async [method](doc, pos) {
        const p = await at(doc, pos);
        if (!p) return undefined;
        const locations = await forwardAt(command, p, pos);
        return locations?.map((l) => remapLocation(p, l));
      },
    }));
  }

  out.push(vscode.languages.registerDocumentHighlightProvider(selector, {
    async provideDocumentHighlights(doc, pos) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      const highlights = await forwardAt("vscode.executeDocumentHighlights", p, pos);
      return highlights?.map((h) => new vscode.DocumentHighlight(p.map.toHostRange(h.range), h.kind));
    },
  }));

  out.push(vscode.languages.registerRenameProvider(selector, {
    async prepareRename(doc, pos) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      const r = await forwardAt("vscode.prepareRename", p, pos);
      return r && { range: p.map.toHostRange(r.range), placeholder: r.placeholder };
    },
    async provideRenameEdits(doc, pos, newName) {
      const p = await at(doc, pos);
      if (!p) return undefined;
      // edits outside the block, in project files, are kept: they are right
      const edit = await forwardAt("vscode.executeDocumentRenameProvider", p, pos, newName);
      return edit && remapWorkspaceEdit(p, edit);
    },
  }));

  out.push(vscode.languages.registerCodeActionsProvider(selector, {
    async provideCodeActions(doc, range) {
      const p = await at(doc, range.start);
      if (!p) return undefined;
      const actions = await vscode.commands.executeCommand("vscode.executeCodeActionProvider",
        p.uri, p.map.toProjectionRange(range), undefined, 25);
      // actions that are only commands would run against the projection
      return actions?.filter((a) => a.edit).map((a) => {
        const out = new vscode.CodeAction(a.title, a.kind);
        out.edit = remapWorkspaceEdit(p, a.edit);
        out.isPreferred = a.isPreferred;
        return out;
      });
    },
  }));

  out.push(vscode.languages.registerDocumentSymbolProvider(selector, {
    async provideDocumentSymbols(doc) {
      const symbols = [];
      for (const p of await store.ensure(doc)) {
        const children = await vscode.commands.executeCommand(
          "vscode.executeDocumentSymbolProvider", p.uri);
        if (!children?.length) continue;
        const header = new vscode.Range(p.region.headerLine, 0, p.region.headerLine, 0);
        const container = new vscode.DocumentSymbol(p.region.key ?? `block ${p.region.ordinal + 1}`,
          p.region.languageId, vscode.SymbolKind.Module,
          header.union(new vscode.Range(p.region.end, 0, p.region.end, Number.MAX_SAFE_INTEGER)),
          header);
        container.children = remapSymbols(p, children);
        symbols.push(container);
      }
      return symbols;
    },
  }));

  out.push(vscode.languages.registerInlayHintsProvider(selector, {
    async provideInlayHints(doc, range) {
      const hints = [];
      for (const p of await store.ensure(doc)) {
        if (p.region.end < range.start.line || p.region.start > range.end.line) continue;
        const projected = await vscode.commands.executeCommand("vscode.executeInlayHintProvider",
          p.uri, p.map.toProjectionRange(range));
        for (const h of projected ?? []) {
          const out = new vscode.InlayHint(p.map.toHost(h.position), h.label, h.kind);
          out.paddingLeft = h.paddingLeft;
          out.paddingRight = h.paddingRight;
          out.tooltip = h.tooltip;
          hints.push(out);
        }
      }
      return hints;
    },
  }));

  out.push(vscode.languages.registerFoldingRangeProvider(selector, {
    async provideFoldingRanges(doc) {
      const ranges = [];
      for (const p of await store.ensure(doc)) {
        const projected = await vscode.commands.executeCommand(
          "vscode.executeFoldingRangeProvider", p.uri);
        const offset = p.region.start;
        for (const f of projected ?? []) {
          ranges.push(new vscode.FoldingRange(f.start + offset, f.end + offset, f.kind));
        }
      }
      return ranges;
    },
  }));

  out.push(vscode.languages.registerSelectionRangeProvider(selector, {
    async provideSelectionRanges(doc, positions) {
      const result = [];
      for (const pos of positions) {
        const p = await at(doc, pos);
        if (!p) return undefined; // one per position, or none
        const projected = await vscode.commands.executeCommand(
          "vscode.executeSelectionRangeProvider", p.uri, [p.map.toProjection(pos)]);
        // rebuild the chain in host positions; clamping keeps it inside the block
        const chain = [];
        for (let n = projected?.[0]; n; n = n.parent) chain.push(p.map.toHostRange(n.range));
        let selection;
        for (let i = chain.length - 1; i >= 0; i--) selection = new vscode.SelectionRange(chain[i], selection);
        if (!selection) return undefined;
        result.push(selection);
      }
      return result;
    },
  }));

  out.push(vscode.languages.registerDocumentLinkProvider(selector, {
    async provideDocumentLinks(doc) {
      const links = [];
      for (const p of await store.ensure(doc)) {
        const projected = await vscode.commands.executeCommand("vscode.executeLinkProvider", p.uri);
        for (const l of projected ?? []) {
          links.push(new vscode.DocumentLink(p.map.toHostRange(l.range), l.target));
        }
      }
      return links;
    },
  }));

  out.push(vscode.languages.registerColorProvider(selector, {
    async provideDocumentColors(doc) {
      const colors = [];
      for (const p of await store.ensure(doc)) {
        const projected = await vscode.commands.executeCommand(
          "vscode.executeDocumentColorProvider", p.uri);
        for (const c of projected ?? []) {
          colors.push(new vscode.ColorInformation(p.map.toHostRange(c.range), c.color));
        }
      }
      return colors;
    },
    async provideColorPresentations(color, context) {
      const p = await at(context.document, context.range.start);
      if (!p) return undefined;
      const presentations = await vscode.commands.executeCommand(
        "vscode.executeColorPresentationProvider", color,
        { uri: p.uri, range: p.map.toProjectionRange(context.range) });
      return presentations?.map((cp) => {
        const out = new vscode.ColorPresentation(cp.label);
        if (cp.textEdit) out.textEdit = p.map.toHostEdit(cp.textEdit);
        if (cp.additionalTextEdits) out.additionalTextEdits = cp.additionalTextEdits.map((e) => p.map.toHostEdit(e));
        return out;
      });
    },
  }));

  return out;
}

module.exports = { registerProviders, remapDiagnostic };
