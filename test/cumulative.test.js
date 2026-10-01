// Tests for cumulative requests: a box provisioned by one request (say the
// environment's `java,android`) and then by another (`ruby,postgres`) keeps
// both — one merged SessionStart hook, a stamp naming every module, and the
// earlier request's persisted env — instead of each request clobbering the
// other's and neither ever taking the fast path.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

function env(home, extra = {}) {
  return {
    ...process.env,
    HOME: home,
    COOEE_PROFILE: path.join(home, ".config", "coo-ee", "env.sh"),
    COOEE_HARNESS_ENV: path.join(home, ".config", "coo-ee", "env.harness"),
    CLAUDE_ENV_FILE: "",
    CLAUDE_CONFIG_DIR: "",
    COOEE_NO_CHECKOUT_PERMS: "1",
    COOEE_NO_NSS_CA: "1",
    ...extra,
  };
}

// Source the rendered script with main neutralized, then run `snippet`.
function evalIn(seg, snippet, home, extra = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const file = path.join(scratch("cum"), "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", ["-c", `bash "${file}" 2>&1`], { encoding: "utf8", env: env(home, extra) }).trim();
}

const merge = (a, b) => evalIn("base", `cooee_merge_segments '${a}' '${b}'`, scratch("home"));

test("segments merge by module, the newer request's params winning", () => {
  assert.equal(merge("android,android-cli,compose,java", "ruby,postgres"), "android,android-cli,compose,java,postgres,ruby");
  assert.equal(merge("java[17,21],android[34]", "java,node"), "android[34],java,node");
  assert.equal(merge("", "node,playwright"), "node,playwright");
  assert.equal(merge("tools[jq,gh],skills[a/b]", ""), "skills[a/b],tools[jq,gh]");
});

test("the previous request comes from the request file, else the hook, unless COOEE_REPLACE=1", () => {
  const home = scratch("home");
  const claude = path.join(home, ".claude");
  fs.mkdirSync(claude, { recursive: true });
  fs.writeFileSync(path.join(claude, "settings.json"), JSON.stringify({
    hooks: { SessionStart: [{ hooks: [{ type: "command", command: "curl -fsSL https://env.coo.ee/android,compose,java[17,21] | bash || echo 'skipped' >&2" }] }] },
  }));
  assert.equal(evalIn("base", "cooee_previous_segment", home), "android,compose,java[17,21]");
  fs.mkdirSync(path.join(home, ".config", "coo-ee"), { recursive: true });
  fs.writeFileSync(path.join(home, ".config", "coo-ee", "request"), "go,rust\n");
  assert.equal(evalIn("base", "cooee_previous_segment", home), "go,rust");
  assert.equal(evalIn("base", "cooee_previous_segment", home, { COOEE_REPLACE: "1" }), "");
});

test("the hook replaces an earlier request's coo.ee hook and keeps unrelated ones", () => {
  const home = scratch("home");
  const settings = path.join(home, ".claude", "settings.json");
  fs.mkdirSync(path.dirname(settings), { recursive: true });
  fs.writeFileSync(settings, JSON.stringify({
    hooks: { SessionStart: [
      { hooks: [{ type: "command", command: "curl -fsSL https://env.coo.ee/java | bash || echo x >&2" }] },
      { hooks: [{ type: "command", command: "echo mine" }] },
    ] },
  }));
  evalIn("node", "COOEE_HOOK_SEGMENT=java,node; cooee_install_session_hook", home);
  const cmds = JSON.parse(fs.readFileSync(settings, "utf8")).hooks.SessionStart.flatMap((e) => e.hooks.map((h) => h.command));
  assert.deepEqual(cmds.filter((c) => c.includes("env.coo.ee")), [
    "curl -fsSL https://env.coo.ee/java,node | bash || echo 'coo.ee/env: setup skipped (offline or host not allowlisted)' >&2",
  ]);
  assert.ok(cmds.includes("echo mine"), "a non-coo.ee hook is left alone");
});

// A full run of `node` (adopted, nothing installed) on a box an earlier `java`
// request provisioned.
const haveNode = (() => { try { execFileSync("node", ["--version"]); return true; } catch { return false; } })();

test("a second request keeps the first one's env, stamp and hook", { skip: !haveNode && "needs node" }, () => {
  const home = scratch("home");
  const cfg = path.join(home, ".config", "coo-ee");
  fs.mkdirSync(cfg, { recursive: true });
  fs.writeFileSync(path.join(cfg, "provisioned"), "base java");
  fs.writeFileSync(path.join(cfg, "request"), "java\n");
  fs.writeFileSync(path.join(cfg, "env.sh"), "export JAVA_HOME=/opt/fake-jdk\nexport PATH=/opt/fake-jdk/bin:/usr/bin:/bin\n");
  fs.writeFileSync(path.join(cfg, "env.harness"), "JAVA_HOME=/opt/fake-jdk\n");
  const file = path.join(scratch("cum"), "full.sh");
  fs.writeFileSync(file, render("node").body);
  const out = execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    cwd: scratch("proj"),
    env: env(home, { COOEE_NO_DEPS: "1", CLAUDE_PROJECT_DIR: scratch("proj") }),
  });
  assert.match(out, /Adding to this box's earlier request \(java\): it now carries java,node/);
  assert.equal(fs.readFileSync(path.join(cfg, "provisioned"), "utf8"), "base java node");
  assert.equal(fs.readFileSync(path.join(cfg, "request"), "utf8").trim(), "java,node");
  const profile = fs.readFileSync(path.join(cfg, "env.sh"), "utf8");
  assert.match(profile, /JAVA_HOME=\/opt\/fake-jdk/, "the earlier request's env survives");
  const settings = JSON.parse(fs.readFileSync(path.join(home, ".claude", "settings.json"), "utf8"));
  const cmds = settings.hooks.SessionStart.flatMap((e) => e.hooks.map((h) => h.command));
  assert.equal(cmds.length, 1);
  assert.match(cmds[0], /env\.coo\.ee\/java,node /);
});

test("compose counts as present once its skill and GL libs are in place", () => {
  const home = scratch("home");
  const present = (extra = {}) => evalIn("compose", "module_present compose && echo yes || echo no", home, extra);
  assert.equal(present(), "no");
  fs.mkdirSync(path.join(home, ".claude", "skills", "compose-preview"), { recursive: true });
  fs.writeFileSync(path.join(home, ".claude", "skills", "compose-preview", "SKILL.md"), "");
  assert.equal(present(), "no", "GL libs still missing");
  assert.equal(present({ COOEE_NO_DESKTOP_GL: "1" }), "yes");
  fs.mkdirSync(path.join(home, ".cache", "coo-ee", "desktop-gl", "lib"), { recursive: true });
  assert.equal(present(), "yes");
});
