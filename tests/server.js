// Local test server for Playwright — a faithful stand-in for `vercel dev`.
//
// The landing page (public/index.html) is dead on arrival without /api/modules,
// and `vercel dev` needs a Vercel login (no good in CI or an ephemeral box), so
// this tiny server serves public/ and mounts the *real* serverless handlers,
// reproducing the routing from vercel.json. No app logic is duplicated: each
// route just calls the same `(req, res)` export Vercel would, with the dynamic
// path segment placed on req.query.modules exactly as the platform does.
//
// Run standalone:  PORT=3000 node tests/server.js
// (Playwright boots it automatically via the webServer block in the config.)

const http = require("http");
const fs = require("fs");
const path = require("path");

const ROOT = path.join(__dirname, "..");
const PUBLIC = path.join(ROOT, "public");

// The same functions Vercel deploys (api/**). Required once, reused per request.
const modulesHandler = require(path.join(ROOT, "api", "modules.js"));
const renderHandler = require(path.join(ROOT, "api", "env", "[modules].js"));
const recommendHandler = require(path.join(ROOT, "api", "env", "recommend", "[modules].js"));

const STATIC_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".png": "image/png",
  ".json": "application/json; charset=utf-8",
};

function serveStatic(res, file) {
  res.statusCode = 200;
  res.setHeader("content-type", STATIC_TYPES[path.extname(file)] || "application/octet-stream");
  res.end(fs.readFileSync(file));
}

// Hand a dynamic segment to a serverless handler the way Vercel does: the path
// segment lands on req.query.modules, and any real query-string params (e.g.
// ?devenv) are merged in alongside it, exactly as the platform presents them.
function dispatch(handler, modules, req, res, searchParams) {
  req.query = { modules };
  if (searchParams) for (const [k, v] of searchParams) req.query[k] = v;
  return handler(req, res);
}

const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://localhost");
  const p = decodeURIComponent(u.pathname);
  const q = u.searchParams;
  let m;

  // --- /api/* : Vercel routes these straight to the function files. ----------
  if (p === "/api/modules") return modulesHandler(req, res);
  if ((m = p.match(/^\/api\/env\/recommend\/(.+)$/))) return dispatch(recommendHandler, m[1], req, res, q);
  if ((m = p.match(/^\/api\/env\/(.+)$/))) return dispatch(renderHandler, m[1], req, res, q);

  // --- pretty rewrites from vercel.json (recommend before env before bare) ---
  if ((m = p.match(/^\/(?:env\/)?recommend\/(.+)$/))) return dispatch(recommendHandler, m[1], req, res, q);
  if ((m = p.match(/^\/env\/(.+)$/))) return dispatch(renderHandler, m[1], req, res, q);

  // --- static files in public/ ("/" -> index.html) --------------------------
  const rel = p === "/" ? "/index.html" : p;
  const file = path.join(PUBLIC, path.normalize(rel));
  if (file.startsWith(PUBLIC) && fs.existsSync(file) && fs.statSync(file).isFile()) {
    return serveStatic(res, file);
  }

  // --- catch-all: bare /:modules -> render (the curl one-liner / "view" link) -
  if ((m = p.match(/^\/([^/]+)$/))) return dispatch(renderHandler, m[1], req, res, q);

  res.statusCode = 404;
  res.setHeader("content-type", "text/plain; charset=utf-8");
  res.end("not found\n");
});

const PORT = process.env.PORT || 3000;
server.listen(PORT, () => {
  // Playwright's webServer waits for this URL to answer; the log aids debugging.
  console.log(`coo-ee test server listening on http://localhost:${PORT}`);
});
