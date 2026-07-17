// Tests for the android module pinning sdk.dir into local.properties across the
// local project checkouts. AGP reads sdk.dir from local.properties before the
// ANDROID_HOME / ANDROID_SDK_ROOT env vars, so a build launched in a shell that
// never sourced our persisted env still finds the SDK. A cloud session can hold
// several repos side by side under the workspace root; every Gradle build root —
// not just the one at the invocation dir — must get sdk.dir pinned.
// Load the rendered android module (neutralizing `main "$@"`) and drive
// cooee_android_pin_sdk_dir. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("android").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-pin-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

// A workspace root holding side-by-side checkouts. `layout` maps a relative path
// to the file to create there (touch), e.g. { "app/settings.gradle.kts": "" }.
function workspace(layout) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-ws-"));
  for (const [rel, contents] of Object.entries(layout)) {
    const p = path.join(root, rel);
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, contents);
  }
  return root;
}

function readProp(dir) {
  const f = path.join(dir, "local.properties");
  return fs.existsSync(f) ? fs.readFileSync(f, "utf8") : null;
}

test("pins sdk.dir in a single project rooted at the project dir", () => {
  const root = workspace({ "repo/build.gradle.kts": "" });
  const proj = path.join(root, "repo");
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { CLAUDE_PROJECT_DIR: proj });
  assert.match(readProp(proj), /^sdk\.dir=\/opt\/android-sdk$/m);
});

test("pins sdk.dir in EVERY Gradle checkout under the workspace root", () => {
  const root = workspace({
    "app/settings.gradle.kts": "",
    "lib/settings.gradle": "",
    "single/build.gradle": "", // settings-less, but has a wrapper below
    "single/gradlew": "",
  });
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { COOEE_CHECKOUTS_DIR: root });
  for (const repo of ["app", "lib", "single"]) {
    assert.match(
      readProp(path.join(root, repo)) || "",
      /^sdk\.dir=\/opt\/android-sdk$/m,
      `${repo} should be pinned`,
    );
  }
});

test("pins a nested Android build (e.g. <repo>/android/)", () => {
  const root = workspace({ "repo/android/settings.gradle.kts": "" });
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { COOEE_CHECKOUTS_DIR: root });
  assert.match(readProp(path.join(root, "repo", "android")) || "", /sdk\.dir=\/opt\/android-sdk/);
});

test("does NOT write sdk.dir into a subproject (bare build.gradle, no settings/gradlew)", () => {
  const root = workspace({
    "repo/settings.gradle.kts": "",
    "repo/feature/build.gradle.kts": "", // a subproject module, not a build root
  });
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { COOEE_CHECKOUTS_DIR: root });
  assert.match(readProp(path.join(root, "repo")) || "", /sdk\.dir=/, "root pinned");
  assert.equal(
    readProp(path.join(root, "repo", "feature")),
    null,
    "subproject must not get its own local.properties",
  );
});

test("updates a stale sdk.dir in place, preserving other entries", () => {
  const root = workspace({
    "repo/settings.gradle.kts": "",
    "repo/local.properties": "flutter.sdk=/old/flutter\nsdk.dir=/stale/sdk\n",
  });
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { CLAUDE_PROJECT_DIR: path.join(root, "repo") });
  const prop = readProp(path.join(root, "repo"));
  assert.match(prop, /^sdk\.dir=\/opt\/android-sdk$/m, "sdk.dir updated");
  assert.match(prop, /^flutter\.sdk=\/old\/flutter$/m, "other entries preserved");
  assert.doesNotMatch(prop, /\/stale\/sdk/, "stale value gone");
});

test("is a no-op (single write) when the project dir is the only checkout", () => {
  // A single repo whose parent is a system dir: workspace root falls back to the
  // project dir itself, and only that one local.properties is written.
  const proj = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-solo-"));
  fs.writeFileSync(path.join(proj, "settings.gradle.kts"), "");
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, { CLAUDE_PROJECT_DIR: proj });
  assert.match(readProp(proj) || "", /sdk\.dir=\/opt\/android-sdk/);
});

test("no Gradle build anywhere → writes nothing", () => {
  const root = workspace({ "repo/README.md": "" });
  run(`cooee_android_pin_sdk_dir '/opt/android-sdk'`, {
    COOEE_CHECKOUTS_DIR: root,
    CLAUDE_PROJECT_DIR: path.join(root, "repo"),
  });
  assert.equal(readProp(path.join(root, "repo")), null, "no local.properties created");
});
