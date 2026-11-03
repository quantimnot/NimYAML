// A host whose files are a map in memory.
//
// The compiled NimYAML reads and writes files only through the host it is
// given (yaml/private/jshost.nim has the contract). This one keeps them in a
// Map from absolute path to bytes, and the standard streams in strings, so
// that the library and the yaml command run where there is no file system
// at all — a browser page, a worker — and so that tests see exactly what a
// command wrote.
//
// The language server's worker needs one more thing of it. The files the
// server reads (configs, `file:` schemas) belong to the page, which the
// worker can only ask, asynchronously, while the server reads synchronously.
// So a path the host does not know is a *miss*: the host answers that the
// file does not exist, as it must at once, and reports the path to
// `onMiss`. The worker asks the page for the paths missed during a step,
// stores the answers with `put` — a text, or null for "no such file", which
// is then known and no longer a miss — and tells the server to read again.
// Without `onMiss` an unknown path is simply absent.
//
// Directories exist implicitly, as the parents of files, or explicitly once
// created. Paths are POSIX paths; a relative one is resolved against `cwd`.

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function normalize(path, cwd) {
  const absolute = path.startsWith("/") ? path : `${cwd}/${path}`;
  const parts = [];
  for (const part of absolute.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") parts.pop();
    else parts.push(part);
  }
  return "/" + parts.join("/");
}

const bytesOf = (content) =>
  typeof content === "string" ? encoder.encode(content) : content;

export function memoryHost({ files = {}, cwd = "/", env = {}, stdin = "",
                             tty = false, onMiss = null } = {}) {
  const contents = new Map();   // path -> { bytes, mtime }
  const absent = new Set();     // paths known not to exist (no longer misses)
  const dirs = new Set(["/"]);  // directories created explicitly
  const output = { 1: [], 2: [] };
  const at = (path) => normalize(path, cwd);

  const isDir = (path) => {
    if (dirs.has(path)) return true;
    const prefix = path === "/" ? "/" : path + "/";
    for (const file of contents.keys()) if (file.startsWith(prefix)) return true;
    return false;
  };
  const miss = (path) => {
    if (onMiss && !absent.has(path) && !isDir(path)) onMiss(path);
  };

  const host = {
    read(path) {
      const entry = contents.get(at(path));
      if (entry) return entry.bytes;
      miss(at(path));
      return null;
    },
    write(path, bytes) {
      const p = at(path);
      contents.set(p, { bytes: Uint8Array.from(bytes), mtime: Date.now() });
      absent.delete(p);
      return true;
    },
    stat(path) {
      const p = at(path);
      if (contents.has(p)) return "file";
      if (isDir(p)) return "dir";
      miss(p);
      return null;
    },
    mtime(path) {
      const entry = contents.get(at(path));
      return entry ? entry.mtime : null;
    },
    mkdir(path) {
      let p = at(path);
      while (p !== "/") {
        if (contents.has(p)) return false;
        dirs.add(p);
        p = p.slice(0, p.lastIndexOf("/")) || "/";
      }
      return true;
    },
    remove(path) {
      const p = at(path);
      absent.add(p);
      return contents.delete(p);
    },
    rename(from, to) {
      const entry = contents.get(at(from));
      if (!entry) return false;
      contents.delete(at(from));
      absent.add(at(from));
      contents.set(at(to), entry);
      absent.delete(at(to));
      return true;
    },
    cwd: () => cwd,
    env: (name) => env[name],
    stdin: () => bytesOf(stdin),
    output(fd, bytes) {
      output[fd]?.push(decoder.decode(bytes, { stream: true }));
    },
    isatty: (fd) => tty,

    // for the embedder, not for NimYAML

    /** Stores a file, or with null records that there is none. */
    put(path, content) {
      const p = at(path);
      if (content === null || content === undefined) {
        contents.delete(p);
        absent.add(p);
      } else {
        contents.set(p, { bytes: bytesOf(content), mtime: Date.now() });
        absent.delete(p);
      }
    },
    /** A file's text, or null. */
    text(path) {
      const entry = contents.get(at(path));
      return entry ? decoder.decode(entry.bytes) : null;
    },
    /** The paths of all files. */
    paths: () => [...contents.keys()].sort(),
    /** What was written to standard output (1) or error (2), and clears it. */
    take(fd) {
      const text = output[fd].join("");
      output[fd].length = 0;
      return text;
    },
  };
  for (const [path, content] of Object.entries(files)) host.put(path, content);
  return host;
}
