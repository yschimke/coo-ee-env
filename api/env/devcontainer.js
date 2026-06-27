// coo.ee/env — devcontainer renderer (option A: thin)
//
// Emits a `.devcontainer/devcontainer.json` from the same module selection the
// shell renderer (render.js) uses. The "thin" strategy: pick a mainstream base
// image and run the existing `curl … | bash` one-liner as postCreateCommand,
// so every bit of provisioning logic — the Nix/devenv backends, host adoption,
// idempotency/repair — is reused verbatim rather than re-expressed as Docker
// layers. The module list, canonical form, and cache key are unchanged; only
// the output format differs (cf. the `?devenv` backend swap in render.js).
//
// The firewall allowlist is computed from each module's need_host/want_host
// declarations — the same metadata the shell script probes in
// check_preconditions and the picker surfaces — so the generated container
// carries a minimal, correct egress allowlist for whichever mechanism the host
// uses (Claude Code's init-firewall.sh domain list, Codex's
// /etc/codex/allowed_domains.txt, or the Codex cloud / Claude web allowlist UI).
//
// Option B (translate modules into Dockerfile layers / dev container features,
// and bake an enforcing init-firewall.sh) will build on this file; the
// base-image, feature, and allowlist selection live here so B can extend them.

const {
  canonicalize,
  entryToString,
  allowedModules,
  moduleInfo,
} = require("./render");

const ONE_LINER_HOST = "https://env.coo.ee";

// Mainstream base images, chosen by host affinity. codex-universal is the image
// Codex cloud mirrors (and coo.ee already aligns with it via the CODEX_ENV_*
// version selectors); the MS devcontainers base is the neutral default that
// works everywhere the Dev Containers spec is supported.
const BASE_IMAGES = {
  ubuntu: "mcr.microsoft.com/devcontainers/base:ubuntu",
  codex: "ghcr.io/openai/codex-universal:latest",
};

// The maintained Claude Code dev container Feature — installs the CLI onto any
// base image (auto-installing Node if absent), so the generated container is
// immediately usable for the agent workflow this service targets.
const CLAUDE_CODE_FEATURE =
  "ghcr.io/anthropics/devcontainer-features/claude-code:1.0";

function pickBase(base) {
  return BASE_IMAGES[base] || BASE_IMAGES.ubuntu;
}

// Union of every host the selected modules need (to install) or want (for
// builds), deduped and sorted. Single source of truth: the need_host/want_host
// directives parsed out of the fragments by moduleInfo() — the exact list the
// rendered script probes and print_allowlist_help prints. Here it becomes the
// container's egress allowlist.
function allowedDomains(entries) {
  const byName = Object.fromEntries(moduleInfo().map((m) => [m.name, m.hosts]));
  const set = new Set();
  for (const e of entries) {
    const hosts = byName[e.name];
    if (!hosts) continue;
    for (const h of [...hosts.need, ...hosts.want]) set.add(h.host);
  }
  return [...set].sort();
}

function jsonError(status, message, allowed, canonical) {
  return {
    status,
    contentType: "application/json; charset=utf-8",
    canonical,
    devcontainer: null,
    allowedDomains: [],
    body:
      JSON.stringify(
        { error: `coo.ee/env: ${message}`, available: allowed },
        null,
        2,
      ) + "\n",
  };
}

// renderDevcontainer(segment, opts) -> { status, contentType, body, canonical,
//   devcontainer, allowedDomains }
//   opts.base   — "ubuntu" (default) | "codex": base image by host affinity.
//   opts.devenv — when true, the one-liner carries ?devenv (devenv.sh backend),
//                 mirroring render()'s flag so both formats agree.
// Validation mirrors render(): malformed/invalid tokens and unknown modules
// return 400 with the available list, just as JSON instead of a shell comment.
function renderDevcontainer(segment, opts) {
  const o = opts || {};
  const allowed = allowedModules();
  const { entries, errors } = canonicalize(segment);
  const canonical = entries.map(entryToString);

  if (errors.length) {
    return jsonError(400, errors.join("; "), allowed, canonical);
  }
  const unknown = entries
    .filter((e) => e.name !== "base" && !allowed.includes(e.name))
    .map((e) => e.name);
  if (unknown.length) {
    return jsonError(
      400,
      `unknown module(s): ${unknown.join(", ")}`,
      allowed,
      canonical,
    );
  }

  // The one-liner targets the canonical module list (minus the implicit base),
  // so it shares the cache key / x-cooee-modules header the shell endpoint
  // emits and re-derives the same implications. ?devenv rides along when set.
  const requested = canonical.filter((c) => c !== "base");
  const query = o.devenv ? "?devenv" : "";
  const oneLiner = `curl -fsSL ${ONE_LINER_HOST}/${requested.join(",")}${query} | bash`;

  const domains = allowedDomains(entries);

  const devcontainer = {
    name: `coo.ee/env • ${requested.join(",") || "base"}`,
    image: pickBase(o.base),
    features: {
      [CLAUDE_CODE_FEATURE]: {},
    },
    // Reuse the shell provisioner verbatim — option A keeps install logic in one
    // place. postCreateCommand runs once, after the container is created.
    postCreateCommand: oneLiner,
    // Surface the computed egress allowlist. Option A does not yet *enforce* a
    // firewall (that needs --cap-add=NET_ADMIN + an enforcing init-firewall.sh,
    // which is option B); this carries the host list for the platform's network
    // policy and for the provisioner's own runtime host probe.
    containerEnv: {
      COOEE_ALLOWED_DOMAINS: domains.join(","),
    },
  };

  return {
    status: 200,
    contentType: "application/json; charset=utf-8",
    canonical,
    devcontainer,
    allowedDomains: domains,
    body: JSON.stringify(devcontainer, null, 2) + "\n",
  };
}

module.exports = {
  renderDevcontainer,
  allowedDomains,
  BASE_IMAGES,
  CLAUDE_CODE_FEATURE,
};
