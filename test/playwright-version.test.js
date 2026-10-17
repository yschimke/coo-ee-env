const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

test("test and screenshot workflows ship the runner's required Playwright browsers", () => {
  const root = path.resolve(__dirname, "..");
  const version = require("../package.json").devDependencies["@playwright/test"];
  for (const name of ["e2e.yml", "update-screenshots.yml"]) {
    const source = fs.readFileSync(path.join(root, ".github/workflows", name), "utf8");
    const image = source.match(/mcr\.microsoft\.com\/playwright:v([^\s@]+)-noble/);
    assert.ok(image, `${name} must declare the Playwright image`);
    assert.equal(image[1], version, `${name} image must match @playwright/test`);
  }
});
