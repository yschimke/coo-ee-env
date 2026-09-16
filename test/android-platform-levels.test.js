// Tests for how the android module reads platform params — in particular the
// minor-versioned levels (37.0) that API 37+ ships under.
//
// The bug these pin down: `cooee_android_levels` matched integers only, so
// `android[37.0]` was dropped and the module quietly installed the default
// platform instead. A container provisioned "successfully" with the wrong SDK,
// and the build discovered it much later.
//
// nixpkgs androidenv keys platforms exactly as Google publishes them — 34, 35,
// 36, 36.1, 37.0, 37.1, with no bare 37 — and `checkVersion` throws on a key it
// doesn't have, so the spelling has to survive the parser verbatim. The
// end-to-end assertions drive module_android with `nix` stubbed out and read the
// expression the backend hands it. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

// A failing install path is expected in some of these: the backend die()s when
// the stubbed nix "build" fails, and die exits the whole script rather than
// returning. The output is what we assert on, so keep it either way.
function evalRendered(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-andlvl-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `exec 2>&1\n${body}\n${snippet}\n`);
  try {
    return execFileSync("bash", [file], {
      encoding: "utf8",
      env: { ...process.env, ...env },
    }).trim();
  } catch (err) {
    if (err.stdout == null) throw err;
    return String(err.stdout).trim();
  }
}

// Drive module_android against a stubbed `nix` that records the expression it is
// given, with SDK discovery forced to miss so the install path runs (the CI box
// may ship an SDK of its own, which would otherwise be adopted).
function androidExpr(seg, env = {}) {
  const bin = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-nixstub-"));
  const capture = path.join(bin, "expr.nix");
  fs.writeFileSync(
    path.join(bin, "nix"),
    `#!/bin/bash
for ((i=1;i<=$#;i++)); do
  if [ "\${!i}" = "--expr" ]; then j=$((i+1)); printf '%s\\n' "\${!j}" > ${capture}; fi
done
echo "error: stubbed nix" >&2
exit 1
`,
  );
  fs.chmodSync(path.join(bin, "nix"), 0o755);
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-andhome-"));
  const out = evalRendered(
    seg,
    `cooee_sdk_is_complete() { return 1; }
     args=(); [[ -n "\${_MODULE_PARAMS[android]:-}" ]] && IFS="," read -r -a args <<< "\${_MODULE_PARAMS[android]}"
     module_android "\${args[@]}" || true`,
    { PATH: `${bin}${path.delimiter}${process.env.PATH}`, HOME: home, ...env },
  );
  const expr = fs.existsSync(capture) ? fs.readFileSync(capture, "utf8") : "";
  const pick = (key) => (expr.match(new RegExp(`${key}\\s*=\\s*\\[([^\\]]*)\\]`)) || [, ""])[1];
  return {
    log: out,
    platforms: (pick("platformVersions").match(/"[^"]*"/g) || []).map((s) => s.slice(1, -1)),
    buildTools: (pick("buildToolsVersions").match(/"[^"]*"/g) || []).map((s) => s.slice(1, -1)),
  };
}

// --- the parser -------------------------------------------------------------

test("a minor-versioned level survives the parser", () => {
  const out = evalRendered("android", `cooee_android_levels 37.0 | tr '\\n' ' '`);
  assert.equal(out, "37.0");
});

test("plain, wear and minor-versioned levels all parse, deduped in order", () => {
  const out = evalRendered("android", `cooee_android_levels 36 37.0 wear-33 36 | tr '\\n' ' '`);
  assert.equal(out, "36 37.0 33");
});

test("wear carries a minor version too", () => {
  const out = evalRendered("android", `cooee_android_levels wear-33.1 | tr '\\n' ' '`);
  assert.equal(out, "33.1");
});

test("a param that names no level is reported, not silently dropped", () => {
  const out = evalRendered("android", `cooee_android_unknown_params 36 37.0 wear-33 banana 1.2.3 | tr '\\n' ' '`);
  assert.equal(out, "banana 1.2.3");
});

// --- what androidenv is actually asked for ----------------------------------

test("android[37.0] asks androidenv for 37.0, not the default platform", () => {
  const { platforms } = androidExpr("android[37.0]");
  assert.deepEqual(platforms, ["37.0"]);
});

test("android[36] and a bare request are unchanged", () => {
  assert.deepEqual(androidExpr("android[36]").platforms, ["36"]);
  assert.deepEqual(androidExpr("android").platforms, ["36"]);
});

test("a mixed request keeps every level, minor version included", () => {
  const { platforms } = androidExpr("android[36,37.0,wear-33]");
  assert.deepEqual(platforms, ["36", "37.0", "33"]);
});

test("an unrecognized param warns and falls back to the default", () => {
  const { log, platforms } = androidExpr("android[banana]");
  assert.match(log, /ignoring unrecognized platform param\(s\): banana/);
  assert.deepEqual(platforms, ["36"]);
});

test("a bare API 37 is flagged as the wrong spelling, but still passed through", () => {
  const { log, platforms } = androidExpr("android[37]");
  assert.match(log, /did you mean 37\.0\?/);
  assert.deepEqual(platforms, ["37"], "androidenv stays the source of truth on which keys exist");
});

// --- build-tools ------------------------------------------------------------

test("a platform newer than the default raises the build-tools revision", () => {
  assert.deepEqual(androidExpr("android[37.0]").buildTools, ["37.0.0"]);
  assert.deepEqual(androidExpr("android[36,37.0]").buildTools, ["37.0.0"]);
});

test("older and default platforms keep the default build-tools", () => {
  assert.deepEqual(androidExpr("android[30]").buildTools, ["36.0.0"]);
  assert.deepEqual(androidExpr("android[36]").buildTools, ["36.0.0"]);
});

test("an explicit build-tools pin is honored exactly", () => {
  const { buildTools } = androidExpr("android[37.0]", { COOEE_ANDROID_BUILD_TOOLS: "36.0.0" });
  assert.deepEqual(buildTools, ["36.0.0"]);
});
