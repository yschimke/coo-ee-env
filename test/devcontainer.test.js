// Unit tests for the devcontainer renderer (option A). Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { render } = require("../api/env/render");
const {
  renderDevcontainer,
  BASE_IMAGES,
  CLAUDE_CODE_FEATURE,
} = require("../api/env/devcontainer");

// json mode: parse the rendered devcontainer.json the way a consumer would.
const dc = (seg, opts) => {
  const out = renderDevcontainer(seg, Object.assign({ mode: "json" }, opts));
  return { out, json: JSON.parse(out.body) };
};

test("json mode emits valid devcontainer.json with a mainstream base image", () => {
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

// ---- apply mode (the default: a script you pipe to bash) -------------------

test("apply mode is the default and emits a shell script", () => {
  const out = renderDevcontainer("java,android");
  assert.equal(out.status, 200);
  assert.match(out.contentType, /text\/x-shellscript/);
  assert.ok(out.body.startsWith("#!/usr/bin/env bash"), "has a shebang");
});

test("the apply script writes .devcontainer/devcontainer.json safely", () => {
  const out = renderDevcontainer("node");
  // Targets the repo root (or $PWD), guarded by COOEE_FORCE, and writes the file.
  assert.ok(out.body.includes("git rev-parse --show-toplevel"), "finds the repo root");
  assert.ok(out.body.includes("COOEE_DEVCONTAINER_DIR"), "destination is overridable");
  assert.ok(out.body.includes('COOEE_FORCE:-0'), "refuses to clobber without force");
  assert.ok(out.body.includes('cat > "$file"'), "writes devcontainer.json");
  // The embedded JSON is exactly the json-mode body, dropped in via a quoted
  // heredoc so its contents are never shell-expanded.
  const json = renderDevcontainer("node", { mode: "json" }).body;
  assert.ok(out.body.includes("<<'COOEE_DEVCONTAINER_JSON'"), "quoted heredoc");
  assert.ok(out.body.includes(json), "embeds the json-mode body verbatim");
});

test("user input can't inject shell into the apply script", () => {
  // Bad params are rejected (400) before any script is produced, so the
  // injection attempt never reaches the heredoc.
  const out = renderDevcontainer("java[$(touch pwned)]");
  assert.equal(out.status, 400);
  assert.ok(!out.body.includes("touch pwned") || out.contentType.includes("json"));
});

test("unknown modules return 400 JSON with the available list", () => {
  const out = renderDevcontainer("nope");
  assert.equal(out.status, 400);
  assert.match(out.contentType, /application\/json/);
  const json = JSON.parse(out.body);
  assert.match(json.error, /unknown module/);
  assert.ok(Array.isArray(json.available) && json.available.includes("java"));
});

test("malformed/invalid tokens return 400 (mirrors render)", () => {
  for (const seg of ["java[17;rm]", "java[$(x)]"]) {
    assert.equal(renderDevcontainer(seg).status, 400, `expected 400 for ${seg}`);
  }
});
