// Tests for the `dotfiles[owner/repo]` module: coordinate handling, the three
// apply strategies, and the safety rules around each. Clones are not exercised
// (no network in the test env) — the module's apply half is driven directly
// against a fixture directory, which is where all the interesting behaviour is.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("dotfiles").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-df-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

/**
 * Same, but with stderr folded in — log/ok/warn all write there, so any test
 * asserting on what the module *said* needs this rather than plain run().
 */
function runSaid(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-df-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

/** A dotfiles repo with plain top-level dotfiles (the symlink case). */
function flatRepo() {
  const dir = scratch("repo");
  fs.writeFileSync(path.join(dir, ".vimrc"), "set nocompatible\n");
  fs.mkdirSync(path.join(dir, ".config"));
  fs.writeFileSync(path.join(dir, ".config", "starship.toml"), "");
  fs.mkdirSync(path.join(dir, ".git"));
  fs.writeFileSync(path.join(dir, ".gitignore"), "*.swp\n");
  fs.writeFileSync(path.join(dir, "README.md"), "# dotfiles\n");
  return dir;
}

/** A stow-style package tree: no top-level dotfiles, one dir per package. */
function stowRepo() {
  const dir = scratch("repo");
  fs.mkdirSync(path.join(dir, "vim"));
  fs.writeFileSync(path.join(dir, "vim", ".vimrc"), "set nocompatible\n");
  fs.mkdirSync(path.join(dir, ".git"));
  return dir;
}

test("top-level dotfiles are linked into $HOME; repo metadata is not", () => {
  const repo = flatRepo();
  const home = scratch("home");
  const out = run(`
    HOME="${home}"
    cooee_dotfiles_symlink "${repo}"
  `);
  assert.equal(out, "2"); // .vimrc + .config
  assert.equal(fs.readlinkSync(path.join(home, ".vimrc")), path.join(repo, ".vimrc"));
  assert.equal(fs.readlinkSync(path.join(home, ".config")), path.join(repo, ".config"));
  for (const skipped of [".git", ".gitignore", "README.md"]) {
    assert.ok(!fs.existsSync(path.join(home, skipped)), `${skipped} should not be linked`);
  }
});

test("an existing file is backed up, not clobbered", () => {
  const repo = flatRepo();
  const home = scratch("home");
  fs.writeFileSync(path.join(home, ".vimrc"), "MINE\n");
  run(`
    HOME="${home}"
    cooee_dotfiles_symlink "${repo}" >/dev/null
  `);
  assert.equal(fs.readFileSync(path.join(home, ".vimrc.cooee.bak"), "utf8"), "MINE\n");
  assert.equal(fs.readlinkSync(path.join(home, ".vimrc")), path.join(repo, ".vimrc"));
});

test("re-running does not stack backups of our own symlinks", () => {
  const repo = flatRepo();
  const home = scratch("home");
  fs.writeFileSync(path.join(home, ".vimrc"), "MINE\n");
  const twice = `
    HOME="${home}"
    cooee_dotfiles_symlink "${repo}" >/dev/null
    cooee_dotfiles_symlink "${repo}" >/dev/null
    ls -a "${home}" | grep -c cooee.bak
  `;
  assert.equal(run(twice), "1");
  // The user's original content is still the thing in the backup.
  assert.equal(fs.readFileSync(path.join(home, ".vimrc.cooee.bak"), "utf8"), "MINE\n");
});

test("a pre-existing backup is never overwritten", () => {
  const repo = flatRepo();
  const home = scratch("home");
  fs.writeFileSync(path.join(home, ".vimrc.cooee.bak"), "ORIGINAL\n");
  fs.writeFileSync(path.join(home, ".vimrc"), "SECOND\n");
  run(`
    HOME="${home}"
    cooee_dotfiles_symlink "${repo}" >/dev/null
  `);
  assert.equal(fs.readFileSync(path.join(home, ".vimrc.cooee.bak"), "utf8"), "ORIGINAL\n");
});

test("stow layouts are recognised, flat ones are not", () => {
  const flat = flatRepo();
  const stow = stowRepo();
  const out = run(`
    cooee_dotfiles_looks_stowable "${stow}" && echo stow-yes || echo stow-no
    cooee_dotfiles_looks_stowable "${flat}" && echo flat-yes || echo flat-no
  `);
  assert.equal(out, "stow-yes\nflat-no");
});

test("an install script is detected but NOT run by default", () => {
  const repo = flatRepo();
  const marker = path.join(repo, "ran");
  fs.writeFileSync(path.join(repo, "install.sh"), `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
  const home = scratch("home");
  const out = runSaid(`
    HOME="${home}"
    cooee_dotfiles_apply "${repo}" owner/repo
  `);
  assert.ok(!fs.existsSync(marker), "install.sh must not run without the opt-in");
  assert.ok(out.includes("COOEE_DOTFILES_RUN_INSTALL=1"), "should say how to opt in");
  // …and it still applied, via linking.
  assert.ok(fs.existsSync(path.join(home, ".vimrc")));
});

test("COOEE_DOTFILES_RUN_INSTALL=1 runs the install script", () => {
  const repo = flatRepo();
  const marker = path.join(repo, "ran");
  fs.writeFileSync(path.join(repo, "install.sh"), `#!/bin/sh\ntouch "${marker}"\n`, { mode: 0o755 });
  const home = scratch("home");
  run(`
    HOME="${home}"
    COOEE_DOTFILES_RUN_INSTALL=1
    cooee_dotfiles_apply "${repo}" owner/repo
  `);
  assert.ok(fs.existsSync(marker), "install.sh should have run");
});

test("a failing install script falls back to linking", () => {
  const repo = flatRepo();
  fs.writeFileSync(path.join(repo, "install.sh"), "#!/bin/sh\nexit 3\n", { mode: 0o755 });
  const home = scratch("home");
  const out = runSaid(`
    HOME="${home}"
    COOEE_DOTFILES_RUN_INSTALL=1
    cooee_dotfiles_apply "${repo}" owner/repo
  `);
  assert.ok(out.includes("falling back to linking"));
  assert.ok(fs.existsSync(path.join(home, ".vimrc")));
});

test("a non-executable install.sh is ignored", () => {
  const repo = flatRepo();
  fs.writeFileSync(path.join(repo, "install.sh"), "#!/bin/sh\nexit 3\n", { mode: 0o644 });
  const out = run(`cooee_dotfiles_installer "${repo}" && echo found || echo none`);
  assert.equal(out, "none");
});

test("bare `dotfiles` warns instead of guessing a repo", () => {
  const out = runSaid(`module_dotfiles`);
  assert.ok(out.includes("no repo given"));
  assert.ok(out.includes("dotfiles[owner/repo]"));
});

test("malformed coordinates are skipped, not fatal", () => {
  const out = runSaid(`
    HOME="${scratch("home")}"
    module_dotfiles notaslug owner/repo/extra || echo "exit=$?"
  `);
  assert.ok(out.includes("skipping 'notaslug'"));
  assert.ok(out.includes("skipping 'owner/repo/extra'"));
  assert.ok(!out.includes("exit="), "a bad coordinate must not fail the run");
});

test("the module renders and is discoverable by the picker", () => {
  const info = render("dotfiles").info || [];
  const entry = require("../api/env/render").moduleInfo().find((m) => m.name === "dotfiles");
  assert.ok(entry, "dotfiles should appear in moduleInfo");
  assert.match(entry.params, /owner\/repo/);
  assert.deepEqual(
    entry.hosts.need.map((h) => h.host),
    ["github.com"],
  );
  assert.equal(entry.hidden, false);
  void info;
});
