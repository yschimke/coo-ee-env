// Tests for the `ruby` module: which Ruby a project asks for, when an existing
// or rbenv-managed Ruby satisfies it, and the native-gem header step before
// `bundle install` — driven against stub `ruby`, rbenv and apt-get binaries (no
// network, no real Ruby needed).
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

// Source the rendered script (main neutralized), then run `snippet`; stderr is
// folded in because log/ok/warn write there.
function run(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = scratch("ruby");
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: dir,
      COOEE_PROFILE: path.join(dir, "env.sh"),
      COOEE_HARNESS_ENV: path.join(dir, "env.harness"),
      CLAUDE_ENV_FILE: "",
      ...env,
    },
  }).trim();
}

// A project dir with the given files.
function project(files) {
  const dir = scratch("ruby-proj");
  for (const [name, body] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), body);
  return dir;
}

// A fake `ruby` that reports <version> (only `-e 'print RUBY_VERSION'` matters).
function fakeRuby(dir, version) {
  fs.mkdirSync(dir, { recursive: true });
  const exe = path.join(dir, "ruby");
  fs.writeFileSync(exe, `#!/bin/sh\nprintf '%s' '${version}'\n`);
  fs.chmodSync(exe, 0o755);
  return dir;
}

test("the wanted Ruby: param, then .ruby-version, .tool-versions, the Gemfile", () => {
  const wanted = (proj, param = "") =>
    run("ruby", `cooee_ruby_wanted ${param}`, { CLAUDE_PROJECT_DIR: proj });
  assert.equal(wanted(project({ ".ruby-version": "ruby-3.2.6\n" })), "3.2.6");
  assert.equal(wanted(project({ ".ruby-version": "3.2.6\n" }), "3.4"), "3.4");
  assert.equal(wanted(project({ ".tool-versions": "nodejs 22.1.0\nruby 3.3.1\n" })), "3.3.1");
  assert.equal(wanted(project({ Gemfile: 'source "https://rubygems.org"\nruby "3.4.1"\ngem "rails"\n' })), "3.4.1");
  assert.equal(wanted(project({ Gemfile: "ruby file: \".ruby-version\"\n" })), "");
  assert.equal(wanted(project({})), "");
});

test("a Ruby satisfies the wanted version on major (and minor when given)", () => {
  const sat = (have, want) => run("ruby", `cooee_ruby_satisfies ${have} '${want}' && echo yes || echo no`);
  assert.equal(sat("3.3.6", ""), "yes");
  assert.equal(sat("3.3.6", "3"), "yes");
  assert.equal(sat("3.3.6", "3.3"), "yes");
  assert.equal(sat("3.3.6", "3.3.1"), "yes", "a patch difference is the same series");
  assert.equal(sat("3.3.6", "3.2.6"), "no");
  assert.equal(sat("3.3.6", "4"), "no");
});

test("an rbenv Ruby is matched exactly, else by series (newest)", () => {
  const root = scratch("rbenv");
  for (const v of ["3.1.6", "3.2.2", "3.2.6", "3.3.6"]) fakeRuby(path.join(root, "versions", v, "bin"), v);
  const match = (want) => run("ruby", `cooee_ruby_rbenv_match ${want} || echo none`, { RBENV_ROOT: root });
  assert.equal(match("3.2.2"), path.join(root, "versions", "3.2.2", "bin"));
  assert.equal(match("3.2.1"), path.join(root, "versions", "3.2.6", "bin"));
  assert.equal(match("3.4.1"), "none");
});

test("module_ruby selects the image's rbenv Ruby when PATH's is the wrong series", () => {
  const root = scratch("rbenv");
  fakeRuby(path.join(root, "versions", "3.2.6", "bin"), "3.2.6");
  const sys = fakeRuby(path.join(scratch("sys"), "bin"), "3.3.6");
  const proj = project({ ".ruby-version": "3.2.6\n" });
  const env = { RBENV_ROOT: root, CLAUDE_PROJECT_DIR: proj, COOEE_NO_DEPS: "1", PATH: `${sys}:${process.env.PATH}` };
  const out = run("ruby", 'cooee_present_ruby && echo PRESENT; module_ruby; echo "now: $(ruby)"', env);
  assert.match(out, /PRESENT/, "an rbenv match counts as present (no Nix, fast path holds)");
  assert.match(out, /selected rbenv's Ruby 3\.2\.6/);
  assert.match(out, /now: 3\.2\.6/);
  assert.doesNotMatch(out, /via Nix/);
});

test("module_ruby adopts PATH's Ruby when it is the right series", () => {
  const sys = fakeRuby(path.join(scratch("sys"), "bin"), "3.3.6");
  const proj = project({ ".ruby-version": "3.3.1\n" });
  const out = run("ruby", "module_ruby", {
    CLAUDE_PROJECT_DIR: proj, COOEE_NO_DEPS: "1", RBENV_ROOT: scratch("none"), PATH: `${sys}:${process.env.PATH}`,
  });
  assert.match(out, /adopted existing/);
  assert.match(out, /pins Ruby 3\.3\.1 but this box has 3\.3\.6/, "warns that a Gemfile patch pin would fail");
});

test("native gems: source builds need headers, precompiled ones don't", () => {
  const has = (files, gem) => run("ruby", `cooee_ruby_bundle_has "${project(files)}" ${gem} && echo yes || echo no`);
  assert.equal(has({ Gemfile: 'gem "pg", "~> 1.5"\n' }, "pg"), "yes");
  assert.equal(has({ Gemfile: "gem 'rails'\n" }, "pg"), "no");
  const lock = (spec) => `GEM\n  remote: https://rubygems.org/\n  specs:\n    ${spec}\n    rails (8.0.0)\n`;
  assert.equal(has({ Gemfile: "", "Gemfile.lock": lock("pg (1.5.9)") }, "pg"), "yes");
  const arch = execFileSync("uname", ["-m"], { encoding: "utf8" }).trim();
  assert.equal(has({ Gemfile: "", "Gemfile.lock": lock(`pg (1.6.2-${arch}-linux)`) }, "pg"), "no");
});

test("missing native-gem headers are apt-installed before bundle install", () => {
  const bin = scratch("bin");
  const logf = path.join(bin, "apt.log");
  for (const [name, body] of Object.entries({
    "apt-get": `#!/bin/sh\necho "apt-get $*" >> '${logf}'\n`,
    sudo: '#!/bin/sh\nexec "$@"\n',
  })) {
    fs.writeFileSync(path.join(bin, name), body);
    fs.chmodSync(path.join(bin, name), 0o755);
  }
  const proj = project({ Gemfile: 'gem "pg"\ngem "mysql2"\ngem "rails"\n' });
  const inc = scratch("include");
  fs.mkdirSync(path.join(inc, "mysql"));
  fs.writeFileSync(path.join(inc, "mysql", "mysql.h"), "");
  const out = run("ruby", `cooee_ruby_native_deps "${proj}"`, {
    COOEE_INCLUDE_DIR: inc, PATH: `${bin}:${process.env.PATH}`,
  });
  assert.match(out, /native-gem headers installed \(libpq-dev\)/);
  const calls = fs.readFileSync(logf, "utf8");
  assert.match(calls, /install -y --no-install-recommends libpq-dev\n/, "only the missing package");
});

test("ruby pre-approves bundler and Rails binstubs", () => {
  const perms = JSON.parse(run("ruby", "cooee_perms_json", { COOEE_NO_CHECKOUT_PERMS: "1" }));
  for (const rule of ["Bash(bundle:*)", "Bash(bin/rails:*)", "Bash(bundle exec:*)"]) assert.ok(perms.includes(rule), rule);
});
