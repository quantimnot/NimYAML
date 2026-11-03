// A host over the real file system and standard streams, through `node:`
// modules, which Node, Bun and Deno all provide.
//
// It is what makes the compiled yaml command a command (js/bin/yaml.mjs):
// files are read and written where they are, and output goes to the
// process's own streams. Every method is synchronous, as the contract in
// yaml/private/jshost.nim requires; a failure is an answer (null, false),
// never an exception, since the compiled code turns answers into its own
// errors (IOError, OSError) with the path in the message.
//
// It has the contract's optional methods as well: links and permissions,
// so that writing a file in place keeps its symbolic link and its mode,
// and reading in ranges, so that a file larger than the memory budget
// allows is read by seeking rather than whole, as natively.

import * as fs from "node:fs";
import process from "node:process";
import { isatty } from "node:tty";

const attempt = (action) => {
  try { action(); return true; } catch { return false; }
};

export function nodeHost() {
  return {
    read(path) {
      try {
        const bytes = fs.readFileSync(path);
        return new Uint8Array(bytes.buffer, bytes.byteOffset, bytes.length);
      } catch { return null; }
    },
    write: (path, bytes) => attempt(() => fs.writeFileSync(path, bytes)),
    stat(path) {
      try {
        const s = fs.statSync(path);
        return s.isDirectory() ? "dir" : "file";
      } catch { return null; }
    },
    mtime(path) {
      try { return fs.statSync(path).mtimeMs; } catch { return null; }
    },
    mkdir: (path) => attempt(() => fs.mkdirSync(path, { recursive: true })),
    remove: (path) => attempt(() => fs.unlinkSync(path)),
    rename: (from, to) => attempt(() => fs.renameSync(from, to)),
    cwd: () => process.cwd(),
    env: (name) => process.env[name],
    stdin() {
      try { return new Uint8Array(fs.readFileSync(0)); }
      catch { return new Uint8Array(); }
    },
    output(fd, bytes) {
      let done = 0;
      while (done < bytes.length) {
        try { done += fs.writeSync(fd, bytes, done); }
        catch (e) { if (e.code !== "EAGAIN") throw e; }
      }
    },
    isatty: (fd) => isatty(fd),
    isLink(path) {
      try { return fs.lstatSync(path).isSymbolicLink(); } catch { return false; }
    },
    realpath(path) {
      try { return fs.realpathSync(path); } catch { return null; }
    },
    mode(path) {
      try { return fs.statSync(path).mode & 0o777; } catch { return null; }
    },
    chmod: (path, mode) => attempt(() => fs.chmodSync(path, mode)),
    size(path) {
      try { return fs.statSync(path).size; } catch { return null; }
    },
    readAt(path, offset, length) {
      let fd;
      try {
        fd = fs.openSync(path, "r");
        const bytes = new Uint8Array(length);
        const n = fs.readSync(fd, bytes, 0, length, offset);
        return bytes.subarray(0, n);
      } catch { return null; }
      finally { if (fd !== undefined) fs.closeSync(fd); }
    },
  };
}
