// Tests for the Gradle wrapper-cache path logic the java module uses when it
// seeds a distribution from the repo.gradle.org proxy. These exercise the
// *rendered* bash: they load the java module's functions (neutralizing the final
// `main "$@"`) and evaluate a snippet against them — so the zipStore-aware
// destination computation is checked end to end. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function evalRendered(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gradle-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

const URL = "https://services.gradle.org/distributions/gradle-9.6.1-bin.zip";
// base36(md5(URL)) — the name Gradle's PathAssembler#getHash derives for this
// distributionUrl, i.e. the wrapper cache subdir.
const HASH = "4ticwg1pgcbps2hj28r8so764";

function writeProps(contents) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-repo-"));
  const wdir = path.join(repo, "gradle", "wrapper");
  fs.mkdirSync(wdir, { recursive: true });
  const props = path.join(wdir, "gradle-wrapper.properties");
  fs.writeFileSync(props, contents);
  return { repo, props };
}

test("zip dest defaults to GRADLE_USER_HOME/wrapper/dists", () => {
  const { repo, props } = writeProps(`distributionUrl=${URL.replace(/:/g, "\\:")}\n`);
  const out = evalRendered("java", `cooee_gradle_zip_dest '${props}' '${URL}' '${repo}'`, {
    GRADLE_USER_HOME: "/tmp/guh",
  });
  assert.equal(out, `/tmp/guh/wrapper/dists/gradle-9.6.1-bin/${HASH}`);
});

test("zip dest honors zipStoreBase=PROJECT and a custom zipStorePath", () => {
  const { repo, props } = writeProps(
    `distributionUrl=${URL.replace(/:/g, "\\:")}\n` +
      `zipStoreBase=PROJECT\n` +
      `zipStorePath=.gradle/dists\n`,
  );
  const out = evalRendered("java", `cooee_gradle_zip_dest '${props}' '${URL}' '${repo}'`, {
    GRADLE_USER_HOME: "/tmp/guh",
  });
  assert.equal(out, `${repo}/.gradle/dists/gradle-9.6.1-bin/${HASH}`);
});

test("store base resolves PROJECT to the build root, everything else to GRADLE_USER_HOME", () => {
  const proj = evalRendered("java", "cooee_gradle_store_base PROJECT /my/repo", {
    GRADLE_USER_HOME: "/tmp/guh",
  });
  assert.equal(proj, "/my/repo");
  const guh = evalRendered("java", "cooee_gradle_store_base GRADLE_USER_HOME /my/repo", {
    GRADLE_USER_HOME: "/tmp/guh",
  });
  assert.equal(guh, "/tmp/guh");
});
