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
  const cases = [
    [{ context: { fileName: "CONTEXT.md" } }, "CONTEXT.md"],
    [{ context: { fileName: ["AGENTS.md", "CONTEXT.md"] } }, "AGENTS.md"],
    [{ context: { fileName: ["AGENTS.md", "GEMINI.md"] } }, "GEMINI.md"],
    [{ contextFileName: "LEGACY.md" }, "LEGACY.md"],
    [{ context: { fileName: "../escape.md" } }, "GEMINI.md"],
    [{}, "GEMINI.md"],
  ];
  // Hide the parsers in turn, so each fallback is exercised wherever it exists.
  const hide = (names) =>
    `command() { case "$2" in ${names}) return 1;; esac; builtin command "$@"; }\n`;
  for (const hidden of ["__none__", "jq", "jq|python3"]) {
    for (const [settings, want] of cases) {
      const home = tmpdir("cooee-home-");
      fs.mkdirSync(path.join(home, ".gemini"));
      fs.writeFileSync(path.join(home, ".gemini/settings.json"), JSON.stringify(settings));
      const out = evalRendered("java", `${hide(hidden)}cooee_agent_rules_files`, {
        HOME: home,
        COOEE_AGENTS: "gemini",
      });
      assert.equal(
        out.split("\n")[1],
        path.join(home, ".gemini", want),
        `${JSON.stringify(settings)} with ${hidden} hidden`,
      );
    }
  }
});
