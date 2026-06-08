# `coo.ee/env` — composable environment bootstrapper

A [gitignore.io](https://www.toptal.com/developers/gitignore)-style service for
**dev environments** instead of `.gitignore` files. You ask for a set of
modules in the URL and get back a single `bash` script that installs them:

```bash
curl -fsSL https://env.coo.ee/java,android | bash
```

Like gitignore.io's `/api/java,android`, the path is a comma-separated list of
modules. The service renders a script by concatenating a fixed preamble with
each requested module and streaming the result.

This repo is the standalone home of the service (extracted from
[`yschimke/skills`](https://github.com/yschimke/skills)). The dynamic renderer
is **live** at [`env.coo.ee`](https://env.coo.ee/java,android) (see
[`api/`](./api)). The checked-in [`java,android`](./java,android) is the
**pre-rendered** response for that request, kept as a runnable, offline-friendly
demo:

```bash
# live service (canonical)
curl -fsSL https://env.coo.ee/java,android | bash
# or from a checkout, with no network call to the service
./java,android
```

## What the script does

1. **Checks preconditions first.** Verifies `curl`/OS, then probes every host
   the requested modules need. If any are blocked it prints exactly which
   hosts to allow and where to set them (Claude Code, Codex, Antigravity /
   Gemini Managed Agents), then **stops** — no half-installed environment.
   Override with `COOEE_IGNORE_HOST_CHECK=1` to try anyway.
2. **Installs [Nix](https://determinate.systems/)** (daemonless) as the base.
3. **Installs each module** through Nix: `java` → Temurin JDK 17 + 21,
   `android` → platform-tools + `ANDROID_HOME`.
4. **Persists the environment** to `~/.config/coo-ee/env.sh` and, when running
   inside a harness, to `$CLAUDE_ENV_FILE` / `$GITHUB_ENV`.

### Idempotent by design

Re-running is safe. The base install is skipped when `nix` is already present,
and packages go through `nix_ensure`, which installs only what's missing and
treats an already-present package as success. So a second run is a **no-op**
on a warm box and a **repair** on a cold or partially-broken one.

## Modules

| Module    | Installs                                  | Needs network access to |
| --------- | ----------------------------------------- | ----------------------- |
| `base`    | Nix (Determinate, daemonless)             | `install.determinate.systems`, `cache.nixos.org`, `channels.nixos.org`, `github.com`, `objects.githubusercontent.com` |
| `java`    | Temurin JDK 17 + 21, `JAVA_HOME`          | `cache.nixos.org` |
| `android` | `android-tools` (adb/fastboot), `ANDROID_HOME` | `cache.nixos.org`, `dl.google.com`, `maven.google.com` |

`base` is always included; it is the implicit preamble for every request.

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
curl -fsSL https://env.coo.ee/java,android | bash
```

**Project config / `SessionStart` hook** (`.claude/settings.json`) — runs in
both local and cloud sessions; idempotency keeps it cheap:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "curl -fsSL https://env.coo.ee/java,android | bash" } ] }
    ]
  }
}
```

**GitHub Actions** — GitHub is just another cloud target. The same one-liner
works as a step, and the rendered script is GitHub-aware: it writes
`JAVA_HOME` / `ANDROID_HOME` / `JAVA_TOOL_OPTIONS` to `$GITHUB_ENV` and prepends
the Nix bin dirs to `$GITHUB_PATH`, so the toolchain is on `PATH` for every
later step. Each module is wrapped in a collapsible `::group::` and failures
surface as `::error::` annotations. Use the bundled composite action:

```yaml
- uses: yschimke/coo-ee-env@v1
  with: { modules: java,android }
- run: ./gradlew build          # JAVA_HOME etc. already exported
```

or drop to the raw step (identical effect):

```yaml
- run: curl -fsSL https://env.coo.ee/java,android | bash
```

Hosted runners have open egress, so the host preconditions just pass. To avoid
re-downloading the JDKs/android-tools each run, cache `/nix` keyed on the module
fragments — see [`.github/workflows/env-example.yml`](./.github/workflows/env-example.yml),
which also shows `base.sh` adopting a restored store instead of reinstalling.

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

CI ([`.github/workflows/render.yml`](./.github/workflows/render.yml)) renders
every module set on each push/PR and syntax-checks the output, so a fragment
that breaks `bash -n` never lands.

## Hosting roadmap

- **M1 — hardcoded.** *(done)* The checked-in [`java,android`](./java,android)
  is a pre-rendered artifact. Zero infrastructure; demonstrates the contract.
- **M2 — dynamic renderer.** *(built, see [`api/`](./api))* A Vercel Node
  function parses `/env/:modules`, canonicalizes the list, concatenates the
  `modules/` fragments, and streams `text/x-shellscript`.
- **M3 — domain.** *(done)* Live at `env.coo.ee/<modules>` (see "Domain" below).

## Deploying

The service is deployed on Vercel behind `env.coo.ee`. The wiring is one-time,
account-level, and secret-free (nothing sensitive lives in the repo):

1. **Vercel Git integration** — the repo is imported at
   <https://vercel.com/new>. Push to `main` → production deploy; PRs → preview
   URLs. Vercel auto-detects the `api/` functions and `vercel.json` routes.
2. **Domain** — Vercel project → Settings → Domains → `env.coo.ee`, with DNS
   `CNAME  env -> cname.vercel-dns.com`.

## Domain

`env.coo.ee/<modules>` is the live shape, chosen because:

- **Subdomain, not apex path** — isolates the curl-serving app, gets its own
  Vercel project + TLS, and avoids apex→www redirect chains that break
  `curl | bash`. The apex `coo.ee` stays free for a human landing page.
- **Comma path** is fine (the gitignore.io precedent); order is canonicalized
  server-side so it caches well.
- **Keep the curl path pure** — a bare `curl` prints the script for review; a
  browser (`Accept: text/html`) can show help. HTTPS only.
- **Later:** version pinning (`/java,android@v1`) for reproducible installs.
