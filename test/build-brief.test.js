// Tests for the build-brief setup the java module runs when Gradle is selected.
// Like gradle-seed.test.js these exercise the *rendered* bash: the module's
// functions are loaded (with the final `main "$@"` neutralized) and a snippet is
// evaluated against them, so the gate, the install and the guide are checked end
// to end. Network is stubbed by overriding cooee_fetch with a local copy, which
// keeps the download/verify/unpack path under test without leaving the machine.
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render, moduleInfo } = require("../api/env/render");

function evalRendered(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-bb-"));
  const file = path.join(dir, "reg.sh");
  // The module talks to the operator on stderr (log/warn/ok), so fold both
  // streams together — the assertions below are mostly about what it *said*.
  fs.writeFileSync(file, `exec 2>&1\n${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

// `gradle` on PATH is a legitimate "Gradle is selected" signal, and CI runners
// ship one — so a test about its *absence* has to say so. Dropping the PATH
// entries that carry Gradle would take /usr/bin (and with it bash, find, sed)
// along with it, so shadow the one lookup the gate makes instead, and forward
// everything else to the builtin.
const NO_GRADLE = `
command() {
  [ "$1" = -v ] && [ "$2" = gradle ] && return 1
  builtin command "$@"
}`;

function tmpdir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

// A workspace root holding one checkout with a Gradle wrapper — what
// cooee_gradle_selected scans for.
function gradleCheckout() {
  const root = tmpdir("cooee-ws-");
  const wrapper = path.join(root, "repo", "gradle", "wrapper");
  fs.mkdirSync(wrapper, { recursive: true });
  fs.writeFileSync(
    path.join(wrapper, "gradle-wrapper.properties"),
    "distributionUrl=https\\://services.gradle.org/distributions/gradle-9.6.1-bin.zip\n",
  );
  return root;
}

// A stand-in release: a tarball holding a fake `build-brief` plus its SHA256SUMS,
// served to the module by a cooee_fetch override that copies by basename.
function fakeRelease(version = "9.9.9") {
  const dir = tmpdir("cooee-bbrel-");
  const bin = path.join(dir, "build-brief");
  fs.writeFileSync(bin, `#!/bin/sh\n[ "$1" = "--version" ] && echo "build-brief ${version}"\n`);
  fs.chmodSync(bin, 0o755);
  const platform = `linux_${process.arch === "arm64" ? "arm64" : "amd64"}`;
  const asset = `build-brief_${version}_${platform}.tar.gz`;
  execFileSync("tar", ["-czf", path.join(dir, asset), "-C", dir, "build-brief"]);
  const sum = execFileSync("sha256sum", [path.join(dir, asset)], { encoding: "utf8" })
    .split(/\s+/)[0];
  fs.writeFileSync(path.join(dir, "SHA256SUMS"), `${sum}  ${asset}\n`);
  return { dir, asset, sum };
}

const stubFetch = (dir, sums = "SHA256SUMS") => `
cooee_fetch() {
  local url=$1 dest=$2 name=\${1##*/}
  [ "$name" = SHA256SUMS ] && name=${sums}
  cp "${dir}/$name" "$dest" 2>/dev/null
}`;

// --- the gate ---------------------------------------------------------------

test("gradle is selected when a checkout has a Gradle wrapper", () => {
  const out = evalRendered("java", `${NO_GRADLE}\ncooee_gradle_selected && echo yes || echo no`, {
    COOEE_CHECKOUTS_DIR: gradleCheckout(),
  });
  assert.equal(out, "yes");
});

test("gradle is selected when the request asks for tools[gradle]", () => {
  const out = evalRendered("java,tools[gradle]", `${NO_GRADLE}\ncooee_gradle_selected && echo yes || echo no`, {
    COOEE_CHECKOUTS_DIR: tmpdir("cooee-empty-"),
  });
  assert.equal(out, "yes");
});

test("gradle is not selected for a JDK-only checkout", () => {
  const out = evalRendered("java", `${NO_GRADLE}\ncooee_gradle_selected && echo yes || echo no`, {
    COOEE_CHECKOUTS_DIR: tmpdir("cooee-empty-"),
  });
  assert.equal(out, "no");
});

test("setup is a no-op without Gradle, and under COOEE_NO_BUILD_BRIEF=1", () => {
  const home = tmpdir("cooee-home-");
  const noGradle = evalRendered("java", `${NO_GRADLE}\ncooee_build_brief_setup`, {
    COOEE_CHECKOUTS_DIR: tmpdir("cooee-empty-"),
    HOME: home,
  });
  assert.match(noGradle, /no Gradle build selected/);
  const optedOut = evalRendered("java", "cooee_build_brief_setup", {
    COOEE_CHECKOUTS_DIR: gradleCheckout(),
    HOME: home,
    COOEE_NO_BUILD_BRIEF: "1",
  });
  assert.match(optedOut, /COOEE_NO_BUILD_BRIEF=1/);
  assert.equal(fs.existsSync(path.join(home, ".claude", "CLAUDE.md")), false);
});

// --- install ----------------------------------------------------------------

test("a pinned release is downloaded, verified, installed and put on PATH", () => {
  const { dir } = fakeRelease();
  const home = tmpdir("cooee-home-");
  const out = evalRendered(
    "java",
    `${stubFetch(dir)}
     cooee_build_brief_setup
     command -v build-brief`,
    {
      COOEE_CHECKOUTS_DIR: gradleCheckout(),
      HOME: home,
      COOEE_BUILD_BRIEF_VERSION: "9.9.9",
    },
  );
  assert.equal(out.split("\n").pop(), path.join(home, ".local/bin/build-brief"));
  assert.equal(fs.existsSync(path.join(home, ".local/bin/build-brief")), true);
});

test("a checksum mismatch refuses the install rather than trusting the bytes", () => {
  const { dir, asset } = fakeRelease();
  fs.writeFileSync(path.join(dir, "BAD_SUMS"), `deadbeef  ${asset}\n`);
  const home = tmpdir("cooee-home-");
  const out = evalRendered(
    "java",
    `${stubFetch(dir, "BAD_SUMS")}
     cooee_build_brief_install || echo refused`,
    {
      COOEE_CHECKOUTS_DIR: gradleCheckout(),
      HOME: home,
      COOEE_BUILD_BRIEF_VERSION: "9.9.9",
    },
  );
  assert.match(out, /checksum mismatch/);
  assert.match(out, /refused/);
  assert.equal(fs.existsSync(path.join(home, ".local/bin/build-brief")), false);
});

// --- the guide --------------------------------------------------------------

test("the guide is written to the global CLAUDE.md, preserving what is there", () => {
  const home = tmpdir("cooee-home-");
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "CLAUDE.md"), "# My memory\n\nkeep me\n");
  evalRendered("java", "cooee_build_brief_guide", {
    COOEE_CHECKOUTS_DIR: gradleCheckout(),
    HOME: home,
  });
  const md = fs.readFileSync(path.join(home, ".claude", "CLAUDE.md"), "utf8");
  assert.match(md, /^# My memory/);
  assert.match(md, /keep me/);
  assert.match(md, /build-brief \.\/gradlew/);
  assert.match(md, /Don't run `build-brief --install` in a checkout/);
});

test("re-running replaces the managed block instead of stacking copies", () => {
  const home = tmpdir("cooee-home-");
  evalRendered("java", "cooee_build_brief_guide; cooee_build_brief_guide", {
    COOEE_CHECKOUTS_DIR: gradleCheckout(),
    HOME: home,
  });
  const md = fs.readFileSync(path.join(home, ".claude", "CLAUDE.md"), "utf8");
  assert.equal(md.match(/coo\.ee\/env:build-brief:start/g).length, 1);
  assert.equal(md.match(/coo\.ee\/env:build-brief:end/g).length, 1);
});

test("the guide can be skipped on its own, without skipping the binary", () => {
  const home = tmpdir("cooee-home-");
  evalRendered("java", "cooee_build_brief_guide", {
    COOEE_CHECKOUTS_DIR: gradleCheckout(),
    HOME: home,
    COOEE_NO_BUILD_BRIEF_GUIDE: "1",
  });
  assert.equal(fs.existsSync(path.join(home, ".claude", "CLAUDE.md")), false);
});

// --- catalog ----------------------------------------------------------------

test("java advertises the hosts build-brief installs from, and pre-approves it", () => {
  const java = moduleInfo().find((m) => m.name === "java");
  const want = new Set(java.hosts.want.map((h) => h.host));
  for (const host of ["github.com", "release-assets.githubusercontent.com", "bb.staticvar.dev"]) {
    assert.ok(want.has(host), `java should advertise ${host}`);
  }
  assert.match(render("java").body, /Bash\(build-brief:\*\)/);
});
