// Tests for the android module publishing a conventional, agent-guessable view
// of the Nix-store SDK: symlinks to the read-only store plus the missing
// cmdline-tools/latest alias, at /opt/android-sdk (overridable via
// COOEE_ANDROID_SDK_LINK_DIR). Load the rendered android module (neutralizing
// `main "$@"`) and drive cooee_android_publish_sdk. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("android").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-and-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

// A fake SDK tree. `cmdlineDir` is the cmdline-tools subdir name (a version like
// "21.0" for a store-style SDK, or "latest" for an already-conventional one).
function fakeSdk(cmdlineDir) {
  const sdk = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-sdk-"));
  const exe = (p) => {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, "#!/bin/sh\n");
    fs.chmodSync(p, 0o755);
  };
  exe(path.join(sdk, "platform-tools", "adb"));
  exe(path.join(sdk, "cmdline-tools", cmdlineDir, "bin", "sdkmanager"));
  exe(path.join(sdk, "cmdline-tools", cmdlineDir, "bin", "avdmanager"));
  fs.mkdirSync(path.join(sdk, "platforms", "android-36"), { recursive: true });
  fs.mkdirSync(path.join(sdk, "build-tools", "36.0.0"), { recursive: true });
  fs.mkdirSync(path.join(sdk, "emulator"), { recursive: true });
  return sdk;
}

test("publishes a conventional view with cmdline-tools/latest for a versioned (store-style) SDK", () => {
  const sdk = fakeSdk("21.0"); // no `latest` — the Nix layout
  const dest = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cooee-link-")), "android-sdk");
  const out = run(`cooee_android_publish_sdk '${sdk}'`, {
    COOEE_ANDROID_SDK_LINK_DIR: dest,
  });
  assert.equal(out, dest, "returns the published path");
  // sdkmanager/avdmanager now resolve through the synthesized `latest` alias.
  assert.ok(
    fs.existsSync(path.join(dest, "cmdline-tools/latest/bin/sdkmanager")),
    "cmdline-tools/latest/bin/sdkmanager resolves",
  );
  assert.ok(
    fs.existsSync(path.join(dest, "cmdline-tools/latest/bin/avdmanager")),
    "avdmanager resolves",
  );
  // Other entries are mirrored so adb/platforms/build-tools are reachable.
  assert.ok(fs.existsSync(path.join(dest, "platform-tools/adb")), "platform-tools mirrored");
  assert.ok(fs.existsSync(path.join(dest, "platforms/android-36")), "platforms mirrored");
  assert.ok(fs.existsSync(path.join(dest, "build-tools/36.0.0")), "build-tools mirrored");
});

test("leaves an SDK that already has cmdline-tools/latest (and isn't in the store) untouched", () => {
  const sdk = fakeSdk("latest");
  const out = run(`cooee_android_publish_sdk '${sdk}'`, {
    COOEE_ANDROID_SDK_LINK_DIR: "/must/not/be/created",
  });
  assert.equal(out, sdk, "echoes the SDK unchanged, no view published");
  assert.ok(!fs.existsSync("/must/not/be/created"), "does not touch the link dir");
});

test("is idempotent — re-publishing returns the same view", () => {
  const sdk = fakeSdk("21.0");
  const dest = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "cooee-link-")), "android-sdk");
  const first = run(`cooee_android_publish_sdk '${sdk}'`, { COOEE_ANDROID_SDK_LINK_DIR: dest });
  const second = run(`cooee_android_publish_sdk '${sdk}'`, { COOEE_ANDROID_SDK_LINK_DIR: dest });
  assert.equal(first, dest);
  assert.equal(second, dest);
});
