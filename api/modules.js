// coo.ee/env — module catalog (JSON) for the autocomplete landing page.
//
// The landing page (public/index.html) fetches this to populate its
// autocomplete, so the picker stays in lockstep with the modules/ fragments
// rather than hardcoding its own list. Same source of truth as the renderer.

const { moduleInfo } = require("./env/render");

module.exports = (req, res) => {
  let modules;
  try {
    modules = moduleInfo();
  } catch (err) {
    res.statusCode = 500;
    res.setHeader("content-type", "application/json; charset=utf-8");
    res.end(JSON.stringify({ error: `module catalog error: ${err.message}` }));
    return;
  }

  res.statusCode = 200;
  res.setHeader("content-type", "application/json; charset=utf-8");
  // Catalog only changes when fragments change (i.e. on deploy), so it caches
  // happily at the edge.
  res.setHeader("cache-control", "public, max-age=300, s-maxage=86400");
  res.end(JSON.stringify({ modules }));
};
