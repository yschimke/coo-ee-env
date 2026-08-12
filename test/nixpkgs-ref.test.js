// Tests for how modules choose — and report — the nixpkgs they build against.
//
// `builtins.getFlake "nixpkgs"` is a *rolling* ref. When it lands on a revision
// cache.nixos.org has not finished building, nothing substitutes and Nix
// compiles the closure from source; the visible symptom is `bash-5.3p15.drv`
// failing during an *Android SDK* provision, which has nothing to do with the
// SDK. Two things follow: the resolved revision has to be in the log (it is the
// one fact that makes such a report answerable), and there has to be a way to
// pin without editing the script.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

/** Run `snippet` against a rendered module body, with `nix` stubbed on PATH. */
function run(modules, snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-npkgs-"));
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(
    path.join(bin, "nix"),
    `#!/usr/bin/env bash
if [ "$1" = "flake" ] && [ "$2" = "metadata" ]; then
  [ -n "\${NIX_METADATA_FAILS:-}" ] && exit 1
  echo "Resolved URL:  github:NixOS/nixpkgs/nixpkgs-unstable"
  echo "Revision:      abc123def456"
  exit 0
fi
exit 0
`,
    { mode: 0o755 },
  );

  const body = render(modules).body.replace(/^main "\$@"$/m, ":");
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env, PATH: `${bin}:${process.env.PATH}` },
    stdio: ["ignore", "pipe", "pipe"],
  });
}

test("the default ref is the registry's rolling nixpkgs", () => {
    const out = run("base", 'cooee_nixpkgs_ref; echo');
    assert.equal(out.trim(), "nixpkgs");
});

test("COOEE_NIXPKGS_REF pins without a code change", () => {
    const out = run("base", 'cooee_nixpkgs_ref; echo', {
        COOEE_NIXPKGS_REF: "github:NixOS/nixpkgs/nixos-25.05",
    });
    assert.equal(out.trim(), "github:NixOS/nixpkgs/nixos-25.05");
});

test("the resolved revision is logged, once", () => {
    // Twice through, one line out: the note is per-run, not per-module.
    const out = run("base", "cooee_nixpkgs_note_revision 2>&1; cooee_nixpkgs_note_revision 2>&1");
    const lines = out.split("\n").filter((l) => l.includes("nixpkgs:"));
    assert.equal(lines.length, 1);
    assert.match(lines[0], /abc123def456/);
});

test("an unresolvable revision says so rather than failing the run", () => {
    const out = run("base", "cooee_nixpkgs_note_revision 2>&1", {
        NIX_METADATA_FAILS: "1",
    });
    assert.match(out, /revision could not be resolved/);
});

test("the failure hint names the ref and the override", () => {
    const out = run("base", "cooee_nixpkgs_hint; echo", {
        COOEE_NIXPKGS_REF: "github:NixOS/nixpkgs/nixos-25.05",
    });
    assert.match(out, /github:NixOS\/nixpkgs\/nixos-25\.05/);
    assert.match(out, /COOEE_NIXPKGS_REF=/);
    // The distinguishing symptom, so a reader can tell this case from a real
    // SDK/network problem without knowing Nix.
    assert.match(out, /source \*?build\*? of something unrelated/);
});

test("both nix-building modules go through the ref helper", () => {
    // A module that hardcodes `getFlake "nixpkgs"` silently opts out of the
    // override and the logging, which is exactly how this became unanswerable.
    for (const m of ["android", "compose"]) {
        const body = render(m).body;
        assert.ok(
            !/getFlake \\?"nixpkgs\\?"/.test(body),
            `${m} still hardcodes the nixpkgs ref`,
        );
    }
});

test("the android SDK failure quotes nix's own first error", () => {
    const body = render("android").body;
    assert.ok(body.includes("First error:"));
    assert.ok(body.includes("cooee_nixpkgs_hint"));
});
