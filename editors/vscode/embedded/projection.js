// Projections: each region of a YAML document written to a file of its
// language, which that language's extension then serves like any other.
//
// Real files, because nothing else reaches the servers that matter. Almost
// every language extension other than VS Code's built-in ones registers for
// `scheme: file` only, so a virtual document is invisible to them. And
// diagnostics are pushed by their owner, read back with
// `languages.getDiagnostics`; there is no command that asks a server for
// them, so the projection has to be a document the server already analyzes:
// a file, opened, written ahead of any request. Projections live in the
// workspace by default so that imports and project configuration resolve;
// `projection.root: temp` keeps them out of it at the cost of that.

const vscode = require("vscode");
const crypto = require("crypto");
const os = require("os");
const path = require("path");
const { resolveRegions, RegionMap } = require("./core");
const { readConfig } = require("./config");

const tempRoot = path.join(os.tmpdir(), "nimyaml-embedded");

function sha1(s) {
  return crypto.createHash("sha1").update(s).digest("hex");
}

const position = (p) => new vscode.Position(p.line, p.character);
const range = (r) => new vscode.Range(position(r.start), position(r.end));

/** `RegionMap` in VS Code's types. */
class HostMap {
  constructor(region) {
    this.core = new RegionMap(region);
  }
  containsHost(p) {
    return this.core.containsLine(p.line);
  }
  toProjection(p) {
    return position(this.core.toProjection(p));
  }
  toHost(p) {
    return position(this.core.toHost(p));
  }
  toProjectionRange(r) {
    return range(this.core.toProjectionRange(r));
  }
  toHostRange(r) {
    return range(this.core.toHostRange(r));
  }
  toHostEdit(e) {
    return new vscode.TextEdit(this.toHostRange(e.range), this.core.reindent(e.newText));
  }
}

class ProjectionStore {
  /**
   * `fetchBlocks(document)` asks yamllsp for the block scalars of a
   * document (`nimyaml/blockScalars`).
   */
  constructor(registry, fetchBlocks) {
    this.registry = registry;
    this.fetchBlocks = fetchBlocks;
    this.hosts = new Map(); // host uri -> state
    this.owners = new Map(); // projection uri -> {hostUri, projection}
    this.pending = new Map(); // host uri -> {version, promise}
    this.onDidReproject = new vscode.EventEmitter();
  }

  dispose() {
    this.onDidReproject.dispose();
  }

  roots() {
    const dir = readConfig().projectionDirectory;
    return [
      tempRoot,
      ...(vscode.workspace.workspaceFolders ?? []).map((f) => path.join(f.uri.fsPath, dir)),
    ];
  }

  /** Whether `uri` is a projection, which must never be a host itself. */
  isProjection(uri) {
    return uri.scheme === "file" &&
      this.roots().some((root) => uri.fsPath.startsWith(root + path.sep));
  }

  projectionsOf(hostUri) {
    return this.hosts.get(hostUri.toString())?.projections ?? [];
  }

  foldedOf(hostUri) {
    return this.hosts.get(hostUri.toString())?.folded ?? [];
  }

  /** The host and projection of the projection file `uri`, if it is one. */
  hostOf(uri) {
    return this.owners.get(uri.toString());
  }

  root(hostUri) {
    const cfg = readConfig();
    const folder = vscode.workspace.getWorkspaceFolder(hostUri) ??
      vscode.workspace.workspaceFolders?.[0];
    if (cfg.projectionRoot === "temp" || !folder) return vscode.Uri.file(tempRoot);
    return vscode.Uri.joinPath(folder.uri, cfg.projectionDirectory);
  }

  /**
   * Projections are named by the region's position in the document, so a
   * block inserted above renames the ones below it; keying them by key path
   * would be stable but is not done yet.
   */
  uriFor(hostUri, region) {
    const ext = this.registry.fileExtension(region.languageId);
    if (!ext) return undefined;
    const slug = sha1(hostUri.toString()).slice(0, 8);
    const base = path.basename(hostUri.path).replace(/[^\w.-]/g, "_");
    const name = `${base}.${String(region.ordinal).padStart(3, "0")}${ext}`;
    return vscode.Uri.joinPath(this.root(hostUri), slug, name);
  }

  /**
   * The projections of `doc` as of its current version, projecting it
   * first if needed. Concurrent callers share one projection.
   */
  ensure(doc) {
    if (!readConfig().enabled || this.isProjection(doc.uri)) return Promise.resolve([]);
    const key = doc.uri.toString();
    const state = this.hosts.get(key);
    if (state && state.version === doc.version) return Promise.resolve(state.projections);
    const pending = this.pending.get(key);
    if (pending && pending.version === doc.version) return pending.promise;
    const promise = this.reproject(doc).finally(() => {
      if (this.pending.get(key)?.promise === promise) this.pending.delete(key);
    });
    this.pending.set(key, { version: doc.version, promise });
    return promise;
  }

  /** The projection of `doc` that contains `position`. */
  async at(doc, position) {
    return (await this.ensure(doc)).find((p) => p.map.containsHost(position));
  }

  async blocksOf(doc) {
    // yamllsp answers for the text it has when the request is sent; if the
    // document changes before the answer arrives, ask again.
    for (let attempt = 0; attempt < 3; attempt++) {
      const version = doc.version;
      let blocks;
      try {
        blocks = await this.fetchBlocks(doc);
      } catch (_) {
        return { version, blocks: [] }; // yamllsp is not running
      }
      if (doc.version === version) return { version, blocks: blocks ?? [] };
    }
    return undefined;
  }

  /** Re-reads the regions of `doc` and brings the projection files in line. */
  async reproject(doc) {
    const fetched = await this.blocksOf(doc);
    if (!fetched) return this.projectionsOf(doc.uri);
    const cfg = readConfig();
    const lines = [];
    for (let i = 0; i < doc.lineCount; i++) lines.push(doc.lineAt(i).text);
    const { regions, folded } = resolveRegions(fetched.blocks, lines, {
      aliases: cfg.aliases,
      stickyDirective: cfg.stickyDirective,
      compatDirective: cfg.compatDirective,
      keyRules: cfg.keyRules,
      isKnownLanguage: (id) => this.registry.isProjectable(id),
      docPath: doc.uri.path,
    });

    const key = doc.uri.toString();
    const previous = this.hosts.get(key);
    const projections = [];
    const hashes = new Map();
    for (const region of regions) {
      const uri = this.uriFor(doc.uri, region);
      if (!uri) continue;
      const hash = sha1(region.content);
      // skip writes that change nothing, i.e. on most keystrokes
      if (previous?.hashes.get(uri.toString()) !== hash) await this.write(uri, region.content);
      projections.push({ hostUri: doc.uri, uri, map: new HostMap(region), region });
      hashes.set(uri.toString(), hash);
    }
    for (const old of previous?.projections ?? []) {
      if (!hashes.has(old.uri.toString())) {
        this.owners.delete(old.uri.toString());
        await this.remove(old.uri);
      }
    }
    for (const p of projections) this.owners.set(p.uri.toString(), { hostUri: doc.uri, projection: p });
    this.hosts.set(key, { version: fetched.version, projections, hashes, folded });
    this.onDidReproject.fire(doc.uri);
    return projections;
  }

  async write(uri, content) {
    await vscode.workspace.fs.createDirectory(vscode.Uri.joinPath(uri, ".."));
    // through the file system rather than an edit: an edited document is
    // dirty, and hidden dirty documents cause save prompts
    await vscode.workspace.fs.writeFile(uri, Buffer.from(content, "utf8"));
    // opening is what makes a server analyze it; it is never shown
    const doc = await vscode.workspace.openTextDocument(uri);
    // an open document reloads asynchronously after the write; positions are
    // mapped into it right after, so wait for it to catch up
    for (let i = 0; i < 20 && doc.getText() !== content; i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    if (doc.getText() !== content) {
      const edit = new vscode.WorkspaceEdit();
      edit.replace(uri, new vscode.Range(0, 0, doc.lineCount, 0), content);
      await vscode.workspace.applyEdit(edit);
      await doc.save();
    }
  }

  async remove(uri) {
    try {
      await vscode.workspace.fs.delete(uri);
    } catch (_) {
      // already gone
    }
  }

  /** Forgets `hostUri` and deletes its projections. */
  async forget(hostUri) {
    const state = this.hosts.get(hostUri.toString());
    if (!state) return;
    this.hosts.delete(hostUri.toString());
    for (const p of state.projections) {
      this.owners.delete(p.uri.toString());
      await this.remove(p.uri);
    }
  }

  async cleanAll() {
    for (const key of [...this.hosts.keys()]) await this.forget(vscode.Uri.parse(key));
    for (const root of this.roots()) {
      try {
        await vscode.workspace.fs.delete(vscode.Uri.file(root), { recursive: true });
      } catch (_) {
        // not present
      }
    }
  }
}

module.exports = { ProjectionStore };
