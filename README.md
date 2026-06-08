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
| `skills`  | Claude Code agent skills, linked into `~/.claude/skills/` | `github.com` (`cache.nixos.org` if `git` is absent) |

`base` is always included; it is the implicit preamble for every request.

### Parameterized modules

A module isn't necessarily a Nix package — `skills` is the first **other kind
of dependency**. It clones one or more skill repos and symlinks every skill
(any directory with a `SKILL.md`) into `~/.claude/skills/`. Which repos is a
**request parameter**, given in brackets:

```bash
# default: the skills repo this service was extracted from
curl -fsSL https://coo.ee/env/skills | bash
# explicit source(s), with an optional @ref (branch/tag/sha)
curl -fsSL 'https://coo.ee/env/skills[yschimke/skills]' | bash
curl -fsSL 'https://coo.ee/env/skills[yschimke/skills@v1,owner/more-skills],java' | bash
```

The bracketed list is the module's request-time input. The renderer validates
it (lowercase module names; `[A-Za-z0-9._/@-]` params, so a URL can't inject
shell), dedupes and sorts it, and injects it into the script as
`set_params skills '<owner/repo,...>'`. The shell fragment stays a static
source of truth for *logic* while the renderer supplies the *data*. Re-running
is idempotent: the repo is cached under `~/.cache/coo-ee/skills/` and re-pulled,
and the symlinks are refreshed in place.

## How rendering works

The served script is just a concatenation (plus, for parameterized requests, a
small injected `set_params` block between the header and the modules):

```
_header.sh  +  [set_params ...]  +  base.sh  +  <module>.sh ...  +  _footer.sh
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
Parameterized modules canonicalize the same way: their bracketed params are
deduped and sorted, and a module named twice merges its params, so
`skills[b,a]` and `skills[a,b]` (and `skills[a],skills[b]`) all share one cache
entry. To preview a different combination, pass a different segment to
`render()`.

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
CDN cache entry; bracketed params (`skills[a,b]`) are canonicalized the same
way. Unknown modules — or malformed names/params — return `400` with the
available list.

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
