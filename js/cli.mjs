// The yaml command (tools/yamlcli.nim), compiled to JavaScript, as a
// function: run(args, {host}) runs it on the host's files and standard
// streams and returns its exit code.
//
// The command is the same program as the native `yaml`, subcommands and
// all (get, set, query, lint, expand, format, diff, patch, schema, ...):
// what differs is only where its files and streams are. With nodeHost
// that is the real file system and the process's streams (bin/yaml.mjs);
// with memoryHost it is a map and two strings, which is how a page or a
// test runs it:
//
//   const host = memoryHost({ files: { "/a.yaml": "a: 1\n" } });
//   run(["get", "/a.yaml", "$.a"], { host });   // 0
//   host.take(1);                                // "1\n"
//
// The host is installed for the run, and stays installed afterwards: the
// compiled program has one, as a process has one file system.

import * as nimyaml from "./dist/nimyaml.mjs";

export function run(args, { host }) {
  if (!host) throw new TypeError("run needs a host");
  nimyaml.installHost(host);
  return nimyaml.runCli(JSON.stringify(args));
}
