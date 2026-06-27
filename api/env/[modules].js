// Vercel Node serverless function for /env/:modules
//
// Wires the pure renderer to HTTP. The dynamic segment arrives as
// req.query.modules (e.g. "java,android"). See ../../README.md.

const { render } = require("./render");
const { renderDevcontainer } = require("./devcontainer");

// A flag is truthy on presence (?flag or ?flag=1); an explicit 0/false/off
// opts out. Shared by ?devenv and ?devcontainer.
function flagOn(query, name) {
  if (!query || !(name in query)) return false;
  const v = String(query[name]).toLowerCase();
  return v !== "0" && v !== "false" && v !== "off";
}

// The `?devenv` flag selects the devenv.sh provisioning backend at render time.
function wantsDevenv(query) {
  return flagOn(query, "devenv");
}

// `?devcontainer` (or `?format=devcontainer`) switches the output to the
// devcontainer renderer. The module list — and so the canonical form / cache
// key — is unaffected; only the rendered artifact differs, like the backend
// swap above.
function wantsDevcontainer(query) {
  if (flagOn(query, "devcontainer")) return true;
  return String((query && query.format) || "").toLowerCase() === "devcontainer";
}

// Within devcontainer mode, `?devcontainer=json` (alias `=file`) returns the
// raw devcontainer.json; anything else (bare `?devcontainer`,
// `?format=devcontainer`) returns the apply script you pipe to bash.
function devcontainerMode(query) {
  const v = String((query && query.devcontainer) || "").toLowerCase();
  return v === "json" || v === "file" ? "json" : "apply";
}

// Base image for the generated devcontainer, by host affinity. `?base=codex`
// (alias `?image=codex`) targets codex-universal; anything else is the default.
function pickBase(query) {
  const b = String((query && (query.base || query.image)) || "").toLowerCase();
  return b === "codex" ? "codex" : "ubuntu";
}

module.exports = (req, res) => {
  const seg = req.query && req.query.modules ? req.query.modules : "";
  const devenv = wantsDevenv(req.query);
  let out;
  try {
    out = wantsDevcontainer(req.query)
      ? renderDevcontainer(seg, {
          devenv,
          base: pickBase(req.query),
          mode: devcontainerMode(req.query),
        })
      : render(seg, { devenv });
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
