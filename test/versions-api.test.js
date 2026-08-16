const { test, afterEach } = require("node:test");
const assert = require("node:assert/strict");

const handler = require("../api/versions");
const originalFetch = global.fetch;

function response() {
  let body = "";
  return {
    statusCode: 0,
    headers: {},
    setHeader(k, v) { this.headers[k.toLowerCase()] = v; },
    end(s) { body = s || ""; },
    json() { return JSON.parse(body); },
  };
}

afterEach(() => {
  handler._private.shardCache.clear();
  global.fetch = originalFetch;
});

test("rejects nested or malformed attributes without fetching", async () => {
  let fetched = false;
  global.fetch = async () => { fetched = true; };
  for (const attr of ["", "nodePackages.prettier", "ripgrep;nope"]) {
    const res = response();
    await handler({ query: { attr } }, res);
    assert.equal(res.statusCode, 400);
  }
  assert.equal(fetched, false);
});

test("returns newest-first live Fast versions from the correct shard", async () => {
  let url = "";
  global.fetch = async (u) => {
    url = u;
    return {
      ok: true,
      async json() {
        return { attrs: { ripgrep: {
          "14.1.1": { ok: 1 },
          "15.2.0": { ok: 1 },
          "12.0.0": { ok: 0 },
          "2.0.0": {},
        } } };
      },
    };
  };
  const res = response();
  await handler({ query: { attr: "ripgrep" } }, res);
  assert.equal(url, "https://nixmultiverse.com/meta/ri.json");
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json().versions, ["15.2.0", "14.1.1", "2.0.0"]);
  assert.match(res.headers["cache-control"], /s-maxage=3600/);
});

test("an unknown top-level attribute returns an empty suggestion list", async () => {
  global.fetch = async () => ({ ok: true, async json() { return { attrs: {} }; } });
  const res = response();
  await handler({ query: { attr: "notapackage" } }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json().versions, []);
});

test("a missing Multiverse shard returns an empty suggestion list", async () => {
  global.fetch = async () => ({ ok: false, status: 404 });
  const res = response();
  await handler({ query: { attr: "zzunlikely" } }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.json().versions, []);
});

test("upstream failures return 502 and are not cached", async () => {
  let calls = 0;
  global.fetch = async () => { calls++; return { ok: false, status: 503 }; };
  for (let i = 0; i < 2; i++) {
    const res = response();
    await handler({ query: { attr: "ripgrep" } }, res);
    assert.equal(res.statusCode, 502);
  }
  assert.equal(calls, 2);
});
