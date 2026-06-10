// Unit tests for the pure renderer. Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { render, canonicalize, moduleInfo } = require("../api/env/render");

const names = (seg) => canonicalize(seg).entries.map((e) => e.name);
const canon = (seg) => render(seg).canonical;

test("base is always present and first", () => {
  assert.deepEqual(names(""), ["base"]);
  assert.deepEqual(names("java"), ["base", "java"]);
});

test("module order is canonicalized (cache-friendly)", () => {
  assert.equal(render("java,android").body, render("android,java").body);
  // android pulls in the android-cli skill automatically (see implication test).
  assert.deepEqual(canon("java,android"), [
    "base",
    "android",
    "android-cli",
    "java",
  ]);
});

test("blanks and duplicate modules collapse", () => {
  assert.deepEqual(names(" java , , java "), ["base", "java"]);
});

test("params parse, dedupe, and sort numerically", () => {
  assert.deepEqual(canon("java[21,17]"), ["base", "java[17,21]"]);
  assert.deepEqual(canon("java[17,17,21]"), ["base", "java[17,21]"]);
  assert.deepEqual(canon("java[8,17,11]"), ["base", "java[8,11,17]"]);
});

test("param order does not affect the rendered script", () => {
  assert.equal(render("java[21,17]").body, render("java[17,21]").body);
});

test("repeated modules merge their params", () => {
  assert.deepEqual(canon("java[17],java[21,17]"), ["base", "java[17,21]"]);
});

test("prefixed param tokens sort after numerics", () => {
  assert.deepEqual(canon("android-emulator[wear-33,9,37,30]"), [
    "base",
    "android",
    "android-cli",
    "android-emulator[9,30,37,wear-33]",
  ]);
});

test("params inject a set_params line; param-less requests stay clean", () => {
  const marker = "request parameters (injected by the renderer)";
  assert.ok(render("java[17,21]").body.includes("set_params java '17,21'"));
  assert.ok(render("java[17,21]").body.includes(marker));
  // A param-less request emits no injection block (byte-identical to before).
  assert.ok(!render("java,android").body.includes(marker));
  assert.ok(!render("java,android").body.includes("set_params java"));
});

test("?devenv splices the devenv backend; default splices the nix backend", () => {
  // The backend is resolved at render time, so the script carries exactly one
  // driver fragment and never a runtime `if devenv` branch.
  const on = render("java[17,21]", { devenv: true }).body;
  const off = render("java[17,21]").body;
  const NIX = "BACKEND: nix profile";
  const DEVENV = "BACKEND: devenv.sh";

  assert.ok(on.includes(DEVENV) && !on.includes(NIX));
  assert.ok(off.includes(NIX) && !off.includes(DEVENV));
  // No backend-selection conditional leaks into either rendered script.
  assert.ok(!on.includes("cooee_devenv_enabled") && !off.includes("cooee_devenv_enabled"));
  assert.ok(!on.includes("set_backend") && !off.includes("set_backend"));

  // The flag is purely a backend switch — params and the module list are
  // untouched, so the same set_params still renders and the canonical form matches.
  assert.ok(on.includes("set_params java '17,21'"));
  assert.deepEqual(render("java", { devenv: true }).canonical, render("java").canonical);
});

test("android-emulator implies android (transitively pulled in)", () => {
  // android-emulator -> android -> android-cli, all pulled in transitively.
  assert.deepEqual(names("android-emulator"), [
    "base",
    "android",
    "android-cli",
    "android-emulator",
  ]);
  assert.deepEqual(names("android-emulator,java"), [
    "base",
    "android",
    "android-cli",
    "android-emulator",
    "java",
  ]);
});

test("android pulls in the android-cli tool; android-cli stands alone", () => {
  // Selecting the android SDK auto-installs Google's Android CLI agent tool...
  assert.deepEqual(names("android"), ["base", "android", "android-cli"]);
  // ...but android-cli on its own is a lightweight, single-binary one-liner that
  // does NOT drag in the heavyweight Nix SDK.
  assert.deepEqual(names("android-cli"), ["base", "android-cli"]);

  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m]));
  assert.deepEqual(byName["android"].implies, ["android-cli"]);
  assert.deepEqual(byName["android-cli"].implies, []);
  // The CLI binary is downloaded from Google.
  assert.ok(
    byName["android-cli"].hosts.need.map((h) => h.host).includes("dl.google.com"),
  );
  // Setup registers the agent skill via `android init` (gated by an opt-out).
  const body = render("android-cli").body;
  assert.ok(body.includes('"$bin" init'), "runs android init");
  assert.ok(body.includes("COOEE_ANDROID_CLI_INIT"), "android init is opt-out-able");
});

test("android-cli is hidden from the picker but still renders and is implied", () => {
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m]));
  // Flagged hidden so the landing page leaves it off the searchable catalog...
  assert.equal(byName["android-cli"].hidden, true);
  // ...while every visible module (android, java, ...) stays unflagged.
  assert.equal(byName["android"].hidden, false);
  assert.equal(byName["java"].hidden, false);
  // It still renders on its own (the /android-cli one-liner works)...
  assert.equal(render("android-cli").status, 200);
  assert.deepEqual(canon("android-cli"), ["base", "android-cli"]);
  // ...and is still pulled in transitively when android is selected.
  assert.ok(names("android").includes("android-cli"));
});

test("an implied module added on its own carries no params", () => {
  assert.deepEqual(canon("android-emulator[34,wear-33]"), [
    "base",
    "android",
    "android-cli",
    "android-emulator[34,wear-33]",
  ]);
});

test("an explicitly-requested implied module keeps its own params", () => {
  assert.deepEqual(canon("android[30],android-emulator"), [
    "base",
    "android[30]",
    "android-cli",
    "android-emulator",
  ]);
});

test("implied modules are concatenated before their requesters", () => {
  // android (adb/ANDROID_HOME) must register before android-emulator uses it.
  const body = render("android-emulator").body;
  assert.ok(
    body.indexOf("register_module android\n") <
      body.indexOf("register_module android-emulator"),
    "android should be concatenated before android-emulator",
  );
});

test("playwright implies node and takes a version param", () => {
  // The agent CLI needs npm, so playwright pulls in node (canonical: before it).
  assert.deepEqual(names("playwright"), ["base", "node", "playwright"]);
  assert.deepEqual(canon("playwright[0.1.13]"), [
    "base",
    "node",
    "playwright[0.1.13]",
  ]);
  const body = render("playwright").body;
  assert.ok(
    body.indexOf("register_module node\n") <
      body.indexOf("register_module playwright"),
    "node should be concatenated before playwright (npm ready first)",
  );
  // The version param is injected for the fragment to read.
  assert.ok(render("playwright[0.1.13]").body.includes("set_params playwright '0.1.13'"));
});

test("compose is a curated target that implies java and android", () => {
  // No emulator — compose-preview renders without one. android also brings the
  // android-cli skill in transitively (compose -> android -> android-cli).
  assert.deepEqual(names("compose"), [
    "base",
    "android",
    "android-cli",
    "compose",
    "java",
  ]);
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m]));
  assert.deepEqual(byName["compose"].implies.sort(), ["android", "java"]);
  // The target clones the skill repo, so it needs github.com.
  assert.ok(byName["compose"].hosts.need.map((h) => h.host).includes("github.com"));
});

test("skills selects a single skill via a path segment after the repo", () => {
  // owner/repo/<skill> is a valid param and round-trips through canonicalization.
  assert.deepEqual(canon("skills[yschimke/skills/compose-preview]"), [
    "base",
    "skills[yschimke/skills/compose-preview]",
  ]);
  assert.ok(
    render("skills[yschimke/skills/compose-preview]").body.includes(
      "set_params skills 'yschimke/skills/compose-preview'",
    ),
  );
});

test("invalid params and malformed tokens return 400", () => {
  for (const seg of ["java[17;rm]", "java[17 21]", "java[$(x)]"]) {
    assert.equal(render(seg).status, 400, `expected 400 for ${JSON.stringify(seg)}`);
  }
});

test("unknown modules return 400 with the available list", () => {
  const o = render("nope");
  assert.equal(o.status, 400);
  assert.match(o.body, /unknown module/);
  assert.match(o.body, /available:/);
});

test("moduleInfo surfaces params and implies for the landing page", () => {
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m]));
  // android-emulator advertises params and its android implication.
  assert.ok(byName["android-emulator"].params.includes("android-emulator["));
  assert.deepEqual(byName["android-emulator"].implies, ["android"]);
  // java advertises a params hint; node does not.
  assert.ok(byName["java"].params.includes("java["));
  assert.equal(byName["node"].params, "");
  // base is flagged implicit so the UI shows it as fixed.
  assert.equal(byName["base"].implicit, true);
});

test("moduleInfo surfaces the hosts each module needs and wants", () => {
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m]));
  // base is required to install Nix itself.
  const baseNeed = byName["base"].hosts.need.map((h) => h.host);
  assert.ok(baseNeed.includes("cache.nixos.org"));
  assert.ok(baseNeed.includes("github.com"));
  // java needs the Nix cache and recommends the build registries (advisory).
  assert.deepEqual(
    byName["java"].hosts.need.map((h) => h.host),
    ["cache.nixos.org"],
  );
  const javaWant = byName["java"].hosts.want.map((h) => h.host);
  assert.ok(javaWant.includes("services.gradle.org"));
  // Reasons are carried through for the allowlist UI.
  assert.equal(
    byName["java"].hosts.need[0].reason,
    "prebuilt Temurin JDK from the Nix cache",
  );
  // Quoted wildcard hosts parse without their quotes.
  assert.ok(byName["android"].hosts.want.map((h) => h.host).includes("*.jetbrains.com"));
});

test("java/node render a COOEE_NO_DEPS-gated build-dependency prefetch", () => {
  // Shared gate + project-dir helper live in the header (always present).
  const header = render("").body;
  assert.ok(header.includes("cooee_deps_enabled"), "header defines the deps gate");
  assert.ok(header.includes("COOEE_NO_DEPS"), "the gate keys off COOEE_NO_DEPS");
  assert.ok(header.includes("cooee_project_dir"), "header defines the project-dir helper");

  // java warms Gradle; the task is overridable via COOEE_GRADLE_DEPS_TASK.
  const java = render("java").body;
  assert.ok(java.includes("cooee_prefetch_gradle"), "java defines + calls the Gradle prefetch");
  assert.ok(java.includes("COOEE_GRADLE_DEPS_TASK"), "the Gradle task is overridable");

  // node installs npm dependencies (npm ci with a lockfile, else npm install).
  const node = render("node").body;
  assert.ok(node.includes("cooee_prefetch_npm"), "node defines + calls the npm prefetch");
  assert.ok(node.includes("npm ci") && node.includes("npm install"), "node uses npm ci/install");
});

test("the version example from the brief renders and is well-formed", () => {
  const o = render("java[17,21],android[30,37,wear-33]");
  assert.equal(o.status, 200);
  assert.deepEqual(o.canonical, [
    "base",
    "android[30,37,wear-33]",
    "android-cli",
    "java[17,21]",
  ]);
  assert.ok(o.body.includes("set_params android '30,37,wear-33'"));
  assert.ok(o.body.includes("set_params java '17,21'"));
});
