// Tests for the Claude Code permission allowlist that setup writes into a
// project's .claude/settings.json. These exercise the *rendered* bash: they run
// the script's registration phase (everything up to the final `main "$@"`, which
// is neutralized) and then evaluate a snippet against the loaded functions and
// state — so the per-module `provides_perms` declarations and the settings
// writer are checked end to end. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

// Load the rendered script's registrations, then run `snippet` with the
// module registry populated. `main "$@"` is replaced by `:` so nothing installs.
function evalRendered(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-perms-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

const perms = (seg) => JSON.parse(evalRendered(seg, "cooee_perms_json"));

test("java pre-approves the JVM build toolchain", () => {
  const p = perms("java");
  for (const rule of ["Bash(./gradlew:*)", "Bash(gradle:*)", "Bash(java:*)"]) {
    assert.ok(p.includes(rule), `expected ${rule}`);
  }
});

test("each toolchain module contributes its own runner", () => {
  assert.ok(perms("node").includes("Bash(npm:*)"));
  assert.ok(perms("python").includes("Bash(pytest:*)"));
  assert.ok(perms("go").includes("Bash(go:*)"));
  assert.ok(perms("rust").includes("Bash(cargo:*)"));
  assert.ok(perms("ruby").includes("Bash(bundle:*)"));
  assert.ok(perms("android").includes("Bash(adb:*)"));
});

test("rules are deduped and sorted, and combine across the module set", () => {
  const p = perms("java,node");
  assert.deepEqual([...p].sort(), p, "rules come out sorted");
  assert.equal(new Set(p).size, p.length, "no duplicates");
  assert.ok(p.includes("Bash(gradle:*)") && p.includes("Bash(node:*)"));
});

test("tools[...] contributes a permission per installed binary (ripgrep -> rg)", () => {
  // The binary name is what gets allowlisted, not the nixpkgs attribute:
  // ripgrep installs `rg`, nodePackages.prettier installs `prettier`.
  assert.deepEqual(perms("tools[ripgrep,jq,nodePackages.prettier]"), [
    "Bash(jq:*)",
    "Bash(prettier:*)",
    "Bash(rg:*)",
  ]);
});

test("a module set with no runners yields an empty allowlist (no failure)", () => {
  assert.deepEqual(perms("skills"), []);
});

test("setup writes the hook AND a permissions allowlist to the global ~/.claude/settings.json", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-home-"));
  evalRendered("java,node", "cooee_install_session_hook >/dev/null 2>&1", {
    HOME: home,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  const s = JSON.parse(
    fs.readFileSync(path.join(home, ".claude", "settings.json"), "utf8"),
  );
  assert.equal(s.hooks.SessionStart.length, 1, "SessionStart hook is present");
  assert.ok(s.permissions.allow.includes("Bash(gradle:*)"));
  assert.ok(s.permissions.allow.includes("Bash(node:*)"));
});

test("setup writes ONLY to the global config, never into any project checkout", () => {
  // The classic cloud layout: repos checked out side by side under a workspace
  // root, each with its own git-tracked .claude/settings.json. The hook install
  // must leave every checkout's tree pristine — writing into them would dirty a
  // committed file — and put everything in the environment's global config.
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-home-"));
  const root = path.join(home, "workspace");
  const a = path.join(root, "repo-a");
  const b = path.join(root, "repo-b");
  for (const p of [a, b]) fs.mkdirSync(path.join(p, ".git"), { recursive: true });
  evalRendered("java,node", "cooee_install_session_hook >/dev/null 2>&1", {
    HOME: home,
    CLAUDE_PROJECT_DIR: a,
    COOEE_CHECKOUTS_DIR: root,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  // Global config got the hook + perms...
  const g = JSON.parse(
    fs.readFileSync(path.join(home, ".claude", "settings.json"), "utf8"),
  );
  assert.equal(g.hooks.SessionStart.length, 1, "global: SessionStart hook present");
  assert.ok(g.permissions.allow.includes("Bash(gradle:*)"), "global: gradle perm");
  assert.ok(g.permissions.allow.includes("Bash(node:*)"), "global: node perm");
  // ...and neither checkout was touched.
  for (const p of [a, b]) {
    assert.ok(
      !fs.existsSync(path.join(p, ".claude")),
      `${p}: no .claude dir created in the checkout`,
    );
  }
});

test("CLAUDE_CONFIG_DIR overrides the target global config location", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-home-"));
  const cfg = path.join(home, "custom-claude");
  evalRendered("java", "cooee_install_session_hook >/dev/null 2>&1", {
    HOME: home,
    CLAUDE_CONFIG_DIR: cfg,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  const s = JSON.parse(fs.readFileSync(path.join(cfg, "settings.json"), "utf8"));
  assert.equal(s.hooks.SessionStart.length, 1, "hook written to CLAUDE_CONFIG_DIR");
  assert.ok(s.permissions.allow.includes("Bash(gradle:*)"));
  // The default ~/.claude was NOT used.
  assert.ok(
    !fs.existsSync(path.join(home, ".claude", "settings.json")),
    "default ~/.claude not written when CLAUDE_CONFIG_DIR is set",
  );
});

test("setup preserves existing global settings and unions permissions, without duplicating the hook", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-home-"));
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  const file = path.join(home, ".claude", "settings.json");
  fs.writeFileSync(
    file,
    JSON.stringify({ model: "opus", permissions: { allow: ["Bash(git:*)"] } }),
  );
  const env = { HOME: home, COOEE_BASE_URL: "https://env.coo.ee" };
  // Run twice: the second run must be a no-op (idempotent).
  evalRendered("java", "cooee_install_session_hook >/dev/null 2>&1", env);
  evalRendered("java", "cooee_install_session_hook >/dev/null 2>&1", env);
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  assert.equal(s.model, "opus", "unrelated keys are preserved");
  assert.equal(s.hooks.SessionStart.length, 1, "hook added exactly once");
  assert.ok(s.permissions.allow.includes("Bash(git:*)"), "pre-existing rule kept");
  assert.ok(s.permissions.allow.includes("Bash(gradle:*)"), "new rules merged");
  assert.equal(
    new Set(s.permissions.allow).size,
    s.permissions.allow.length,
    "merged allowlist has no duplicates",
  );
});
