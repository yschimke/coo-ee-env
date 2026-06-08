// Playwright configuration for the env.coo.ee landing page (public/index.html).
//
// The unit suite (node --test) already owns the pure renderer / recommender;
// Playwright owns the *browser* behavior of the picker UI and its screenshots.
// The app is served by tests/server.js (a faithful local stand-in for the
// Vercel functions) via the webServer block below.

const { defineConfig, devices } = require("@playwright/test");

const PORT = process.env.PORT || 3000;
const baseURL = `http://localhost:${PORT}`;

module.exports = defineConfig({
  testDir: "./tests",
  testMatch: "**/*.spec.js",

  // Deterministic runs: no accidental .only in CI, retry once there to absorb
  // the rare cold-start flake, single worker so screenshots are stable.
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: process.env.CI ? [["html", { open: "never" }], ["list"]] : "list",

  use: {
    baseURL,
    trace: "on-first-retry",
    // Fixed surface so screenshots are reproducible across machines.
    viewport: { width: 1000, height: 900 },
    deviceScaleFactor: 1,
  },

  // Visual-regression knobs. Baselines live in tests/__screenshots__ and are
  // committed; they're generated inside the matching Playwright container (see
  // README "End-to-end tests") so font rendering matches CI exactly. A small
  // tolerance absorbs sub-pixel antialiasing noise without hiding real changes.
  expect: {
    toHaveScreenshot: {
      animations: "disabled",
      caret: "hide",
      maxDiffPixelRatio: 0.01,
    },
  },
  snapshotPathTemplate: "tests/__screenshots__/{arg}{ext}",

  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],

  webServer: {
    command: "node tests/server.js",
    url: baseURL,
    reuseExistingServer: !process.env.CI,
    timeout: 30_000,
  },
});
