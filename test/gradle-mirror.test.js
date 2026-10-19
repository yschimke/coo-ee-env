// Tests for the Maven Central mirror + network-retry settings the java module
// writes into the Gradle user home (cooee_gradle_maven_mirror). These exercise
// the *rendered* bash against a scratch GRADLE_USER_HOME, never the real one.
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("java").body.replace(/^main "\$@"$/m, ":");
const INIT = "init.d/cooee-maven-mirror.init.gradle";
const ATTEMPTS = "systemProp.org.gradle.internal.network.retry.max.attempts";
const BACKOFF = "systemProp.org.gradle.internal.network.retry.initial.backOff";

function scratch() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "cooee-mirror-"));
}

function run(guh, env = {}) {
  const file = path.join(scratch(), "reg.sh");
  fs.writeFileSync(file, `${BODY}\ncooee_gradle_maven_mirror >/dev/null 2>&1\n`);
  execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, GRADLE_USER_HOME: guh, ...env },
  });
}

const props = (guh) => fs.readFileSync(path.join(guh, "gradle.properties"), "utf8");

test("writes the mirror init script and the retry properties", () => {
  const guh = scratch();
  run(guh);
  const init = fs.readFileSync(path.join(guh, INIT), "utf8");
  assert.match(init, /def mirrorUrl = 'https:\/\/maven-central\.storage-download\.googleapis\.com\/maven2\/'/);
  assert.match(init, /repos\.addFirst\(m\)/);
  assert.match(init, /def googleOnly = \['androidx'\]/);
  assert.match(init, /hostOf\(r\) == 'plugins\.gradle\.org'/);
  // Groovy's own interpolation survives the bash heredoc.
  assert.match(init, /Maven mirror not applied: \$\{t\}/);
  assert.equal(props(guh), `${ATTEMPTS}=6\n${BACKOFF}=2000\n`);
});

test("re-running is idempotent and keeps the user's own values", () => {
  const guh = scratch();
  fs.writeFileSync(path.join(guh, "gradle.properties"), `org.gradle.caching=true\n${ATTEMPTS}=10\n`);
  run(guh);
  run(guh);
  assert.equal(props(guh), `org.gradle.caching=true\n${ATTEMPTS}=10\n${BACKOFF}=2000\n`);
});

test("COOEE_NO_MAVEN_MIRROR retires the init script but keeps the retries", () => {
  const guh = scratch();
  run(guh);
  run(guh, { COOEE_NO_MAVEN_MIRROR: "1" });
  assert.ok(!fs.existsSync(path.join(guh, INIT)));
  assert.match(props(guh), new RegExp(`${ATTEMPTS.replace(/\./g, "\\.")}=6`));
});

test("COOEE_NO_GRADLE_INIT skips only the init script", () => {
  const guh = scratch();
  run(guh, { COOEE_NO_GRADLE_INIT: "1" });
  assert.ok(!fs.existsSync(path.join(guh, INIT)));
  assert.ok(fs.existsSync(path.join(guh, "gradle.properties")));
});

test("COOEE_NO_GRADLE_PROPS writes nothing at all", () => {
  const guh = scratch();
  run(guh, { COOEE_NO_GRADLE_PROPS: "1" });
  assert.deepEqual(fs.readdirSync(guh), []);
});

test("COOEE_MAVEN_MIRROR_URL overrides the mirror", () => {
  const guh = scratch();
  run(guh, { COOEE_MAVEN_MIRROR_URL: "https://mirror.example/maven2/" });
  assert.match(fs.readFileSync(path.join(guh, INIT), "utf8"), /def mirrorUrl = 'https:\/\/mirror\.example\/maven2\/'/);
});
