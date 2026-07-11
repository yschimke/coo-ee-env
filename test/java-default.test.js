// Tests for the java module's default JDK-major set: with no explicit request it
// provisions BOTH 17 and 21 (plus any distinct toolchain major the project pins),
// so a box shipping only one LTS doesn't leave half the builds without a JDK.
// These load the rendered java module (neutralizing `main "$@"`) and evaluate
// cooee_java_default_versions against a project dir. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("java").body.replace(/^main "\$@"$/m, ":");

// Run `cooee_java_default_versions` from inside `projectDir`, returning the
// canonicalized (ascending, unique) comma-joined majors.
function defaultVersions(projectDir) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-jdef-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(
    file,
    `${BODY}\ncd '${projectDir}' && cooee_java_default_versions | sort -un | paste -sd,\n`,
  );
  return execFileSync("bash", [file], { encoding: "utf8" }).trim();
}

function projectPinning(version) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-proj-"));
  if (version != null) {
    fs.mkdirSync(path.join(dir, "gradle"), { recursive: true });
    fs.writeFileSync(
      path.join(dir, "gradle", "gradle-daemon-jvm.properties"),
      `toolchainVersion=${version}\n`,
    );
  }
  return dir;
}

test("defaults to 17 + 21 when the project pins no toolchain", () => {
  assert.equal(defaultVersions(projectPinning(null)), "17,21");
});

test("a project pinning 17 or 21 does not duplicate the default", () => {
  assert.equal(defaultVersions(projectPinning(17)), "17,21");
  assert.equal(defaultVersions(projectPinning(21)), "17,21");
});

test("folds in a distinct project-pinned toolchain major", () => {
  assert.equal(defaultVersions(projectPinning(22)), "17,21,22");
});
