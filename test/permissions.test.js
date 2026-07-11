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

test("setup writes the hook AND a permissions allowlist to a fresh settings.json", () => {
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-proj-"));
  fs.mkdirSync(path.join(proj, ".git"));
  evalRendered("java,node", "cooee_install_session_hook >/dev/null 2>&1", {
    CLAUDE_PROJECT_DIR: proj,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  const s = JSON.parse(
    fs.readFileSync(path.join(proj, ".claude", "settings.json"), "utf8"),
  );
  assert.equal(s.hooks.SessionStart.length, 1, "SessionStart hook is present");
  assert.ok(s.permissions.allow.includes("Bash(gradle:*)"));
  assert.ok(s.permissions.allow.includes("Bash(node:*)"));
});

test("setup writes the hook + permissions into every sibling checkout, not just CLAUDE_PROJECT_DIR", () => {
  // Two repos checked out side by side under a workspace root, the classic
  // cloud layout. CLAUDE_PROJECT_DIR points at one; the other must still get
  // provisioned, or a session that opens it re-prompts for the toolchain.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-ws-"));
  const a = path.join(root, "repo-a");
  const b = path.join(root, "repo-b");
  for (const p of [a, b]) fs.mkdirSync(path.join(p, ".git"), { recursive: true });
  evalRendered("java,node", "cooee_install_session_hook >/dev/null 2>&1", {
    CLAUDE_PROJECT_DIR: a,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  for (const p of [a, b]) {
    const s = JSON.parse(
      fs.readFileSync(path.join(p, ".claude", "settings.json"), "utf8"),
    );
    assert.equal(s.hooks.SessionStart.length, 1, `${p}: SessionStart hook present`);
    assert.ok(s.permissions.allow.includes("Bash(gradle:*)"), `${p}: gradle perm`);
    assert.ok(s.permissions.allow.includes("Bash(node:*)"), `${p}: node perm`);
  }
});

test("each sibling checkout merges with its OWN existing settings, without cross-contaminating", () => {
  // repo-a and repo-b each declare their own project-specific permission. The
  // coo.ee setup must union its rules into each without leaking a's rule into b.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-ws-"));
  const a = path.join(root, "repo-a");
  const b = path.join(root, "repo-b");
  for (const p of [a, b]) fs.mkdirSync(path.join(p, ".claude"), { recursive: true });
  fs.writeFileSync(
    path.join(a, ".claude", "settings.json"),
    JSON.stringify({ model: "opus", permissions: { allow: ["Bash(only-a:*)"] } }),
  );
  fs.writeFileSync(
    path.join(b, ".claude", "settings.json"),
    JSON.stringify({ permissions: { allow: ["Bash(only-b:*)"] } }),
  );
  // a is not a git repo here, so drive discovery from the workspace root.
  evalRendered("java", "cooee_install_session_hook >/dev/null 2>&1", {
    COOEE_CHECKOUTS_DIR: root,
    CLAUDE_PROJECT_DIR: a,
    COOEE_BASE_URL: "https://env.coo.ee",
  });
  const sa = JSON.parse(fs.readFileSync(path.join(a, ".claude", "settings.json"), "utf8"));
  const sb = JSON.parse(fs.readFileSync(path.join(b, ".claude", "settings.json"), "utf8"));
  assert.equal(sa.model, "opus", "a's unrelated keys preserved");
  assert.ok(sa.permissions.allow.includes("Bash(only-a:*)"), "a keeps its own rule");
  assert.ok(sa.permissions.allow.includes("Bash(gradle:*)"), "a gets the coo.ee rule");
  assert.ok(!sa.permissions.allow.includes("Bash(only-b:*)"), "b's rule does not leak into a");
  assert.ok(sb.permissions.allow.includes("Bash(only-b:*)"), "b keeps its own rule");
  assert.ok(sb.permissions.allow.includes("Bash(gradle:*)"), "b gets the coo.ee rule");
  assert.ok(!sb.permissions.allow.includes("Bash(only-a:*)"), "a's rule does not leak into b");
});

test("setup preserves existing settings and unions permissions, without duplicating the hook", () => {
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-proj-"));
  fs.mkdirSync(path.join(proj, ".claude"), { recursive: true });
  const file = path.join(proj, ".claude", "settings.json");
  fs.writeFileSync(
    file,
    JSON.stringify({ model: "opus", permissions: { allow: ["Bash(git:*)"] } }),
  );
  const env = { CLAUDE_PROJECT_DIR: proj, COOEE_BASE_URL: "https://env.coo.ee" };
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
