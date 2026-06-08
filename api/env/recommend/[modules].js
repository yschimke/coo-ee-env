// Vercel Node serverless function for /env/recommend/:modules
//
// Wires the pure recommender to HTTP. The current selection arrives as
// req.query.modules (e.g. "java,android"); the response suggests what to add
// next. JSON by default (for tooling / a UI); a browser or plain-text client
// gets a human-readable list. See ../../../api/env/recommend.js and README.

const { recommend } = require("../recommend");

function toText(out) {
  const lines = [
    `# coo.ee/env — recommendations for: ${out.selected.join(",") || "(nothing yet)"}`,
  ];
  if (!out.recommendations.length) {
    lines.push("# nothing to suggest — you're well equipped.");
  } else {
    for (const r of out.recommendations) {
      lines.push(`#`, `#   ${r.spec}   (score ${r.score})`);
      for (const reason of r.reasons) lines.push(`#     - ${reason}`);
    }
    lines.push(`#`, `# add everything:`, `curl -fsSL https://env.coo.ee/${out.next} | bash`);
  }
  return lines.join("\n") + "\n";
}

module.exports = (req, res) => {
  const seg = req.query && req.query.modules ? req.query.modules : "";
  let out;
  try {
    out = recommend(seg);
  } catch (err) {
    res.statusCode = 500;
    res.setHeader("content-type", "text/plain; charset=utf-8");
    res.end(`# coo.ee/env: recommend error: ${err.message}\n`);
    return;
  }

  const accept = (req.headers && req.headers.accept) || "";
  const wantsText = accept.includes("text/html") || accept.includes("text/plain");

  res.statusCode = 200;
  res.setHeader("content-disposition", "inline");
  res.setHeader("vary", "Accept");
  // Selection is deterministic, so the suggestion caches well at the edge.
  res.setHeader("cache-control", "public, max-age=300, s-maxage=86400");

  if (wantsText) {
    res.setHeader("content-type", "text/plain; charset=utf-8");
    res.end(toText(out));
  } else {
    res.setHeader("content-type", "application/json; charset=utf-8");
    res.end(JSON.stringify(out, null, 2) + "\n");
  }
};
