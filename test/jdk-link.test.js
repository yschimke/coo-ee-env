// Tests for the java module linking each provisioned JDK into the conventional
// /usr/lib/jvm (overridable via COOEE_JVM_LINK_DIR), so Gradle toolchain
// auto-detection and agents find a Nix JDK that otherwise lives only at an
// unguessable /nix/store path. Load the rendered java module (neutralizing
// `main "$@"`) and drive cooee_link_jdk_typical. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("java").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-jl-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

// A minimal JDK home: bin/java + a release file naming the major.
function fakeJdk(major) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), `cooee-jdk${major}-`));
  fs.mkdirSync(path.join(home, "bin"), { recursive: true });
  fs.writeFileSync(path.join(home, "bin", "java"), "#!/bin/sh\n");
  fs.chmodSync(path.join(home, "bin", "java"), 0o755);
  fs.writeFileSync(path.join(home, "release"), `JAVA_VERSION="${major}.0.10"\n`);
  return home;
}

function jvmDir() {
  return path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cooee-jvm-")), "jvm");
}

test("links a JDK into <jvmdir>/temurin-<major> and its java resolves", () => {
  const home = fakeJdk(17);
  const jvm = jvmDir();
  run(`cooee_link_jdk_typical '${home}' 17`, { COOEE_JVM_LINK_DIR: jvm });
  const link = path.join(jvm, "temurin-17");
  assert.equal(fs.realpathSync(link), fs.realpathSync(home), "link points at the JDK home");
  assert.ok(fs.existsSync(path.join(link, "bin/java")), "java resolves through the link");
});

test("skips a JDK already under the link dir (no self-link)", () => {
  const jvm = jvmDir();
  fs.mkdirSync(jvm, { recursive: true });
  // A JDK that already lives inside the conventional dir.
  const home = path.join(jvm, "java-17-openjdk");
  fs.mkdirSync(path.join(home, "bin"), { recursive: true });
  fs.writeFileSync(path.join(home, "bin", "java"), "#!/bin/sh\n");
  fs.chmodSync(path.join(home, "bin", "java"), 0o755);
  fs.writeFileSync(path.join(home, "release"), `JAVA_VERSION="17.0.10"\n`);
  run(`cooee_link_jdk_typical '${home}' 17`, { COOEE_JVM_LINK_DIR: jvm });
  assert.ok(!fs.existsSync(path.join(jvm, "temurin-17")), "no redundant temurin-17 alias created");
});

test("is idempotent — re-linking leaves the same symlink", () => {
  const home = fakeJdk(21);
  const jvm = jvmDir();
  run(`cooee_link_jdk_typical '${home}' 21`, { COOEE_JVM_LINK_DIR: jvm });
  run(`cooee_link_jdk_typical '${home}' 21`, { COOEE_JVM_LINK_DIR: jvm });
  const link = path.join(jvm, "temurin-21");
  assert.equal(fs.realpathSync(link), fs.realpathSync(home));
});
