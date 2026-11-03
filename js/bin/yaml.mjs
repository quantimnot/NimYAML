#!/usr/bin/env node
// The yaml command on Node, Bun or Deno: `node js/bin/yaml.mjs ARGS`
// behaves as the native `yaml ARGS`, on the real files and streams.
// `yaml lsp`, which serves until its input ends, is the exception: the
// compiled program reads standard input whole, so it would answer nothing
// until then; the language server's driver for streams is lsp/stdio.mjs.

import process from "node:process";
import { run } from "../cli.mjs";
import { nodeHost } from "../hosts/node.mjs";

process.exitCode = run(process.argv.slice(2), { host: nodeHost() });
