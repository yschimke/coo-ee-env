// Unit tests for the pure recommender. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { recommend } = require("../api/env/recommend");
const { render } = require("../api/env/render");

const specs = (seg) => recommend(seg).recommendations.map((r) => r.spec);

// The core guarantee: nothing the service suggests can be uninstallable. Every
// recommendation spec, and the merged "next" path, must render (status 200).
test("every recommendation and the merged next path render", () => {
  const sels = [
    "", "java", "android", "android-emulator", "node", "python", "go", "rust",
    "ruby", "java,android", "node,python", "node,skills",
    "java,tools[ripgrep,gradle]",
  ];
  for (const s of sels) {
    const out = recommend(s);
    for (const r of out.recommendations) {
      assert.equal(render(r.spec).status, 200, `spec ${r.spec} (from ${s}) should render`);
    }
    assert.equal(render(out.next).status, 200, `next ${out.next} (from ${s}) should render`);
  }
});

test("a bare selection suggests the universal kit and agent skills", () => {
  const s = specs("");
  assert.ok(s.includes("skills"), "should suggest skills");
  assert.ok(s.some((x) => x.startsWith("tools[")), "should suggest the CLI kit");
});

test("java leads with android; android leads with java (its prerequisite)", () => {
  assert.equal(recommend("java").recommendations[0].spec, "android");
  assert.equal(recommend("android").recommendations[0].spec, "java");
});

test("a tool is suggested once, in its strongest bundle (no double-suggest)", () => {
  // `gh` is in both the baseline kit (weight 1) and the skills rule (weight 2);
  // with skills selected it belongs to the skills bundle, not the kit.
  const recs = recommend("node,skills").recommendations.filter((r) => r.kind === "tools");
  const withGh = recs.filter((r) => r.spec.includes("gh"));
  assert.equal(withGh.length, 1, "gh should appear in exactly one bundle");
  assert.ok(withGh[0].reasons[0].includes("GitHub CLI"));
});

test("tools already requested are not suggested again", () => {
  for (const spec of specs("java,tools[ripgrep,gradle]")) {
    assert.ok(!/(^|\[|,)ripgrep(,|\]|$)/.test(spec), `ripgrep already present: ${spec}`);
    assert.ok(!/(^|\[|,)gradle(,|\]|$)/.test(spec), `gradle already present: ${spec}`);
  }
});

test("already-selected modules are never re-recommended", () => {
  const out = recommend("java,android,node,python,go,rust");
  for (const r of out.recommendations.filter((x) => x.kind === "module")) {
    assert.ok(!out.selected.includes(r.spec), `${r.spec} already selected`);
  }
});

test("ruby and android-emulator participate in the catalog", () => {
  assert.ok(specs("ruby").some((x) => x.includes("rubocop")), "ruby suggests rubocop");
  // android pulls in the emulator suggestion alongside its java prerequisite.
  assert.ok(specs("android").includes("android-emulator"));
});
