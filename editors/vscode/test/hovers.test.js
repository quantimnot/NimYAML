// Tests of hovers/index.js; run with `bun test`.

const test = require("node:test");
const assert = require("node:assert/strict");
const { HoverTransformers } = require("../hovers");

const token = (cancelled = false) => ({ isCancellationRequested: cancelled });
const hover = (...contents) => ({ contents });
const serving = (h) => async () => h;

test("without transformers, the server's hover", async () => {
  const hovers = new HoverTransformers();
  const h = hover("a");
  assert.equal(await hovers.provideHover({}, {}, token(), serving(h)), h);
});

test("transformers run in registration order until disposed", async () => {
  const hovers = new HoverTransformers();
  const seen = [];
  const doc = { uri: "file:///a.yaml" };
  const pos = { line: 1, character: 2 };
  const first = hovers.register((h, d, p, t) => {
    seen.push([d, p, t]);
    return hover(...h.contents, "first");
  });
  // edits in place and keeps the hover
  const second = hovers.register(async (h) => {
    h.contents[h.contents.length - 1] += " second";
    return undefined;
  });
  const t = token();
  assert.deepEqual((await hovers.provideHover(doc, pos, t, serving(hover("a")))).contents, ["a", "first second"]);
  assert.deepEqual(seen, [[doc, pos, t]]);
  first.dispose();
  assert.deepEqual((await hovers.provideHover(doc, pos, t, serving(hover("a")))).contents, ["a second"]);
  second.dispose();
  assert.deepEqual((await hovers.provideHover(doc, pos, t, serving(hover("a")))).contents, ["a"]);
});

test("one function registered twice runs twice and is disposed once at a time", async () => {
  const hovers = new HoverTransformers();
  const add = (h) => hover(...h.contents, "x");
  const one = hovers.register(add);
  hovers.register(add);
  assert.deepEqual((await hovers.provideHover({}, {}, token(), serving(hover()))).contents, ["x", "x"]);
  one.dispose();
  one.dispose();
  assert.deepEqual((await hovers.provideHover({}, {}, token(), serving(hover()))).contents, ["x"]);
});

test("a failing transformer is reported and skipped", async () => {
  const errors = [];
  const hovers = new HoverTransformers((e) => errors.push(e.message));
  hovers.register(() => { throw new Error("thrown"); });
  hovers.register(async () => { throw new Error("rejected"); });
  hovers.register((h) => hover(...h.contents, "after"));
  assert.deepEqual((await hovers.provideHover({}, {}, token(), serving(hover("a")))).contents, ["a", "after"]);
  assert.deepEqual(errors, ["thrown", "rejected"]);
});

test("not called without a hover or once cancelled", async () => {
  const hovers = new HoverTransformers();
  let calls = 0;
  hovers.register(() => { calls++; return null; });
  assert.equal(await hovers.provideHover({}, {}, token(), serving(null)), null);
  assert.equal(await hovers.provideHover({}, {}, token(), serving(undefined)), undefined);
  const h = hover("a");
  assert.equal(await hovers.provideHover({}, {}, token(true), serving(h)), h);
  assert.equal(calls, 0);
  // null keeps the hover, like undefined
  assert.equal(await hovers.provideHover({}, {}, token(), serving(h)), h);
  assert.equal(calls, 1);
});

test("disposing during a run does not change that run", async () => {
  const hovers = new HoverTransformers();
  let later;
  hovers.register((h) => { later.dispose(); return h; });
  later = hovers.register((h) => hover(...h.contents, "later"));
  assert.deepEqual((await hovers.provideHover({}, {}, token(), serving(hover()))).contents, ["later"]);
  assert.deepEqual((await hovers.provideHover({}, {}, token(), serving(hover()))).contents, []);
});

test("only functions can be registered", () => {
  assert.throws(() => new HoverTransformers().register({}), TypeError);
});
