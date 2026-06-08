# `coo.ee/env` — composable environment bootstrapper (simulation)

A [gitignore.io](https://www.toptal.com/developers/gitignore)-style service for
**dev environments** instead of `.gitignore` files. You ask for a set of
modules in the URL and get back a single `bash` script that installs them:

```bash
curl -fsSL https://coo.ee/env/java,android | bash
```

Like gitignore.io's `/api/java,android`, the path after `/env/` is a
comma-separated list of modules. The service renders a script by concatenating
a fixed preamble with each requested module and streaming the result.

This repo is the standalone home of the service (extracted from
[`yschimke/skills`](https://github.com/yschimke/skills)). The dynamic renderer
is **built** (see [`api/`](./api)); it is **not yet wired to a public domain**,
so `coo.ee/env/...` is still a simulation until the domain is live (see
[Deploying](#deploying)). The checked-in [`java,android`](./java,android) is the
**pre-rendered** response for that request, so you can see and run the idea
today:

```bash
# from a checkout (the file lives at the repo root)
./java,android
# or, the shape the real service would take
curl -fsSL https://raw.githubusercontent.com/yschimke/coo-ee-env/main/java,android | bash
```

## What the script does

1. **Short-circuits if already provisioned.** If a previous run installed
   exactly this module set and every tool is still on `PATH`, it re-exports the
   saved environment and exits — no network, no Nix. `COOEE_FORCE=1` forces a
   re-provision.
2. **Prefers the cloud provider's built-ins.** It detects the host (Claude
   Code, Codex, Gemini/Antigravity) and, for each module whose tool is already
   present, **adopts** it instead of installing a redundant copy. On Codex —
   whose base image version-selects languages via `CODEX_ENV_*_VERSION` — it
   warns you to set that variable rather than install through Nix. See
   [Cloud built-ins](#cloud-built-ins--short-circuit).
3. **Checks preconditions.** When something does need installing, it verifies
   `curl`/OS and probes every host the to-be-installed modules need. If any are
   blocked it prints exactly which hosts to allow and where (Claude Code,
   Codex, Antigravity / Gemini), then **stops** — no half-installed
   environment. Override with `COOEE_IGNORE_HOST_CHECK=1`.
4. **Installs [Nix](https://determinate.systems/)** as the base — only if at
   least one module actually needs to install. Daemonless when running as root
   (the usual agent sandbox); when run non-root (e.g. a CI runner) it brings up
   the `nix-daemon` (via systemd when present, otherwise started directly) so
   the root-owned store is reachable.
5. **Installs each remaining module** through Nix (e.g. `java` → Temurin JDK
   17 + 21, `node` → Node.js 22).
6. **Persists the environment** to `~/.config/coo-ee/env.sh` and, when running
   inside a harness, to `$CLAUDE_ENV_FILE` / `$GITHUB_ENV`.

### Idempotent by design

Re-running is safe and cheap. A warm box hits the short-circuit and is a pure
**no-op**; otherwise the base install is skipped when `nix` is already present,
and packages go through `nix_ensure`, which installs only what's missing and
treats an already-present package as success — so a partial/cold box is
**repaired**.

## Modules

| Module    | Installs                                  | Needs network access to | Cloud built-in selector |
| --------- | ----------------------------------------- | ----------------------- | ----------------------- |
| `base`    | Nix (Determinate, daemonless)             | `install.determinate.systems`, `cache.nixos.org`, `channels.nixos.org`, `github.com`, `objects.githubusercontent.com` | — |
| `java`    | Temurin JDK 17 + 21, `JAVA_HOME`          | `cache.nixos.org` | base-image JDK |
| `android` | `android-tools` (adb/fastboot), `ANDROID_HOME` | `cache.nixos.org`, `dl.google.com`, `maven.google.com` | — |
| `node`    | Node.js 22 LTS, npm                       | `cache.nixos.org`, `registry.npmjs.org` | Codex: `CODEX_ENV_NODE_VERSION` |
| `python`  | CPython 3 + pip                           | `cache.nixos.org`, `pypi.org`, `files.pythonhosted.org` | Codex: `CODEX_ENV_PYTHON_VERSION` |
| `go`      | Go toolchain, `GOPATH`                    | `cache.nixos.org`, `proxy.golang.org`, `sum.golang.org` | Codex: `CODEX_ENV_GO_VERSION` |
| `rust`    | `rustc` + `cargo`                         | `cache.nixos.org`, `static.crates.io`, `index.crates.io` | Codex: `CODEX_ENV_RUST_VERSION` |

`base` is always included; it is the implicit preamble for every request.

## Cloud built-ins & short-circuit

In a hosted agent environment the cheapest install is the one you skip. The
script is built around two ideas:

- **Adopt, don't duplicate.** Every language module first checks whether its
  tool is already on `PATH` (a warm box, or shipped by the provider's base
  image). If so it *adopts* the existing tool — sets `JAVA_HOME` / `GOPATH` /
  etc. from it — and skips the Nix install. If nothing is left to install, even
  Nix (`base`) and the host preflight are skipped, so the whole run is offline.
- **Prefer the provider's selector.** [Codex](https://chatgpt.com/codex) ships
  a base image whose languages are chosen via `CODEX_ENV_*_VERSION`. When you
  request a module Codex could provide but the tool isn't present, the script
  **warns** you to set that variable instead of installing a parallel copy via
  Nix. Claude Code and Gemini expose their tools directly on `PATH`, so there
  the adopt path covers it.

Knobs:

| Variable | Effect |
| --- | --- |
| `COOEE_FORCE=1` | Ignore the short-circuit and adoption; force a fresh Nix install / repair. |
| `COOEE_IGNORE_HOST_CHECK=1` | Continue even if a required install host is blocked. |

The provisioning stamp lives at `~/.config/coo-ee/provisioned` (the canonical
module set); delete it to force the next run to re-probe.

## How rendering works

The served script is just a concatenation:

```
_header.sh  +  base.sh  +  <module>.sh ...  +  _footer.sh
```

The [`modules/`](./modules) directory holds the source fragments — the single
source of truth. [`api/env/render.js`](./api/env/render.js) is the renderer that
both the live service and the checked-in artifact go through, so there is only
one way to produce a script. To re-render the checked-in artifact after editing
the fragments:

```bash
node -e 'process.stdout.write(require("./api/env/render").render("java,android").body)' > 'java,android'
bash -n 'java,android'   # syntax check
```

`render()` canonicalizes the module list — it dedupes, forces `base` first, and
sorts the rest alphabetically — so `java,android` and `android,java` render
byte-identically (the `android` block comes before the `java` block in both).
To preview a different combination, pass a different segment to `render()`.

## Wiring it into an agent environment

Because it is one idempotent line, it drops into either layer:

**Cloud setup script** (Claude Code on the web environment, Codex setup
script) — runs once, result is cached:

```bash
curl -fsSL https://coo.ee/env/java,android | bash
```

**Project config / `SessionStart` hook** (`.claude/settings.json`) — runs in
both local and cloud sessions; idempotency keeps it cheap:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "curl -fsSL https://coo.ee/env/java,android | bash" } ] }
    ]
  }
}
```

Either way, make sure the module hosts above are on your environment's
allowlist — the script tells you precisely which are missing if not. This is
the same allowlist discussed in the `skills` repo's
[`compose-preview/references/agent-cloud.md`](https://github.com/yschimke/skills/blob/main/skills/compose-preview/references/agent-cloud.md).

## The dynamic service

```
modules/              shell fragments — the single source of truth
api/env/render.js     pure renderer: canonicalize + concatenate (unit-testable)
api/env/[modules].js  Vercel handler wrapping render()
vercel.json           routes /env/:modules and /:modules -> the function
java,android          M1 pre-rendered sample (kept as a runnable demo)
```

`render()` sorts + dedupes modules and always puts `base` first, so
`java,android` and `android,java` produce byte-identical output and share one
CDN cache entry. Unknown modules return `400` with the available list.

**Run it locally:**

```bash
node -e 'process.stdout.write(require("./api/env/render").render("java,android").body)' | bash -n -
npx vercel dev        # serves http://localhost:3000/env/java,android
```

CI runs two checks on each push/PR:

- [`render.yml`](./.github/workflows/render.yml) renders every module set and
  syntax-checks the output, so a fragment that breaks `bash -n` never lands.
- [`setup.yml`](./.github/workflows/setup.yml) renders `android,java` and
  actually runs it on a clean runner, then asserts `java`, `adb`, and `nix`
  work from the persisted profile and that a second run is a no-op — an
  end-to-end check that the setup really installs a usable environment.

## Hosting roadmap

- **M1 — hardcoded.** *(done)* The checked-in [`java,android`](./java,android)
  is a pre-rendered artifact. Zero infrastructure; demonstrates the contract.
- **M2 — dynamic renderer.** *(built, see [`api/`](./api))* A Vercel Node
  function parses `/env/:modules`, canonicalizes the list, concatenates the
  `modules/` fragments, and streams `text/x-shellscript`.
- **M3 — domain.** *(pending)* `env.coo.ee/<modules>` (see "Domain" below).

## Deploying

The code is push-ready; what remains is wiring it to Vercel and a domain. These
are one-time account-level steps (no secrets live in the repo):

1. **Vercel Git integration** — import this repo once at
   <https://vercel.com/new>. Push to `main` → production deploy; PRs → preview
   URLs. Vercel auto-detects the `api/` functions and `vercel.json` routes.
2. **Domain** — Vercel project → Settings → Domains → add `env.coo.ee`, then in
   DNS add `CNAME  env -> cname.vercel-dns.com`.

After the domain is live, drop the simulation caveat above and the
`0.1.0-sim` version marker in [`modules/_header.sh`](./modules/_header.sh).

## Domain

`env.coo.ee/<modules>` is the recommended shape:

- **Subdomain, not apex path** — isolates the curl-serving app, gets its own
  Vercel project + TLS, and avoids apex→www redirect chains that break
  `curl | bash`. Keep the apex `coo.ee` for a human landing page.
- **Comma path** is fine (the gitignore.io precedent); order is canonicalized
  server-side so it caches well.
- **Renders inline in a browser** — the handler negotiates on `Accept`: a
  browser (`Accept: text/html`) gets `text/plain` so the script displays in the
  tab for review instead of downloading, while `curl` and other tools get the
  semantically correct `text/x-shellscript`. Both send
  `Content-Disposition: inline` (no save-as), and `Vary: Accept` keeps the two
  representations cached separately. HTTPS only.
- **Later:** version pinning (`/java,android@v1`) for reproducible installs.

## License

[Apache License 2.0](./LICENSE).
