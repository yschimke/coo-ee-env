// Tests for the `git-identity` module: COOEE_GIT_* wins, the GitHub account is
// the default (with the noreply fallback for a private email), and a failed
// lookup leaves the existing config alone. `gh` is a stub on PATH — no network.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("git-identity").body.replace(/^main "\$@"$/m, ":");

/** A scratch $HOME whose .gitconfig carries the harness's agent identity. */
function agentHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gi-home-"));
  fs.writeFileSync(
    path.join(home, ".gitconfig"),
    "[user]\n\tname = Claude\n\temail = noreply@anthropic.com\n",
  );
  return home;
}

/** A PATH dir holding a `gh` stub that prints <tsv> for `gh api user --jq`. */
function ghStub(tsv, exitCode = 0) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gi-bin-"));
  const gh = path.join(dir, "gh");
  fs.writeFileSync(gh, `#!/bin/sh\nprintf '%s\\n' '${tsv}'\nexit ${exitCode}\n`);
  fs.chmodSync(gh, 0o755);
  return dir;
}

function run(home, env = {}, binDir) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gi-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\ncooee_git_identity_apply\n`);
  const base = { ...process.env };
  for (const k of Object.keys(base)) {
    if (/^(GIT_|COOEE_GIT_)/.test(k)) delete base[k];
  }
  const said = execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: {
      ...base,
      HOME: home,
      XDG_CONFIG_HOME: path.join(home, ".config"),
      PATH: `${binDir || fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gi-empty-"))}:${process.env.PATH}`,
      ...env,
    },
  });
  const cfg = (key) =>
    execFileSync("git", ["config", "--file", path.join(home, ".gitconfig"), key], {
      encoding: "utf8",
    }).trim();
  return { said, name: cfg("user.name"), email: cfg("user.email") };
}

test("COOEE_GIT_NAME/EMAIL replace the agent identity", () => {
  const home = agentHome();
  const r = run(home, { COOEE_GIT_NAME: "Ada Lovelace", COOEE_GIT_EMAIL: "ada@example.com" },
    ghStub("Someone Else\tother@example.com"));
  assert.equal(r.name, "Ada Lovelace");
  assert.equal(r.email, "ada@example.com");
  assert.match(r.said, /COOEE_GIT_NAME\/COOEE_GIT_EMAIL/);
});

test("defaults to the GitHub account gh is authenticated as", () => {
  const home = agentHome();
  const r = run(home, {}, ghStub("Ada Lovelace\tada@example.com"));
  assert.equal(r.name, "Ada Lovelace");
  assert.equal(r.email, "ada@example.com");
});

test("one override field combines with the account for the other", () => {
  const home = agentHome();
  const r = run(home, { COOEE_GIT_EMAIL: "work@example.com" }, ghStub("Ada Lovelace\tada@example.com"));
  assert.equal(r.name, "Ada Lovelace");
  assert.equal(r.email, "work@example.com");
});

test("a failed lookup leaves the existing identity alone and says so", () => {
  const home = agentHome();
  const r = run(home, {}, ghStub("", 1));
  assert.equal(r.name, "Claude");
  assert.equal(r.email, "noreply@anthropic.com");
  assert.match(r.said, /set COOEE_GIT_NAME and COOEE_GIT_EMAIL/);
});

test("re-running with the same identity is a no-op", () => {
  const home = agentHome();
  const env = { COOEE_GIT_NAME: "Ada Lovelace", COOEE_GIT_EMAIL: "ada@example.com" };
  run(home, env);
  const r = run(home, env);
  assert.match(r.said, /already Ada Lovelace <ada@example.com>/);
});

test("the module never pulls in Nix and runs on the fast path", () => {
  assert.match(BODY, /cooee_present_git-identity\(\) \{ return 0; \}/);
  assert.match(BODY, /declare -F cooee_git_identity_apply/);
});
