// coo.ee/env — Nix Multiverse Fast version suggestions for the landing page.
//
// Multiverse publishes cache-liveness metadata in two-character shards. Some
// shards are sizeable, so the browser asks this same-origin endpoint for one
// top-level attribute and receives only its live, Fast-installable versions.
// Vercel caches the tiny response at the edge; a warm function also reuses the
// upstream shard promise across attributes with the same prefix.

const MULTIVERSE = "https://nixmultiverse.com";
const ATTR_RE = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;
const shardCache = new Map();
const versionCollator = new Intl.Collator("en", { numeric: true, sensitivity: "base" });

function shardOf(attr) {
  return [...attr.slice(0, 2).toLowerCase()]
    .map((c) => (/[a-z0-9]/.test(c) ? c : "_"))
    .join("") || "_";
}

function loadShard(shard) {
  if (!shardCache.has(shard)) {
    const request = fetch(`${MULTIVERSE}/meta/${shard}.json`)
      .then((r) => {
        // Multiverse deliberately omits empty shards.
        if (r.status === 404) return { attrs: {} };
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .catch((err) => {
        shardCache.delete(shard); // a transient upstream error may recover
        throw err;
      });
    shardCache.set(shard, request);
  }
  return shardCache.get(shard);
}

function json(res, status, body, cache) {
  res.statusCode = status;
  res.setHeader("content-type", "application/json; charset=utf-8");
  res.setHeader("cache-control", cache || "no-store");
  res.end(JSON.stringify(body));
}

module.exports = async (req, res) => {
  const attr = String(req.query?.attr || "").trim();
  if (!ATTR_RE.test(attr)) {
    json(res, 400, { error: "attr must be a top-level nixpkgs attribute" });
    return;
  }

  try {
    const shard = await loadShard(shardOf(attr));
    const entries = shard?.attrs?.[attr] || {};
    // `ok: 0` means the weekly census could no longer fetch that store path.
    // Older metadata without `ok` remains eligible.
    const versions = Object.entries(entries)
      .filter(([, meta]) => !meta || meta.ok !== 0)
      .map(([version]) => version)
      .sort((a, b) => versionCollator.compare(b, a));
    json(
      res,
      200,
      { attribute: attr, versions, source: `${MULTIVERSE}/packages/${encodeURIComponent(attr)}` },
      "public, max-age=300, s-maxage=3600, stale-while-revalidate=86400",
    );
  } catch (err) {
    json(res, 502, { error: `Nix Multiverse lookup failed: ${err.message}` });
  }
};

module.exports._private = { shardOf, shardCache };
