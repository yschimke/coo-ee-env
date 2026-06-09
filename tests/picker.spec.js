// Browser tests for the env.coo.ee picker (public/index.html).
//
// Scope: the things only a real browser exercises — the autocomplete, chip
// selection, the live `curl … | bash` one-liner, the host allowlist, clipboard
// copy, and #hash sharing. The pure renderer/recommender stay covered by
// `node --test`; we don't re-test them through the DOM.
//
// Each meaningful state produces two images:
//   • a committed visual-regression baseline  -> expect(...).toHaveScreenshot()
//   • a labeled artifact PNG for docs/review  -> screenshots/<name>.png
// Baselines are generated inside the matching Playwright container so their
// font rendering matches CI (see README "End-to-end tests").

const fs = require("fs");
const path = require("path");
const { test, expect } = require("@playwright/test");

// Labeled, human-facing PNGs (committed as living documentation of the UI).
const SHOTS_DIR = path.join(__dirname, "..", "screenshots");
fs.mkdirSync(SHOTS_DIR, { recursive: true });
const artifact = (name) => path.join(SHOTS_DIR, `${name}.png`);

// Capture both representations of a state in one place.
async function snap(target, name) {
  await expect(target).toHaveScreenshot(`${name}.png`);
  await target.screenshot({ path: artifact(name) });
}

// The picker is ready once /api/modules has populated the catalog: base shows
// as an implicit chip and the command reflects it.
async function gotoApp(page, hash = "") {
  await page.goto(`/${hash}`);
  await expect(page.locator("#chips .chip.implicit", { hasText: "base" })).toBeVisible();
  await expect(page.locator("#cmd-text")).toContainText("| bash");
}

test.describe("env.coo.ee picker", () => {
  test("landing page renders the empty state", async ({ page }) => {
    await gotoApp(page);

    await expect(page).toHaveTitle(/env\.coo\.ee/);
    // Nothing selected => the one-liner provisions just the implicit base.
    await expect(page.locator("#cmd-text")).toHaveText(/curl -fsSL \S+\/base \| bash/);
    // base always declares the Nix hosts, so the allowlist is shown from the start.
    await expect(page.locator("#hosts")).not.toHaveClass(/empty/);
    await expect(page.locator("#host-need li")).not.toHaveCount(0);

    await snap(page, "01-landing");
  });

  test("autocomplete filters as you type", async ({ page }) => {
    await gotoApp(page);

    await page.locator("#search").click();
    await page.locator("#search").fill("java");
    const menu = page.locator("#menu");
    await expect(menu).toHaveClass(/open/);
    await expect(menu.locator(".opt .name", { hasText: "java" })).toBeVisible();
    // The query narrows the list — no unrelated module should remain.
    await expect(menu.locator(".opt .name", { hasText: "rust" })).toHaveCount(0);

    await snap(page, "02-autocomplete");
  });

  test("selecting a module updates chips, command, and hosts", async ({ page }) => {
    await gotoApp(page);

    await page.locator("#search").fill("java");
    await page.locator("#menu .opt", { hasText: "java" }).first().click();

    // Chip appears and the param input lets us pin JDK majors.
    const javaChip = page.locator("#chips .chip", { hasText: "java" });
    await expect(javaChip).toBeVisible();
    await javaChip.locator("input.param").fill("17,21");

    // Bracketed params switch the command to the quoted, globoff form.
    await expect(page.locator("#cmd-text")).toHaveText(/curl -fsSL -g '\S+\/java\[17,21\]' \| bash/);
    // Selecting java reveals the host allowlist.
    await expect(page.locator("#hosts")).not.toHaveClass(/empty/);
    await expect(page.locator("#host-need li")).not.toHaveCount(0);

    await snap(page, "03-java-selected");
  });

  test("hash round-trips a shared selection", async ({ page }) => {
    await gotoApp(page, "#java,node");

    await expect(page.locator("#chips .chip", { hasText: "java" })).toBeVisible();
    await expect(page.locator("#chips .chip", { hasText: "node" })).toBeVisible();
    await expect(page.locator("#cmd-text")).toHaveText(/\/[^ ]*java[^ ]*node|\/[^ ]*node[^ ]*java/);

    await snap(page, "04-shared-hash");
  });

  test("copy button writes the command to the clipboard", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await gotoApp(page);

    await page.locator("#search").fill("node");
    await page.locator("#menu .opt", { hasText: "node" }).first().click();

    const command = await page.locator("#cmd-text").textContent();
    await page.locator("#copy").click();
    await expect(page.locator("#copy")).toHaveText("Copied!");

    const clip = await page.evaluate(() => navigator.clipboard.readText());
    expect(clip).toBe(command);
  });

  test("target selector controls the host copy format", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await gotoApp(page);

    // base alone declares several hosts — enough to tell the formats apart.
    await expect(page.locator("#host-need li").nth(1)).toBeVisible();

    // Codex's domain allowlist wants one comma-separated line.
    await page.locator('#target-select button[data-target="codex"]').click();
    await expect(page.locator('#target-select button[data-target="codex"]'))
      .toHaveAttribute("aria-pressed", "true");
    await page.locator("#copy-hosts").click();
    const codex = await page.evaluate(() => navigator.clipboard.readText());
    expect(codex).toContain(",");
    expect(codex).not.toContain("\n");

    // Claude (and GitHub) keep one host per line.
    await page.locator('#target-select button[data-target="claude"]').click();
    await page.locator("#copy-hosts").click();
    const claude = await page.evaluate(() => navigator.clipboard.readText());
    expect(claude).toContain("\n");
    expect(claude).not.toContain(",");
    // Same hosts, just a different separator.
    expect(claude.split("\n").sort()).toEqual(codex.split(",").sort());
  });

  test("backspace on an empty search removes the last chip", async ({ page }) => {
    await gotoApp(page, "#go,rust");

    await expect(page.locator("#chips .chip", { hasText: "rust" })).toBeVisible();
    await page.locator("#search").click();
    await page.locator("#search").press("Backspace");
    await expect(page.locator("#chips .chip", { hasText: "rust" })).toHaveCount(0);
    await expect(page.locator("#chips .chip", { hasText: "go" })).toBeVisible();
  });

  test("the rendered one-liner actually serves a shell script", async ({ page, request }) => {
    await gotoApp(page, "#java,node");

    // Follow the exact URL the UI puts in the command / "View script" link.
    const href = await page.locator("#view").getAttribute("href");
    const res = await request.get(href, { headers: { accept: "text/x-shellscript" } });
    expect(res.status()).toBe(200);
    expect(res.headers()["content-type"]).toMatch(/shellscript/);
    expect(await res.text()).toContain("#!/usr/bin/env bash");
  });
});
