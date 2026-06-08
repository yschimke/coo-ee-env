// Unit tests for the pure renderer. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { render, canonicalize } = require("../api/env/render");

const names = (seg) => canonicalize(seg).map((m) => m.name);
const canon = (seg) => render(seg).canonical;

test("base is always present and first", () => {
  assert.deepEqual(names(""), ["base"]);
  assert.deepEqual(names("java"), ["base", "java"]);
});

test("module order is canonicalized (cache-friendly)", () => {
  assert.equal(render("java,android").body, render("android,java").body);
  assert.deepEqual(canon("java,android"), ["base", "android", "java"]);
});

test("blanks and duplicate modules collapse", () => {
  assert.deepEqual(names(" java , , java "), ["base", "java"]);
});

test("version specifiers parse, sort, and dedupe", () => {
  assert.deepEqual(canon("java[21,17]"), ["base", "java[17,21]"]);
  assert.deepEqual(canon("java[17,17,21]"), ["base", "java[17,21]"]);
});

test("version order does not affect the rendered script", () => {
  assert.equal(render("java[21,17]").body, render("java[17,21]").body);
});

test("repeated modules merge their versions", () => {
  assert.deepEqual(canon("java[17],java[21,17]"), ["base", "java[17,21]"]);
});

test("numeric-aware version sort, with prefixed tokens last", () => {
  assert.deepEqual(canon("android[wear-33,9,37,30]"), [
    "base",
    "android[9,30,37,wear-33]",
  ]);
});

test("versions inject a COOEE_VERSIONS block; version-less stays clean", () => {
  const marker = "requested module versions (coo.ee/env)";
  assert.ok(render("java[17,21]").body.includes(marker));
  assert.ok(render("java[17,21]").body.includes('COOEE_VERSIONS[java]="17 21"'));
  assert.ok(!render("java,android").body.includes(marker));
});

test("malformed specs are rejected with 400", () => {
  for (const seg of ["java[", "java]", "java[]extra", "ja va", "java[17;rm]"]) {
    assert.equal(render(seg).status, 400, `expected 400 for ${JSON.stringify(seg)}`);
  }
});

test("shell metacharacters in versions never reach the body", () => {
  const o = render("java[17$(touch x)]");
  assert.equal(o.status, 400);
});

test("unknown modules return 400 with the available list", () => {
  const o = render("nope");
  assert.equal(o.status, 400);
  assert.match(o.body, /unknown module/);
  assert.match(o.body, /available:/);
});

test("the full example from the brief renders and is well-formed", () => {
  const o = render("java[17,21],android[30,37,wear-33]");
  assert.equal(o.status, 200);
  assert.deepEqual(o.canonical, [
    "base",
    "android[30,37,wear-33]",
    "java[17,21]",
  ]);
  assert.ok(o.body.includes('COOEE_VERSIONS[android]="30 37 wear-33"'));
  assert.ok(o.body.includes('COOEE_VERSIONS[java]="17 21"'));
});
