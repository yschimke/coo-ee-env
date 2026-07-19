// Tests for cooee_forward_to_harness upserting (rather than blindly appending)
// KEY=value lines into the host harness env files ($CLAUDE_ENV_FILE /
// $GITHUB_ENV). Claude Code re-runs the whole bootstrap on every SessionStart
// (including resume and compact) and inlines $CLAUDE_ENV_FILE into the preamble
// of every Bash call, so a naive `>>` grows the file — and every spawned
// command string — without bound until it trips the argv limit (E2BIG). Load
// the rendered base module (neutralizing `main "$@"`) and drive the forwarder
// directly. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-he-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

test("re-forwarding the same key does not duplicate lines (re-fire safe)", () => {
  const out = run(`
    export CLAUDE_ENV_FILE="$(mktemp)"
    cooee_forward_to_harness "FOO=bar"
    cooee_forward_to_harness "FOO=bar"
    cooee_forward_to_harness "FOO=bar"
    cat "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "FOO=bar");
});

test("a changed value replaces the prior line rather than stacking", () => {
  const out = run(`
    export CLAUDE_ENV_FILE="$(mktemp)"
    cooee_forward_to_harness "FOO=old"
    cooee_forward_to_harness "FOO=new"
    cat "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "FOO=new");
});

test("lines owned by other harness hooks are preserved", () => {
  const out = run(`
    export CLAUDE_ENV_FILE="$(mktemp)"
    printf 'OTHER=keepme\\n' > "$CLAUDE_ENV_FILE"
    cooee_forward_to_harness "FOO=bar"
    cooee_forward_to_harness "FOO=bar"
    cat "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "OTHER=keepme\nFOO=bar");
});

test("collapses a file already bloated by the old append behaviour", () => {
  const out = run(`
    export CLAUDE_ENV_FILE="$(mktemp)"
    for i in $(seq 1 200); do printf 'FOO=bar\\n' >> "$CLAUDE_ENV_FILE"; done
    cooee_forward_to_harness "FOO=bar"
    grep -c '^FOO=' "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "1");
});

test("no harness env files present is a safe no-op", () => {
  const out = run(`
    unset CLAUDE_ENV_FILE GITHUB_ENV
    cooee_forward_to_harness "FOO=bar"
    echo OK
  `);
  assert.equal(out, "OK");
});

test("GitHub Actions' $GITHUB_ENV gets the same idempotent treatment", () => {
  const out = run(`
    unset CLAUDE_ENV_FILE
    export GITHUB_ENV="$(mktemp)"
    cooee_forward_to_harness "FOO=bar"
    cooee_forward_to_harness "FOO=bar"
    cat "$GITHUB_ENV"
  `);
  assert.equal(out, "FOO=bar");
});

test("add_env forwards idempotently end-to-end", () => {
  const out = run(`
    export COOEE_PROFILE="$(mktemp)"
    export COOEE_HARNESS_ENV="$(mktemp)"
    export CLAUDE_ENV_FILE="$(mktemp)"
    add_env FOO bar
    add_env FOO bar
    cat "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "FOO=bar");
});
