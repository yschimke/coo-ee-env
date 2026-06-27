// Unit tests for the devcontainer renderer (option A). Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { render } = require("../api/env/render");
const {
  renderDevcontainer,
  BASE_IMAGES,
  CLAUDE_CODE_FEATURE,
} = require("../api/env/devcontainer");

// Parse the rendered body the way a consumer (VS Code, the devcontainer CLI)
// would: it must be valid JSON.
const dc = (seg, opts) => {
  const out = renderDevcontainer(seg, opts);
  return { out, json: JSON.parse(out.body) };
};

test("emits valid devcontainer.json with a mainstream base image", () => {
  const { out, json } = dc("java,android");
  assert.equal(out.status, 200);
  assert.match(out.contentType, /application\/json/);
  assert.equal(json.image, BASE_IMAGES.ubuntu);
  // The Claude Code Feature is layered on so the CLI is present in-container.
  assert.ok(Object.keys(json.features).includes(CLAUDE_CODE_FEATURE));
});

test("postCreateCommand reuses the curl one-liner over the canonical list", () => {
  const { json } = dc("java,android");
  // Canonical (minus the implicit base) — android pulls in android-cli — so the
  // one-liner shares the cache key the shell endpoint emits.
  assert.equal(
    json.postCreateCommand,
    "curl -fsSL https://env.coo.ee/android,android-cli,java | bash",
  );
});

test("?base=codex selects the codex-universal base image", () => {
  assert.equal(dc("node", { base: "codex" }).json.image, BASE_IMAGES.codex);
  // Anything else falls back to the neutral default.
  assert.equal(dc("node", { base: "wat" }).json.image, BASE_IMAGES.ubuntu);
  assert.equal(dc("node").json.image, BASE_IMAGES.ubuntu);
});

test("devenv rides along into the one-liner", () => {
  assert.ok(dc("java", { devenv: true }).json.postCreateCommand.endsWith("/java?devenv | bash"));
  assert.ok(dc("java").json.postCreateCommand.endsWith("/java | bash"));
});

test("the firewall allowlist is computed from module need/want hosts", () => {
  const { out, json } = dc("android"); // base + android + android-cli
  const domains = out.allowedDomains;
  // base installs Nix; android pulls Google's SDK + CLI binary.
  for (const h of ["cache.nixos.org", "github.com", "dl.google.com", "maven.google.com"]) {
    assert.ok(domains.includes(h), `expected ${h} in allowlist`);
  }
  // Sorted + deduped, and mirrored into containerEnv for the host's policy.
  assert.deepEqual(domains, [...new Set(domains)].sort());
  assert.equal(json.containerEnv.COOEE_ALLOWED_DOMAINS, domains.join(","));
});

test("canonical form matches the shell renderer (shared cache key)", () => {
  assert.deepEqual(
    renderDevcontainer("android,java").canonical,
    render("java,android").canonical,
  );
});

test("unknown modules return 400 JSON with the available list", () => {
  const { out, json } = dc("nope");
  assert.equal(out.status, 400);
  assert.match(out.contentType, /application\/json/);
  assert.match(json.error, /unknown module/);
  assert.ok(Array.isArray(json.available) && json.available.includes("java"));
});

test("malformed/invalid tokens return 400 (mirrors render)", () => {
  for (const seg of ["java[17;rm]", "java[$(x)]"]) {
    assert.equal(renderDevcontainer(seg).status, 400, `expected 400 for ${seg}`);
  }
});
