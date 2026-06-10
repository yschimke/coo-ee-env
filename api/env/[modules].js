// Vercel Node serverless function for /env/:modules
//
// Wires the pure renderer to HTTP. The dynamic segment arrives as
// req.query.modules (e.g. "java,android"). See ../../README.md.

const { render } = require("./render");

// The `?devenv` flag selects the devenv.sh provisioning backend at render time.
// Truthy on presence (?devenv or ?devenv=1); an explicit 0/false/off opts out.
function wantsDevenv(query) {
  if (!query || !("devenv" in query)) return false;
  const v = String(query.devenv).toLowerCase();
  return v !== "0" && v !== "false" && v !== "off";
}

module.exports = (req, res) => {
  const seg = req.query && req.query.modules ? req.query.modules : "";
  let out;
  try {
    out = render(seg, { devenv: wantsDevenv(req.query) });
  } catch (err) {
    res.statusCode = 500;
    res.setHeader("content-type", "text/plain; charset=utf-8");
    res.end(`# coo.ee/env: render error: ${err.message}\n`);
    return;
  }

  res.statusCode = out.status;

  // Content negotiation: a browser (Accept: text/html) gets text/plain so the
  // script renders inline for review instead of downloading; curl and other
  // tools keep the semantically correct text/x-shellscript. Either way
  // Content-Disposition: inline tells the browser not to save-as. Vary: Accept
  // so the CDN caches the two representations separately.
  const accept = (req.headers && req.headers.accept) || "";
  const isBrowser = accept.includes("text/html");
  const contentType =
    out.status === 200 && isBrowser ? "text/plain; charset=utf-8" : out.contentType;

  res.setHeader("content-type", contentType);
  res.setHeader("content-disposition", "inline");
  res.setHeader("vary", "Accept");
  // Canonical form is deterministic, so it caches well at the CDN edge.
  if (out.status === 200) {
    res.setHeader("cache-control", "public, max-age=300, s-maxage=86400");
    res.setHeader("x-cooee-modules", out.canonical.join(","));
  }
  res.end(out.body);
};
