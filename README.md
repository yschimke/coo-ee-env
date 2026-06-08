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
7. **Activates itself** so the env applies without a manual `source` — see
   [Auto-activation](#auto-activation) below.

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
| `java`    | Temurin JDK (default 17 + 21; `java[17,21]` to choose), `JAVA_HOME` | `cache.nixos.org` | base-image JDK |
| `android` | Full SDK via `androidenv`: `platform-tools` (adb), `cmdline-tools`, the requested platform(s) + `build-tools`, `ANDROID_HOME`; `android[30,37,wear-33]` picks the platform API levels | `cache.nixos.org`, `dl.google.com`, `maven.google.com` | — |
| `android-emulator` | Adds `emulator` + `system-images` to the SDK (via the implied `android` build) and configures `/dev/kvm` access (GitHub `99-kvm4all.rules`); `android-emulator[34,wear-33]` picks the image levels; **implies `android`** | `cache.nixos.org`, `dl.google.com` | — |
| `node`    | Node.js 22 LTS, npm                       | `cache.nixos.org`, `registry.npmjs.org` | Codex: `CODEX_ENV_NODE_VERSION` |
| `python`  | CPython 3 + pip                           | `cache.nixos.org`, `pypi.org`, `files.pythonhosted.org` | Codex: `CODEX_ENV_PYTHON_VERSION` |
| `go`      | Go toolchain, `GOPATH`                    | `cache.nixos.org`, `proxy.golang.org`, `sum.golang.org` | Codex: `CODEX_ENV_GO_VERSION` |
| `rust`    | `rustc` + `cargo`                         | `cache.nixos.org`, `static.crates.io`, `index.crates.io` | Codex: `CODEX_ENV_RUST_VERSION` |
| `ruby`    | Ruby + RubyGems (default 3; `ruby[3.4.9]` to pin) | `cache.nixos.org`, `rubygems.org`, `index.rubygems.org` | Codex: `CODEX_ENV_RUBY_VERSION` |
| `skills`  | Claude Code agent skills, linked into `~/.claude/skills/` | `github.com` (`cache.nixos.org` if `git` is absent) | — |
| `tools`   | Arbitrary CLI tools from nixpkgs, by name (`tools[ripgrep,jq,gh]`) | `cache.nixos.org` | — |

`base` is always included; it is the implicit preamble for every request. The
language modules above install a Nix toolchain (or adopt the provider's
built-in); `skills` and `tools` are different *kinds* of dependency — see below.

### Parameterized modules

A module isn't necessarily a Nix package — `skills` is the first **other kind
of dependency**. It clones one or more skill repos and symlinks every skill
(any directory with a `SKILL.md`) into `~/.claude/skills/`. Which repos is a
**request parameter**, given in brackets:

```bash
# default: the skills repo this service was extracted from
curl -fsSL https://env.coo.ee/skills | bash
# explicit source(s), with an optional @ref (branch/tag/sha)
curl -fsSL 'https://env.coo.ee/skills[yschimke/skills]' | bash
curl -fsSL 'https://env.coo.ee/skills[yschimke/skills@v1,owner/more-skills],java' | bash
```

The bracketed list is the module's request-time input. The renderer validates
it (lowercase module names; `[A-Za-z0-9._/@-]` params, so a URL can't inject
shell), dedupes and sorts it (numerically, so `9 < 17 < 21`), and injects it
into the script as `set_params skills '<owner/repo,...>'`. The shell fragment
stays a static source of truth for *logic* while the renderer supplies the
*data*. Re-running is idempotent: the repo is cached under
`~/.cache/coo-ee/skills/` and re-pulled, and the symlinks are refreshed in place.

The same brackets carry **versions** for the toolchain modules:

```bash
curl -fsSL 'https://env.coo.ee/java[17,21],android[30,37,wear-33]' | bash
```

`java[17,21]` installs each Temurin major (`nixpkgs#temurin-bin-<major>`, lowest
owning the `java`/`javac` symlinks); bare `java` keeps the default 17 + 21.
`android[30,37,wear-33]` installs those platform API levels (with their
`build-tools`), and `android-emulator[34,wear-33]` installs the matching
`emulator` system images — both built into the SDK by `androidenv` (see
[Android: what `android` installs](#android-what-android-installs)). `ruby[3]`
selects the major series (the nixpkgs default Ruby 3) and `ruby[3.4.9]` pins a
full version down to its `ruby_3_4` major.minor attribute. A param-less request
injects nothing, so it renders byte-identically to before parameters existed.

### Module implications

A fragment can declare render-time dependencies with a directive comment —
`# coo.ee:implies <name>` — and the renderer pulls them in (transitively) before
canonicalizing. `android-emulator` implies `android`, so requesting just the
emulator renders as `base,android,android-emulator` (with `android` first, so
its `adb`/`ANDROID_HOME` are ready before the emulator block). Keeping the
declaration in the fragment means a module's full definition lives in one file.

`tools` is the same idea for the long tail of CLIs that don't deserve their own
module — each parameter is a nixpkgs attribute name, installed through the same
idempotent `nix_ensure`:

```bash
curl -fsSL 'https://env.coo.ee/tools[ripgrep,jq,gh]' | bash
# mix with anything else
curl -fsSL 'https://env.coo.ee/tools[ripgrep,jq],node,skills' | bash
```

Nested attributes work too (`tools[nodePackages.prettier]`); an unknown name
just warns and is skipped, so one typo doesn't fail the whole environment.

### Android: what `android` installs

The `android` module installs a **complete, buildable SDK** — `platform-tools`
(`adb`/`fastboot`), `cmdline-tools`, the requested platform(s) and
`build-tools` — using [`nixpkgs`
`androidenv`](https://nixos.org/manual/nixpkgs/stable/#android), and points
`ANDROID_HOME` / `ANDROID_SDK_ROOT` at it. Add `android-emulator` and the same
build also includes the `emulator` and matching `system-images`. So

```bash
curl -fsSL 'https://env.coo.ee/java[21],android[34],android-emulator[34]' | bash
```

leaves you with a JDK, `adb`, the API-34 platform + build-tools, the emulator,
an API-34 system image, and a configured `/dev/kvm` — ready for
`./gradlew assembleDebug` or to boot an AVD, no extra flake step.

**Which versions.** The bracketed params pick the platform API levels
(`android[30,37,wear-33]`); a `wear-NN` level also pulls the `android-wear`
system image. A bare `android` installs one default platform. Two knobs tune the
rest (set them in the environment before running):

| Variable | Default | Selects |
| --- | --- | --- |
| `COOEE_ANDROID_DEFAULT_PLATFORM` | `36` | platform API level for a param-less `android` |
| `COOEE_ANDROID_BUILD_TOOLS` | `36.0.0` | the `build-tools` revision to install |

Because the SDK is built through Nix, it is reproducible and survives
`nix store gc` (the build is anchored by a GC root under `~/.cache/coo-ee/`). On
a box that already has a **complete** SDK (a CI runner, or a warm box with
platforms + build-tools), the module adopts it instead of rebuilding — and only
falls back to a Nix build if an explicitly requested platform is missing. The
recorded `COOEE_ANDROID_PLATFORMS` / `COOEE_ANDROID_EMULATOR_IMAGES` values are
kept as a description of the request.

**Allowlist.** Installing now fetches the SDK components, so beyond
`cache.nixos.org` (the Nix closure) the module needs **`dl.google.com`** (the
platform / build-tools / system-image sources). *Building* the project
additionally wants the registries the module lists under **"Recommended for
builds"** (`maven.google.com`, `packages.jetbrains.team`, `*.jetbrains.com`,
`fonts.googleapis.com`, `fonts.gstatic.com`), plus whatever your Gradle build
resolves from — commonly `services.gradle.org` (the Gradle distribution),
`repo.maven.apache.org` / `repo1.maven.org` (Maven Central), and `jitpack.io`.
The build-time registries are advisory: the script never probes them and never
fails on them, it just reminds you to allow them before `./gradlew build`.

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
| `COOEE_NO_ACTIVATE=1` | Skip [auto-activation](#auto-activation) — don't touch shell rc files or `.claude/settings.json`. |
| `COOEE_BASE_URL` | Service base URL baked into the installed SessionStart hook (default `https://env.coo.ee`). |

The provisioning stamp lives at `~/.config/coo-ee/provisioned` (the canonical
module set); delete it to force the next run to re-probe.

## Auto-activation

Persisting the env to `~/.config/coo-ee/env.sh` doesn't help if nothing loads
it. So a normal run also **wires up activation** for the consuming project — no
manual `source`, no per-project boilerplate:

- **Shell rc.** A guarded block is appended to `~/.bashrc`, `~/.profile` (and
  `~/.zshrc` when zsh is in play) that sources the persisted env, so every
  future shell has the toolchain on `PATH`. The block is fenced by
  `# >>> coo.ee/env >>>` markers and added at most once.
- **Claude Code SessionStart hook.** The script installs (or merges) a
  `SessionStart` hook into the consuming project's `.claude/settings.json` that
  re-runs the *same request* — `curl -fsSL https://env.coo.ee/<your,modules> | bash` —
  so a fresh web session re-provisions automatically. It reconstructs the
  request (modules + params) from the run itself, merges with `jq`/`python3`/
  `node` so existing settings are preserved (and warns with the snippet if none
  is available), and is idempotent — the hook is added at most once. The target
  is `$CLAUDE_PROJECT_DIR`, falling back to the current directory when it's a
  git repo.

This is generic plumbing baked into the bootstrapper, so **any** project that
pulls in coo.ee/env gets it — nothing is specific to one repo. GitHub Actions
has its own activation (`$GITHUB_ENV` / `$GITHUB_PATH`), so the step is skipped
there. Opt out entirely with `COOEE_NO_ACTIVATE=1`.

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

## Recommendations

Given what you've already picked, the service can suggest what to add next —
sibling modules and `tools[...]` bundles that commonly go with your selection:

```bash
# JSON, for tooling / a UI
curl -fsSL https://env.coo.ee/recommend/java
# human-readable, for the terminal
curl -fsSL -H 'Accept: text/plain' https://env.coo.ee/recommend/java
```

```jsonc
{
  "selected": ["base", "java"],
  "recommendations": [
    { "kind": "module", "spec": "android", "score": 5,
      "reasons": ["Android builds run on the JDK you just added."] },
    { "kind": "tools", "spec": "tools[gradle,kotlin]", "score": 3,
      "reasons": ["Gradle + Kotlin are the usual JVM build/CLI companions."] }
    // ... plus the universal CLI kit and agent skills
  ],
  "next": "base,android,java,skills,tools[bat,fd,fzf,gh,gradle,jq,kotlin,ripgrep]"
}
```

Each `spec` is an appendable request, and `next` is the whole selection plus
every suggestion, already canonicalized — so `curl .../$next | bash` just works.
A CI check asserts every recommendation (and `next`) actually renders, so the
service can never suggest something uninstallable.

The rules live in [`api/env/recommend.js`](./api/env/recommend.js) as a static
affinity table (`BASELINE_TOOLS`, per-module `RULES`, `COOCCURRENCE`). The
engine takes the affinities as an argument — `recommend(segment, { knowledge })`
— so the hand-written table can later be swapped for one derived from real
usage (co-occurrence counts from request logs) without touching the scoring.

## Wiring it into an agent environment

Because it is one idempotent line, it drops into either layer:

**Cloud setup script** (Claude Code on the web environment, Codex setup
script) — runs once, result is cached:

```bash
curl -fsSL https://env.coo.ee/java,android | bash
```

**Project config / `SessionStart` hook** (`.claude/settings.json`) — runs in
both local and cloud sessions; idempotency keeps it cheap. You usually don't
write this by hand: the first run [auto-installs](#auto-activation) exactly this
hook into the consuming project. The shape it writes (or merges) is:

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

**GitHub Actions** — GitHub is just another cloud target. Use the bundled
composite action:

```yaml
- uses: yschimke/coo-ee-env@v1
  with: { modules: java,android }
- run: ./gradlew build          # JAVA_HOME etc. already exported
```

or drop to the raw step (identical effect):

```yaml
- run: curl -fsSL https://env.coo.ee/java,android | bash
```

The rendered script is runner-aware: `add_env` forwards `JAVA_HOME` /
`ANDROID_HOME` / `JAVA_TOOL_OPTIONS` to `$GITHUB_ENV`, so the toolchain is on
`PATH` for every later step; each module is wrapped in a collapsible `::group::`
and failures surface as `::error::` annotations. On a non-root runner `base.sh`
brings up the `nix-daemon` so the root-owned store is reachable (see
[Modules](#modules)). [`.github/workflows/env-example.yml`](./.github/workflows/env-example.yml)
is a runnable example — `workflow_dispatch`-only, since the action exercises the
live service rather than a branch's code, so gate per-commit on a local render
instead (as [`setup.yml`](./.github/workflows/setup.yml) does).

Either way, make sure the module hosts above are on your environment's
allowlist — the script tells you precisely which are missing if not. This is
the same allowlist discussed in the `skills` repo's
[`compose-preview/references/agent-cloud.md`](https://github.com/yschimke/skills/blob/main/skills/compose-preview/references/agent-cloud.md).

## The dynamic service

```
modules/                       shell fragments — the single source of truth
api/env/render.js              pure renderer: canonicalize + concatenate (unit-testable)
api/env/[modules].js           Vercel handler wrapping render()
api/env/recommend.js           pure recommender: affinity table + scoring (unit-testable)
api/env/recommend/[modules].js Vercel handler wrapping recommend()
api/modules.js                 JSON module catalog (name + software blurb) for the picker
public/index.html              landing page: autocomplete picker -> the one-liner
vercel.json                    routes /env/:modules, /recommend/:modules, /:modules
java,android                   M1 pre-rendered sample (kept as a runnable demo)
```

`render()` sorts + dedupes modules and always puts `base` first, so
`java,android` and `android,java` produce byte-identical output and share one
CDN cache entry; bracketed params (`skills[a,b]`) are canonicalized the same
way. Unknown modules — or malformed names/params — return `400` with the
available list.

### Landing page (the picker)

Visiting `env.coo.ee/` (no module segment) serves a
[gitignore.io](https://www.toptal.com/developers/gitignore)-style picker
([`public/index.html`](./public/index.html)): type to autocomplete modules, add
them as chips, and copy the generated `curl … | bash` one-liner (or follow
*View script* to read it inline). It builds the command against
`location.origin`, so the copied line works from production, a Vercel preview,
or `vercel dev` alike, and the selection round-trips through the URL hash
(`/#java,android`) so a configuration is shareable.

The picker's module list isn't hardcoded — it fetches
[`/api/modules`](./api/modules.js), which derives the catalog (each module's
name + `software:` blurb) straight from the `modules/` fragment headers. Add or
edit a fragment and the picker updates with no extra wiring. `base` is shown as
a fixed, always-included chip. Static files are matched before the `/:modules`
rewrite, so `/` and `/api/*` resolve to the page and the catalog while
`/java,android` still falls through to the renderer.

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
- **M3 — domain.** *(done)* Live at `env.coo.ee/<modules>` (see "Domain" below).
- **M4 — picker.** *(done)* A landing page at `env.coo.ee/` autocompletes the
  module list and generates the one-liner (see [Landing page](#landing-page-the-picker)).

## Deploying

Deployed on Vercel behind `env.coo.ee`. These were the one-time account-level
steps (no secrets live in the repo), kept here for reference:

1. **Vercel Git integration** — import this repo once at
   <https://vercel.com/new>. Push to `main` → production deploy; PRs → preview
   URLs. Vercel auto-detects the `api/` functions and `vercel.json` routes.
2. **Domain** — Vercel project → Settings → Domains → add `env.coo.ee`, then in
   DNS add `CNAME  env -> cname.vercel-dns.com`.

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
