// Tests for the `swift` module: which hosts each source needs, how the
// toolchain version is chosen, and the swiftly install path — driven against a
// stub `swiftly` (no network in the test env), which is where the module's own
// logic lives. The swift[nix] path is a Nix build and isn't exercised here.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render, moduleInfo } = require("../api/env/render");

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

// Source the rendered script (main neutralized), then run `snippet`; stderr is
// folded in because log/ok/warn write there.
function run(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const file = path.join(scratch("swift"), "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: { ...process.env, ...env },
  }).trim();
}

const hosts = (seg) => run(seg, `printf '%s\\n' "\${!_HOST_REASON[@]}" | sort`).split("\n");

test("the official toolchain needs swift.org's hosts, swift[nix] does not", () => {
  const official = hosts("swift");
  assert.ok(official.includes("download.swift.org"));
  assert.ok(official.includes("www.swift.org"));

  const nix = hosts("swift[nix]");
  assert.ok(!nix.includes("download.swift.org"), "swift[nix] must not probe download.swift.org");
  assert.ok(nix.includes("cache.nixos.org"));
});

test("the catalog lists every host the module can need, including the indented ones", () => {
  const info = moduleInfo().find((m) => m.name === "swift");
  const need = info.hosts.need.map((h) => h.host);
  for (const h of ["download.swift.org", "www.swift.org", "cache.nixos.org"]) assert.ok(need.includes(h), h);
  assert.ok(info.hosts.want.some((h) => h.host === "github.com"), "SwiftPM resolves packages from GitHub");
});

test("version: request param, else .swift-version, else latest", () => {
  const proj = scratch("proj");
  const env = { CLAUDE_PROJECT_DIR: proj };
  assert.equal(run("swift", "cooee_swift_requested_version 6.3", env), "6.3");
  assert.equal(run("swift", "cooee_swift_requested_version nix", env), "");
  assert.equal(run("swift", "cooee_swift_requested_version", env), "");

  fs.writeFileSync(path.join(proj, ".swift-version"), "6.2.1\n");
  assert.equal(run("swift", "cooee_swift_requested_version", env), "6.2.1");
  assert.equal(run("swift", "cooee_swift_requested_version 6.4", env), "6.4", "param beats the marker");
});

test("a requested version matches at a dot boundary", () => {
  const m = (want, have) =>
    run("swift", `cooee_swift_version_matches '${want}' '${have}' && echo y || echo n`);
  assert.equal(m("", "5.10.1"), "y");
  assert.equal(m("6.4", "6.4.0"), "y");
  assert.equal(m("6", "6.4.0"), "y");
  assert.equal(m("6.4", "6.40.1"), "n");
  assert.equal(m("6.4", "5.10.1"), "n");
});

// A fake swiftly that records its arguments and, on install, drops a `swift`
// into its bin dir and optionally writes a post-install script.
function stubSwiftly(home, { post = "" } = {}) {
  const bin = path.join(home, ".local/share/swiftly/bin");
  fs.mkdirSync(bin, { recursive: true });
  const log = path.join(home, "swiftly.args");
  fs.writeFileSync(
    path.join(bin, "swiftly"),
    `#!/usr/bin/env bash
echo "$*" >> ${JSON.stringify(log)}
if [[ "$1" == install ]]; then
  printf '#!/bin/sh\\necho "Swift version 6.4.0 (swift-6.4.0-RELEASE)"\\n' > "${bin}/swift"
  chmod +x "${bin}/swift"
  for a in "$@"; do case "$a" in --post-install-file) next=1 ;; *) [[ -n "\${next:-}" ]] && { printf %s ${JSON.stringify(post)} > "$a"; next=; } ;; esac; done
fi
`,
    { mode: 0o755 },
  );
  return log;
}

test("swiftly installs the requested version and puts its bin dir on PATH", () => {
  const home = scratch("home");
  const log = stubSwiftly(home);
  const out = run("swift[6.4]", "module_swift 6.4; command -v swift", {
    HOME: home,
    CLAUDE_PROJECT_DIR: scratch("proj"),
    COOEE_FORCE: "1",
  });
  const args = fs.readFileSync(log, "utf8");
  assert.match(args, /^install 6\.4 --use --assume-yes .*--post-install-file /m);
  assert.match(out, /swift ready: Swift 6\.4\.0/);
  assert.match(out, /system libraries already present/);
  assert.ok(out.endsWith(path.join(home, ".local/share/swiftly/bin/swift")));
  const profile = fs.readFileSync(path.join(home, ".config/coo-ee/env.sh"), "utf8");
  assert.match(profile, /SWIFTLY_HOME_DIR/);
  assert.match(profile, /\.local\/share\/swiftly\/bin/);
});

test("bare swift installs .swift-version's toolchain, or latest", () => {
  const home = scratch("home");
  const log = stubSwiftly(home);
  const proj = scratch("proj");
  const env = { HOME: home, CLAUDE_PROJECT_DIR: proj, COOEE_FORCE: "1" };
  run("swift", "module_swift", env);
  fs.writeFileSync(path.join(proj, ".swift-version"), "6.3\n");
  run("swift", "module_swift", env);
  const lines = fs.readFileSync(log, "utf8").trim().split("\n");
  assert.match(lines[0], /^install latest /);
  assert.match(lines[1], /^install 6\.3 /);
});

test("the distro packages swiftly asks for are reported when opted out", () => {
  const home = scratch("home");
  stubSwiftly(home, { post: "apt-get -y install libcurl4-openssl-dev libxml2-dev libz3-dev\n" });
  const out = run("swift", "module_swift", {
    HOME: home,
    CLAUDE_PROJECT_DIR: scratch("proj"),
    COOEE_FORCE: "1",
    COOEE_SWIFT_SYSTEM_DEPS: "0",
  });
  assert.match(out, /COOEE_SWIFT_SYSTEM_DEPS=0/);
  assert.match(out, /apt-get -y install libcurl4-openssl-dev/);
});

test("an existing swift that satisfies the request is adopted, a mismatch is not", () => {
  const home = scratch("home");
  const bin = path.join(home, "sysbin");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(bin, "swift"), '#!/bin/sh\necho "Swift version 5.10.1 (swift-5.10.1-RELEASE)"\n', { mode: 0o755 });
  const env = { HOME: home, CLAUDE_PROJECT_DIR: scratch("proj"), PATH: `${bin}:${process.env.PATH}` };
  assert.equal(run("swift", "cooee_present_swift && echo y || echo n", env), "y");
  assert.equal(run("swift[5.10]", "cooee_present_swift && echo y || echo n", env), "y");
  assert.equal(run("swift[6.4]", "cooee_present_swift && echo y || echo n", env), "n");
});

test("swift pre-approves the toolchain and participates in recommendations", () => {
  const perms = JSON.parse(run("swift", "cooee_perms_json", { COOEE_NO_CHECKOUT_PERMS: "1" }));
  for (const rule of ["Bash(swift:*)", "Bash(swiftc:*)", "Bash(swiftly:*)"]) assert.ok(perms.includes(rule), rule);
  const { recommend } = require("../api/env/recommend");
  assert.ok(recommend("swift").recommendations.some((r) => r.spec.includes("swiftlint")));
});
