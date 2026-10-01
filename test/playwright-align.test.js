// Tests for the `playwright` browser view and project alignment: a project that
// pins a different Playwright than the box's browsers were built for gets its
// exact revision downloaded when the CDN allows it, else aliased to the
// nearest Chromium — without the source browser dir ever being written to.
// Driven against a stub playwright-core (its `install --dry-run` / `install`)
// and stub browser trees; no network, no real browser.
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

function exe(file, body = "#!/bin/sh\necho browser\n") {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, body);
  fs.chmodSync(file, 0o755);
}

// An image-style browsers dir (old layout): chromium-<rev>, its headless shell, ffmpeg.
function sourceBrowsers(rev) {
  const src = scratch("pw-src");
  exe(path.join(src, `chromium-${rev}`, "chrome-linux", "chrome"));
  exe(path.join(src, `chromium_headless_shell-${rev}`, "chrome-linux", "headless_shell"));
  fs.mkdirSync(path.join(src, "ffmpeg-1011"));
  for (const d of [`chromium-${rev}`, `chromium_headless_shell-${rev}`]) {
    fs.writeFileSync(path.join(src, d, "INSTALLATION_COMPLETE"), "");
  }
  return src;
}

// A project whose node_modules/playwright-core is version <ver> wanting <rev>.
// `install` succeeds (creating the new-layout dirs) only when canDownload.
function projectWanting(ver, rev, canDownload) {
  const dir = scratch("pw-proj");
  const core = path.join(dir, "node_modules", "playwright-core");
  fs.mkdirSync(core, { recursive: true });
  fs.writeFileSync(path.join(core, "package.json"), JSON.stringify({ name: "playwright-core", version: ver }));
  fs.writeFileSync(path.join(core, "cli.js"), `
const fs = require("fs"), path = require("path");
const root = process.env.PLAYWRIGHT_BROWSERS_PATH;
const dirs = ["chromium-${rev}", "chromium_headless_shell-${rev}", "ffmpeg-1011"];
const args = process.argv.slice(2);
if (args.includes("--dry-run")) {
  for (const d of dirs) console.log("  Install location:    " + path.join(root, d));
  process.exit(0);
}
if (!${canDownload}) { console.error("403 cdn.playwright.dev"); process.exit(1); }
for (const d of dirs.slice(0, 2)) {
  const sub = d.startsWith("chromium-") ? "chrome-linux64/chrome" : "chrome-headless-shell-linux64/chrome-headless-shell";
  fs.mkdirSync(path.dirname(path.join(root, d, sub)), { recursive: true });
  fs.writeFileSync(path.join(root, d, sub), "#!/bin/sh\\necho downloaded\\n", { mode: 0o755 });
  fs.writeFileSync(path.join(root, d, "INSTALLATION_COMPLETE"), "");
}
`);
  return dir;
}

function run(snippet, env = {}, home = scratch("pw-home")) {
  const body = render("playwright,ruby").body.replace(/^main "\$@"$/m, ":");
  const file = path.join(home, "reg.sh");
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  const out = execFileSync("bash", ["-c", `bash "${file}" 2>&1`], {
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      COOEE_PROFILE: path.join(home, "env.sh"),
      COOEE_HARNESS_ENV: path.join(home, "env.harness"),
      CLAUDE_ENV_FILE: "",
      NPM_CONFIG_PREFIX: path.join(home, ".npm-global"),
      ...env,
    },
  }).trim();
  return { out, home, view: path.join(home, ".cache", "coo-ee", "playwright-browsers-view") };
}

const snapshot = (dir) =>
  execFileSync("bash", ["-c", `cd "${dir}" && find . | sort`], { encoding: "utf8" });

test("an existing PLAYWRIGHT_BROWSERS_PATH with a Chromium is adopted", () => {
  const src = sourceBrowsers(1194);
  const { out } = run("cooee_playwright_existing_browsers", { PLAYWRIGHT_BROWSERS_PATH: src });
  assert.equal(out, src);
  const empty = scratch("pw-empty");
  assert.throws(() => run("cooee_playwright_existing_browsers", { PLAYWRIGHT_BROWSERS_PATH: empty }));
});

test("a pinned Playwright whose revision can't be downloaded gets an alias", () => {
  const src = sourceBrowsers(1194);
  const before = snapshot(src);
  const proj = projectWanting("1.60.0", 1223, false);
  const { out, view, home } = run(`cooee_playwright_view_init "${src}"; cooee_playwright_align`, { CLAUDE_PROJECT_DIR: proj });
  assert.match(out, /aliased chromium-1223 -> chromium-1194 for Playwright 1\.60\.0/);
  assert.match(out, /aliased chromium_headless_shell-1223 -> chromium_headless_shell-1194/);
  // both executable layouts resolve to the real source binaries
  for (const [rel, real] of [
    ["chromium-1223/chrome-linux64/chrome", "chromium-1194/chrome-linux/chrome"],
    ["chromium-1223/chrome-linux/chrome", "chromium-1194/chrome-linux/chrome"],
    ["chromium_headless_shell-1223/chrome-headless-shell-linux64/chrome-headless-shell", "chromium_headless_shell-1194/chrome-linux/headless_shell"],
  ]) {
    assert.equal(fs.realpathSync(path.join(view, rel)), fs.realpathSync(path.join(src, real)), rel);
  }
  assert.ok(fs.existsSync(path.join(view, "chromium-1223", "INSTALLATION_COMPLETE")));
  assert.ok(fs.existsSync(path.join(view, "ffmpeg-1011")));
  assert.equal(fs.realpathSync(path.join(view, ".cooee-chrome")), fs.realpathSync(path.join(src, "chromium-1194/chrome-linux/chrome")));
  assert.equal(snapshot(src), before, "the source browser dir is never written to");

  // idempotent: a second pass (the fast path) finds everything in place
  const again = run("cooee_playwright_align", { CLAUDE_PROJECT_DIR: proj }, home);
  assert.doesNotMatch(again.out, /aliased/);
  assert.match(again.out, /Playwright 1\.60\.0 has its browsers/);
});

test("a downloadable revision is fetched beside the view, not aliased", () => {
  const src = sourceBrowsers(1194);
  const proj = projectWanting("1.60.0", 1223, true);
  const { out, view } = run(`cooee_playwright_view_init "${src}"; cooee_playwright_align`, { CLAUDE_PROJECT_DIR: proj });
  assert.match(out, /downloaded chromium-1223 chromium_headless_shell-1223 for Playwright 1\.60\.0/);
  assert.doesNotMatch(out, /aliased/);
  const link = path.join(view, "chromium-1223");
  assert.ok(fs.lstatSync(link).isSymbolicLink(), "linked in from the downloads dir");
  assert.match(fs.realpathSync(link), /playwright-browsers-downloads/);
  assert.ok(fs.existsSync(path.join(view, "chromium-1194")), "the source browsers stay linked");
});

test("a later real download replaces an alias", () => {
  const src = sourceBrowsers(1194);
  const proj = projectWanting("1.60.0", 1223, false);
  const { view } = run(`cooee_playwright_view_init "${src}"; cooee_playwright_align`, { CLAUDE_PROJECT_DIR: proj });
  assert.ok(fs.existsSync(path.join(view, "chromium-1223", ".cooee-alias-of")));
  // A box whose newer source now carries the real 1223.
  const src2 = sourceBrowsers(1223);
  fs.mkdirSync(path.join(src2, "chromium-1223", "chrome-linux64"));
  run(`cooee_playwright_view_init "${src2}"`, {}, path.dirname(path.dirname(path.dirname(view))));
  assert.ok(fs.lstatSync(path.join(view, "chromium-1223")).isSymbolicLink());
  assert.equal(fs.realpathSync(path.join(view, "chromium-1223")), fs.realpathSync(path.join(src2, "chromium-1223")));
});

test("COOEE_PLAYWRIGHT_ALIAS=0 refuses to alias", () => {
  const src = sourceBrowsers(1194);
  const proj = projectWanting("1.60.0", 1223, false);
  const { out, view } = run(`cooee_playwright_view_init "${src}"; cooee_playwright_align`, {
    CLAUDE_PROJECT_DIR: proj, COOEE_PLAYWRIGHT_ALIAS: "0",
  });
  assert.match(out, /COOEE_PLAYWRIGHT_ALIAS=0 forbids aliasing/);
  assert.ok(!fs.existsSync(path.join(view, "chromium-1223")));
});

test("a project without Playwright is left alone", () => {
  const src = sourceBrowsers(1194);
  const { out } = run(`cooee_playwright_view_init "${src}"; cooee_playwright_align; echo done`, {
    CLAUDE_PROJECT_DIR: scratch("pw-none"),
  });
  assert.equal(out, "done");
});

test("alignment re-runs on the already-provisioned fast path", () => {
  const body = render("playwright").body;
  const fast = body.slice(body.indexOf("if cooee_already_provisioned"), body.indexOf("cooee_builtin_pass\n"));
  assert.match(fast, /cooee_playwright_align/);
});
