// Tests for where skills and the environment-wide guide land per agent. Claude
// Code reads ~/.claude; Codex and Gemini read ~/.agents/skills and their own
// global rules file. Like build-brief.test.js these load the rendered bash (with
// `main "$@"` neutralized) and run a snippet against a throwaway HOME.
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function tmpdir(prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

function evalRendered(seg, snippet, env = {}) {
  const body = render(seg).body.replace(/^main "\$@"$/m, ":");
  const file = path.join(tmpdir("cooee-agents-"), "reg.sh");
  fs.writeFileSync(file, `exec 2>&1\n${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    // An empty COOEE_AGENTS would fall through to detection, which reads the
    // runner's PATH — so every test names the agents it expects.
    env: { ...process.env, CODEX_HOME: "", ...env },
  }).trim();
}

// A skill directory standing in for a cloned repo's skill.
function fakeSkill(name = "demo") {
  const dir = path.join(tmpdir("cooee-skill-"), name);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, "SKILL.md"), `---\nname: ${name}\n---\n`);
  return dir;
}

test("with no other agent, skills and rules go to Claude's home only", () => {
  const home = tmpdir("cooee-home-");
  const out = evalRendered("java", "cooee_skill_dirs; cooee_agent_rules_files", {
    HOME: home,
    COOEE_AGENTS: "none",
  });
  assert.deepEqual(out.split("\n"), [
    path.join(home, ".claude/skills"),
    path.join(home, ".claude/CLAUDE.md"),
  ]);
});

test("Codex and Gemini add ~/.agents/skills and their own rules files", () => {
  const home = tmpdir("cooee-home-");
  const out = evalRendered("java", "cooee_skill_dirs; cooee_agent_rules_files", {
    HOME: home,
    COOEE_AGENTS: "codex,gemini",
  });
  assert.deepEqual(out.split("\n"), [
    path.join(home, ".claude/skills"),
    path.join(home, ".agents/skills"),
    path.join(home, ".claude/CLAUDE.md"),
    path.join(home, ".codex/AGENTS.md"),
    path.join(home, ".gemini/GEMINI.md"),
  ]);
});

test("a Codex config dir is enough to detect Codex, and CODEX_HOME is honoured", () => {
  const home = tmpdir("cooee-home-");
  const codexHome = path.join(home, "codex-home");
  fs.mkdirSync(codexHome);
  const out = evalRendered(
    "java",
    // Hide any codex/gemini CLI the runner happens to have.
    `command() { case "$2" in codex|gemini) return 1;; esac; builtin command "$@"; }
     cooee_agent_rules_files`,
    { HOME: home, CODEX_HOME: codexHome, COOEE_AGENTS: "" },
  );
  assert.deepEqual(out.split("\n"), [
    path.join(home, ".claude/CLAUDE.md"),
    path.join(codexHome, "AGENTS.md"),
  ]);
});

test("a skill is linked into every agent's skills dir", () => {
  const home = tmpdir("cooee-home-");
  const skill = fakeSkill();
  evalRendered("java", `cooee_link_skill '${skill}' && cooee_skill_linked demo && echo linked`, {
    HOME: home,
    COOEE_AGENTS: "codex",
  });
  for (const dir of [".claude/skills", ".agents/skills"]) {
    const link = path.join(home, dir, "demo");
    assert.equal(fs.readlinkSync(link), skill, `${dir} should link the skill`);
  }
});

test("a skill dir another installer owns is kept, not linked into", () => {
  const home = tmpdir("cooee-home-");
  const owned = path.join(home, ".agents/skills/demo");
  fs.mkdirSync(owned, { recursive: true });
  fs.writeFileSync(path.join(owned, "SKILL.md"), "theirs\n");
  const out = evalRendered("java", `cooee_link_skill '${fakeSkill()}'`, {
    HOME: home,
    COOEE_AGENTS: "codex",
  });
  assert.match(out, /kept ~\/\.agents\/skills\/demo/);
  assert.equal(fs.lstatSync(owned).isSymbolicLink(), false);
  assert.deepEqual(fs.readdirSync(owned), ["SKILL.md"]);
});

test("a skill missing from one agent's dir is not linked, so the fast path re-provisions", () => {
  const home = tmpdir("cooee-home-");
  const skill = fakeSkill();
  // Linked for Claude only (a box provisioned before Codex arrived)...
  evalRendered("java", `cooee_link_skill '${skill}'`, { HOME: home, COOEE_AGENTS: "none" });
  // ...is not "linked" once Codex is on the box.
  const out = evalRendered("java", "cooee_skill_linked demo && echo yes || echo no", {
    HOME: home,
    COOEE_AGENTS: "codex",
  });
  assert.equal(out, "no");
});

test("the build-brief guide is written to every agent's global rules file", () => {
  const home = tmpdir("cooee-home-");
  evalRendered("java", "cooee_build_brief_guide", {
    HOME: home,
    COOEE_AGENTS: "codex,gemini",
  });
  for (const file of [".claude/CLAUDE.md", ".codex/AGENTS.md", ".gemini/GEMINI.md"]) {
    const md = fs.readFileSync(path.join(home, file), "utf8");
    assert.match(md, /build-brief \.\/gradlew/, `${file} should carry the guide`);
    assert.equal(md.match(/coo\.ee\/env:build-brief:start/g).length, 1);
  }
});

test("a non-empty Codex AGENTS.override.md gets the guide instead of AGENTS.md", () => {
  const home = tmpdir("cooee-home-");
  fs.mkdirSync(path.join(home, ".codex"));
  fs.writeFileSync(path.join(home, ".codex/AGENTS.override.md"), "# mine\n");
  evalRendered("java", "cooee_build_brief_guide", { HOME: home, COOEE_AGENTS: "codex" });
  const md = fs.readFileSync(path.join(home, ".codex/AGENTS.override.md"), "utf8");
  assert.match(md, /^# mine/);
  assert.match(md, /build-brief \.\/gradlew/);
  assert.equal(fs.existsSync(path.join(home, ".codex/AGENTS.md")), false);
});

test("a skill found twice in a repo is listed once, preferring the copy outside plugins/", () => {
  const repo = tmpdir("cooee-repo-");
  for (const dir of ["plugins/bundle/skills/demo", "skills/demo", "skills/other"]) {
    fs.mkdirSync(path.join(repo, dir), { recursive: true });
    fs.writeFileSync(path.join(repo, dir, "SKILL.md"), "");
  }
  const all = evalRendered("java", `cooee_find_skills '${repo}'`, { COOEE_AGENTS: "none" });
  assert.deepEqual(all.split("\n").sort(), [
    path.join(repo, "skills/demo"),
    path.join(repo, "skills/other"),
  ]);
  const one = evalRendered("java", `cooee_find_skills '${repo}' demo`, { COOEE_AGENTS: "none" });
  assert.equal(one, path.join(repo, "skills/demo"));
});

test("Gemini's configured context file name gets the guide, with any of jq, python3 or node", () => {
  // [user settings, system settings, env, files expected besides GEMINI.md]
  const cases = [
    [{ context: { fileName: "CONTEXT.md" } }, null, {}, ["CONTEXT.md"]],
    [{ context: { fileName: ["AGENTS.md", "CONTEXT.md"] } }, null, {}, ["AGENTS.md"]],
    [{ context: { fileName: ["AGENTS.md", "GEMINI.md"] } }, null, {}, []],
    [{ contextFileName: "LEGACY.md" }, null, {}, ["LEGACY.md"]],
    [{ context: { fileName: "../escape.md" } }, null, {}, []],
    [{}, null, {}, []],
    // System settings outrank the user's.
    [{ context: { fileName: "USER.md" } }, { context: { fileName: "SYSTEM.md" } }, {}, ["SYSTEM.md"]],
    // Environment references expand the way Gemini expands them.
    [{ context: { fileName: "${CTX_FILE:-DEFAULT.md}" } }, null, {}, ["DEFAULT.md"]],
    [{ context: { fileName: "${CTX_FILE:-DEFAULT.md}" } }, null, { CTX_FILE: "SET.md" }, ["SET.md"]],
    [{ context: { fileName: "$CTX_FILE" } }, null, {}, []],
    [{ context: { fileName: "pre-$CTX_FILE.md" } }, null, { CTX_FILE: "x" }, []],
  ];
  // Hide the parsers in turn, so each fallback is exercised wherever it exists.
  const hide = (names) =>
    `command() { case "$2" in ${names}) return 1;; esac; builtin command "$@"; }\n`;
  for (const hidden of ["__none__", "jq", "jq|python3"]) {
    for (const [settings, system, env, want] of cases) {
      const home = tmpdir("cooee-home-");
      fs.mkdirSync(path.join(home, ".gemini"));
      fs.writeFileSync(path.join(home, ".gemini/settings.json"), JSON.stringify(settings));
      const systemPath = path.join(home, "system-settings.json");
      if (system) fs.writeFileSync(systemPath, JSON.stringify(system));
      const out = evalRendered("java", `${hide(hidden)}cooee_agent_rules_files`, {
        HOME: home,
        COOEE_AGENTS: "gemini",
        GEMINI_CLI_SYSTEM_SETTINGS_PATH: systemPath,
        CTX_FILE: "",
        ...env,
      });
      assert.deepEqual(
        out.split("\n").slice(1),
        ["GEMINI.md", ...want].map((f) => path.join(home, ".gemini", f)),
        `${JSON.stringify(settings)} / ${JSON.stringify(system)} / ${JSON.stringify(env)} with ${hidden} hidden`,
      );
    }
  }
});

test("a skill an enabled Claude plugin ships is not linked into ~/.claude/skills", () => {
  const home = tmpdir("cooee-home-");
  // A cloned skills repo whose marketplace bundle `bundle` carries `demo`.
  const repo = path.join(home, ".cache/coo-ee/skills/owner-repo");
  for (const dir of ["skills/demo", "plugins/bundle/skills/demo"]) {
    fs.mkdirSync(path.join(repo, dir), { recursive: true });
    fs.writeFileSync(path.join(repo, dir, "SKILL.md"), "");
  }
  const skill = path.join(repo, "skills/demo");
  // Linked by an earlier run, before the plugin was enabled.
  evalRendered("java", `cooee_link_skill '${skill}'`, { HOME: home, COOEE_AGENTS: "codex" });
  assert.ok(fs.lstatSync(path.join(home, ".claude/skills/demo")).isSymbolicLink());

  fs.writeFileSync(
    path.join(home, ".claude/settings.json"),
    JSON.stringify({ enabledPlugins: { "bundle@market": true, "other@market": false } }),
  );
  const out = evalRendered(
    "java",
    `cooee_link_skill '${skill}'; cooee_skill_linked demo && echo linked`,
    { HOME: home, COOEE_AGENTS: "codex" },
  );
  assert.match(out, /comes from an enabled Claude plugin/);
  assert.match(out, /linked$/, "the plugin's copy counts as linked for Claude Code");
  assert.equal(fs.existsSync(path.join(home, ".claude/skills/demo")), false, "the old link is removed");
  assert.equal(fs.readlinkSync(path.join(home, ".agents/skills/demo")), skill, "Codex keeps its copy");
});

test("a disabled plugin, or one that doesn't ship the skill, changes nothing", () => {
  const home = tmpdir("cooee-home-");
  const cache = path.join(home, ".claude/plugins/cache/market/bundle/1.0.0/skills/other");
  fs.mkdirSync(cache, { recursive: true });
  fs.writeFileSync(path.join(cache, "SKILL.md"), "");
  fs.writeFileSync(
    path.join(home, ".claude/settings.json"),
    JSON.stringify({ enabledPlugins: { "bundle@market": true, "off@market": false } }),
  );
  const skill = fakeSkill("demo");
  evalRendered("java", `cooee_link_skill '${skill}'`, { HOME: home, COOEE_AGENTS: "none" });
  assert.equal(fs.readlinkSync(path.join(home, ".claude/skills/demo")), skill);
  // ...while the plugin cache does answer for the skill it ships.
  const out = evalRendered("java", "cooee_claude_plugin_provides other && echo yes || echo no", {
    HOME: home,
    COOEE_AGENTS: "none",
  });
  assert.equal(out, "yes");
});

test("a stale coo.ee link beside an enabled plugin keeps the box off the fast path", () => {
  const home = tmpdir("cooee-home-");
  const repo = path.join(home, ".cache/coo-ee/skills/owner-repo");
  for (const dir of ["skills/demo", "plugins/bundle/skills/demo"]) {
    fs.mkdirSync(path.join(repo, dir), { recursive: true });
    fs.writeFileSync(path.join(repo, dir, "SKILL.md"), "");
  }
  // Provisioned first, plugin enabled afterwards.
  evalRendered("java", `cooee_link_skill '${path.join(repo, "skills/demo")}'`, {
    HOME: home,
    COOEE_AGENTS: "none",
  });
  fs.writeFileSync(
    path.join(home, ".claude/settings.json"),
    JSON.stringify({ enabledPlugins: { "bundle@market": true } }),
  );
  const linked = () =>
    evalRendered("java", "cooee_skill_linked demo && echo yes || echo no", { HOME: home, COOEE_AGENTS: "none" });
  assert.equal(linked(), "no", "the stale link must send the next run down the full path");
  evalRendered("java", `cooee_link_skill '${path.join(repo, "skills/demo")}'`, {
    HOME: home,
    COOEE_AGENTS: "none",
  });
  assert.equal(fs.existsSync(path.join(home, ".claude/skills/demo")), false);
  assert.equal(linked(), "yes");
});

test("a plugin's skills come from its own marketplace's cache", () => {
  const home = tmpdir("cooee-home-");
  // `bundle` is enabled from market-a; only market-b's cache ships `demo`.
  for (const [market, skill] of [["market-a", "other"], ["market-b", "demo"]]) {
    const dir = path.join(home, `.claude/plugins/cache/${market}/bundle/1.0.0/skills/${skill}`);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "SKILL.md"), "");
  }
  fs.writeFileSync(
    path.join(home, ".claude/settings.json"),
    JSON.stringify({ enabledPlugins: { "bundle@market-a": true } }),
  );
  const provides = (name) =>
    evalRendered("java", `cooee_claude_plugin_provides ${name} && echo yes || echo no`, {
      HOME: home,
      COOEE_AGENTS: "none",
    });
  assert.equal(provides("demo"), "no");
  assert.equal(provides("other"), "yes");
});
