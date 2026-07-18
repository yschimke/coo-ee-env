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
    // Default the checkout-perms scan OFF so toolchain assertions stay hermetic
    // regardless of what repos happen to be checked out next to this one. Tests
    // that exercise the merge opt back in with COOEE_NO_CHECKOUT_PERMS: "0".
    env: { ...process.env, COOEE_NO_CHECKOUT_PERMS: "1", ...env },
  }).trim();
}

const perms = (seg, env = {}) => JSON.parse(evalRendered(seg, "cooee_perms_json", env));

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
  // ripgrep installs `rg`, nodePackages.prettier installs `prettier`. (base
  // also contributes its environment-wide MCP defaults; scope this to the
  // Bash toolchain rules the `tools` module is responsible for.)
  const bash = perms("tools[ripgrep,jq,nodePackages.prettier]").filter((r) =>
    r.startsWith("Bash("),
  );
  assert.deepEqual(bash, ["Bash(jq:*)", "Bash(prettier:*)", "Bash(rg:*)"]);
});

test("a module set with no toolchain runners still carries the base environment defaults", () => {
  const p = perms("skills");
  assert.equal(
    p.filter((r) => r.startsWith("Bash(")).length,
    0,
    "no toolchain runner rules for a runner-less set",
  );
  assert.ok(
    p.includes("mcp__Claude_Code_Remote__send_later"),
    "base MCP defaults are always present",
  );
});

test("base pre-approves the harness scheduling + GitHub collaboration tools", () => {
  const p = perms("skills"); // base is the implicit preamble of every request
  for (const rule of [
    "mcp__Claude_Code_Remote__send_later",
    "mcp__Claude_Code_Remote__create_trigger",
    "mcp__claude-code-remote__create_trigger", // hyphenated server spelling too
    "mcp__github__create_pull_request",
    "mcp__github__subscribe_pr_activity",
    "mcp__github__unsubscribe_pr_activity",
    "mcp__github__get_job_logs",
    "mcp__github__get_check_run",
  ]) {
    assert.ok(p.includes(rule), `expected ${rule}`);
  }
});

test("permissions from side-by-side project checkouts are merged in", () => {
  // A workspace with a sibling repo that pre-approves its own tools. Those
  // rules must surface in the global allowlist even though the repo isn't the
  // session's own project dir.
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-ws-"));
  const repo = path.join(root, "repo-a");
  fs.mkdirSync(path.join(repo, ".claude"), { recursive: true });
  fs.writeFileSync(
    path.join(repo, ".claude", "settings.json"),
    JSON.stringify({
      permissions: { allow: ["Bash(flutter:*)", "mcp__github__merge_pull_request"] },
    }),
  );
  const p = perms("java", {
    COOEE_NO_CHECKOUT_PERMS: "0",
    COOEE_CHECKOUTS_DIR: root,
    CLAUDE_PROJECT_DIR: repo,
  });
  assert.ok(p.includes("Bash(flutter:*)"), "checkout Bash rule merged");
  assert.ok(p.includes("mcp__github__merge_pull_request"), "checkout MCP rule merged");
  assert.ok(p.includes("Bash(gradle:*)"), "module toolchain rules still present");
  assert.ok(
    p.includes("mcp__Claude_Code_Remote__send_later"),
    "base defaults still present",
  );
});

test("checkout permission merge is opt-out via COOEE_NO_CHECKOUT_PERMS", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-ws-"));
  const repo = path.join(root, "repo-a");
  fs.mkdirSync(path.join(repo, ".claude"), { recursive: true });
  fs.writeFileSync(
    path.join(repo, ".claude", "settings.json"),
    JSON.stringify({ permissions: { allow: ["Bash(flutter:*)"] } }),
  );
  const p = perms("java", {
    COOEE_NO_CHECKOUT_PERMS: "1",
    COOEE_CHECKOUTS_DIR: root,
    CLAUDE_PROJECT_DIR: repo,
  });
  assert.ok(!p.includes("Bash(flutter:*)"), "checkout rule not merged when opted out");
  assert.ok(p.includes("Bash(gradle:*)"), "module rules unaffected by opt-out");
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
