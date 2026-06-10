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
[`api/`](./api)), rendered on demand from the [`modules/`](./modules) fragments:

```bash
curl -fsSL https://env.coo.ee/java,android | bash
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
| `java`    | Temurin JDK, `JAVA_HOME`; bare `java` uses the JDK the project pins for Gradle (`toolchainVersion` in `gradle/gradle-daemon-jvm.properties`), else 21 (17 + 21 with `android`); `java[17,21]` to choose | `cache.nixos.org` | base-image JDK |
| `android` | Full SDK via `androidenv`: `platform-tools` (adb), `cmdline-tools`, the requested platform(s) + `build-tools`, `ANDROID_HOME`; `android[30,36,wear-33]` picks the platform API levels; **implies `android-cli`** (the Android CLI rides along) | `cache.nixos.org`, `dl.google.com`, `maven.google.com` | — |
| `android-cli` _(hidden)_ | [Google's Android CLI](https://developer.android.com/tools/agents/android-cli) — the agent-first `android` command (scaffold projects, manage AVDs, run Journeys). Downloads the prebuilt binary to `~/.local/bin`, puts it on PATH, and runs `android init` to register its agent skill (opt out with `COOEE_ANDROID_CLI_INIT=0`). Rides along with `android` (which implies it) or installs via its own `/android-cli` one-liner; **not shown in the picker** (it does not pull the Nix SDK back) | `dl.google.com` | — |
| `android-emulator` | Adds `emulator` + `system-images` to the SDK (via the implied `android` build) and configures `/dev/kvm` access (GitHub `99-kvm4all.rules`); `android-emulator[36,wear-33]` picks the image levels; **implies `android`** | `cache.nixos.org`, `dl.google.com` | — |
| `node`    | Node.js 22 LTS, npm                       | `cache.nixos.org`, `registry.npmjs.org` | Codex: `CODEX_ENV_NODE_VERSION` |
| `playwright` | [Playwright agent CLI](https://playwright.dev/agent-cli/introduction) (`@playwright/cli`, the `playwright-cli` binary) via npm + the Playwright browsers from Nix; `playwright[0.1.13]` pins the CLI version; **implies `node`** | `cache.nixos.org`, `registry.npmjs.org` (`cdn.playwright.dev` only with `COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1`) | — |
| `python`  | CPython 3 + pip                           | `cache.nixos.org`, `pypi.org`, `files.pythonhosted.org` | Codex: `CODEX_ENV_PYTHON_VERSION` |
| `go`      | Go toolchain, `GOPATH`                    | `cache.nixos.org`, `proxy.golang.org`, `sum.golang.org` | Codex: `CODEX_ENV_GO_VERSION` |
| `rust`    | `rustc` + `cargo`                         | `cache.nixos.org`, `static.crates.io`, `index.crates.io` | Codex: `CODEX_ENV_RUST_VERSION` |
| `ruby`    | Ruby + RubyGems (default 3; `ruby[3.4.9]` to pin) | `cache.nixos.org`, `rubygems.org`, `index.rubygems.org` | Codex: `CODEX_ENV_RUBY_VERSION` |
| `compose` | Jetpack Compose `@Preview` rendering: installs the `compose-preview` agent skill (renders previews to PNG, no emulator) and pulls in a JDK + the Android SDK; **implies `java`, `android`** | `github.com`, `cache.nixos.org` (git, if absent) | — |
| `skills`  | Claude Code agent skills, linked into `~/.claude/skills/`; `skills[owner/repo]` links every skill in a repo, `skills[owner/repo/<skill>]` links just one | `github.com` (`cache.nixos.org` if `git` is absent) | — |
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
curl -fsSL -g 'https://env.coo.ee/skills[yschimke/skills]' | bash
curl -fsSL -g 'https://env.coo.ee/skills[yschimke/skills@v1,owner/more-skills],java' | bash
# just one skill from a repo: add a path segment after owner/repo
curl -fsSL -g 'https://env.coo.ee/skills[yschimke/skills/compose-preview]' | bash
```

> **Bracketed requests use `-g '...'`.** The single quotes stop the *shell*
> from globbing `[`/`]` before curl runs; `-g` (`--globoff`) stops *curl* from
> reading them as its own URL range/list syntax (without it, `[17,21]` fails
> with `bad range in URL`). Plain requests like `java,android` need neither.

The bracketed list is the module's request-time input. The renderer validates
it (lowercase module names; `[A-Za-z0-9._/@-]` params, so a URL can't inject
shell), dedupes and sorts it (numerically, so `9 < 17 < 21`), and injects it
into the script as `set_params skills '<owner/repo,...>'`. The shell fragment
stays a static source of truth for *logic* while the renderer supplies the
*data*. Re-running is idempotent: the repo is cached under
`~/.cache/coo-ee/skills/` and re-pulled, and the symlinks are refreshed in place.

A repo entry takes an optional **skill selector** — a path segment after
`owner/repo` that links just one skill instead of the whole repo:
`skills[owner/repo/<skill>]` links only the directory named `<skill>` (matched
by name, wherever it lives in the repo), and `@ref` still applies
(`owner/repo/<skill>@v1`). Bare `owner/repo` links every skill, as before.

The same brackets carry **versions** for the toolchain modules:

```bash
curl -fsSL -g 'https://env.coo.ee/java[17,21],android[30,36,wear-33]' | bash
```

`java[17,21]` installs each Temurin major (`nixpkgs#temurin-bin-<major>`, lowest
owning the `java`/`javac` symlinks). With no param, `java` looks for a
**project-specified version marker** before falling back to a built-in default:
it reads the JDK the project pins for its Gradle build — `toolchainVersion` in
the version file in the gradle directory, `gradle/gradle-daemon-jvm.properties`
(the file Gradle's [Daemon JVM
criteria](https://docs.gradle.org/current/userguide/gradle_daemon.html#sec:daemon_jvm_criteria)
reads to choose the daemon's JDK) — so the env provisions exactly what
`./gradlew` will run on. With no such marker it defaults to 21 (the current LTS),
or 17 + 21 when `android` is also being installed (AGP/Gradle pins 17 while app
code targets 21). An explicit `java[…]` always overrides the detection.
`android[30,36,wear-33]` installs those platform API levels (with their
`build-tools`), and `android-emulator[36,wear-33]` installs the matching
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

The `android` SDK implies `android-cli` — [Google's Android CLI](https://developer.android.com/tools/agents/android-cli),
the agent-first `android` command — so any box with the Nix SDK also gets the
CLI on PATH. The implication is one-directional: `android-cli` is a lightweight,
standalone binary download, so `curl -fsSL https://env.coo.ee/android-cli | bash`
installs just the CLI (it manages its own SDK on demand) without building the
heavyweight Nix SDK. Request `android` too when you want both.

`android-cli` is marked `# coo.ee:hidden`, so the picker leaves it off the
top-level module list — it rides along with `android` or installs via its own
one-liner, rather than being chosen on its own. A hidden module still renders
and installs like any other; it's just kept out of the searchable catalog.

`compose` is a **curated target** built on the same mechanism: it implies
`java` and `android` (the JDK + SDK that Compose `@Preview` rendering needs —
but *not* `android-emulator`, which the renderer doesn't use) and installs the
`compose-preview` agent skill, so one word sets up a Compose preview workflow:

```bash
curl -fsSL https://env.coo.ee/compose | bash
```

`tools` is the same idea for the long tail of CLIs that don't deserve their own
module — each parameter is a nixpkgs attribute name, installed through the same
idempotent `nix_ensure`:

```bash
curl -fsSL -g 'https://env.coo.ee/tools[ripgrep,jq,gh]' | bash
# mix with anything else
curl -fsSL -g 'https://env.coo.ee/tools[ripgrep,jq],node,skills' | bash
```

Nested attributes work too (`tools[nodePackages.prettier]`); an unknown name
just warns and is skipped, so one typo doesn't fail the whole environment.

#### Recommended tools

A CLI gets its **own module** only when installing it needs logic beyond a
nixpkgs attribute name — e.g. `playwright` (npm + browsers + env vars). Everything
else is the long tail the `tools` module already covers: pick the nixpkgs
attribute name and request it. The high-demand picks, by job:

| Job | `tools[...]` request | nixpkgs attributes |
| --- | --- | --- |
| **Search / navigate** | `tools[ripgrep,fd,fzf,tree]` | `ripgrep` (rg), `fd`, `fzf`, `tree` |
| **JSON / YAML / data** | `tools[jq,yq,jaq]` | `jq`, `yq` (yq-go), `jaq` |
| **GitHub / git** | `tools[gh,git,lazygit,delta,gitleaks]` | `gh`, `git`, `lazygit`, `delta`, `gitleaks` |
| **HTTP / APIs** | `tools[curl,wget,httpie,websocat]` | `curl`, `wget`, `httpie` (http), `websocat` |
| **Containers / k8s** | `tools[docker-client,kubectl,k9s,kubernetes-helm]` | `docker-client`, `kubectl`, `k9s`, `kubernetes-helm` (helm) |
| **Cloud / IaC** | `tools[awscli2,terraform,opentofu]` | `awscli2` (aws), `terraform`, `opentofu` (tofu) |
| **Build / make** | `tools[just,gnumake,cmake,ninja]` | `just`, `gnumake` (make), `cmake`, `ninja` |
| **Editors / nicer shell** | `tools[neovim,bat,eza,zoxide,direnv]` | `neovim` (nvim), `bat`, `eza`, `zoxide`, `direnv` |
| **JS/TS formatters** | `tools[nodePackages.prettier,nodePackages.pnpm]` | nested `nodePackages.*` |

These are advisory — any other [nixpkgs](https://search.nixos.org/packages)
attribute works the same way. Mix them with anything else, e.g.
`tools[ripgrep,jq,gh],node,playwright`.

### Android: what `android` installs

The `android` module installs a **complete, buildable SDK** — `platform-tools`
(`adb`/`fastboot`), `cmdline-tools`, the requested platform(s) and
`build-tools` — using [`nixpkgs`
`androidenv`](https://nixos.org/manual/nixpkgs/stable/#android), and points
`ANDROID_HOME` / `ANDROID_SDK_ROOT` at it. Add `android-emulator` and the same
build also includes the `emulator` and matching `system-images`. So

```bash
curl -fsSL -g 'https://env.coo.ee/java[21],android[34],android-emulator[34]' | bash
```

leaves you with a JDK, `adb`, the API-34 platform + build-tools, the emulator,
an API-34 system image, and a configured `/dev/kvm` — ready for
`./gradlew assembleDebug` or to boot an AVD, no extra flake step.

**Which versions.** The bracketed params pick the platform API levels
(`android[30,36,wear-33]`); a `wear-NN` level also pulls the `android-wear`
system image. A bare `android` installs one default platform. Two knobs tune the
rest (set them in the environment before running):

| Variable | Default | Selects |
| --- | --- | --- |
| `COOEE_ANDROID_DEFAULT_PLATFORM` | `36` | platform API level for a param-less `android` |
| `COOEE_ANDROID_BUILD_TOOLS` | `36.0.0` | the `build-tools` revision to install |
| `COOEE_ANDROID_NCURSES5_STUB` | `1` | on x86_64, stub the legacy 32-bit `ncurses5` androidenv drags in (set `0` only if you need the 32-bit legacy build-tools on a 32-bit-capable host) |

On x86_64 Linux, `androidenv` always pulls in 32-bit (i686) `glibc`/`zlib`/`ncurses5`
for ancient 32-bit build-tool binaries the modern 64-bit `build-tools` don't use.
The niche `ncurses5` (`ncurses-abi5-compat`) usually isn't in the binary cache, so
Nix *builds* it — and any i686 build runs a 32-bit builder, which fails with
`Exec format error` on kernels without 32-bit x86 support (common in minimal cloud
containers). By default the module swaps in a native empty stub so the SDK build
never needs a 32-bit builder; `COOEE_ANDROID_NCURSES5_STUB=0` restores the real lib.

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

## Playwright

The [`playwright`](https://playwright.dev/agent-cli/introduction) module installs
the **Playwright agent CLI** — the `playwright-cli` tool published as
[`@playwright/cli`](https://www.npmjs.com/package/@playwright/cli) — together with
the browsers it drives:

```bash
curl -fsSL https://env.coo.ee/playwright | bash      # @latest
curl -fsSL -g 'https://env.coo.ee/playwright[0.1.13]' | bash   # pin the CLI version
```

**Is it on Nix?** Two halves, two answers:

- **The CLI is not.** `@playwright/cli` is a young (0.1.x) npm package and isn't
  in nixpkgs, so it can only come from **npm**. That's why the module *implies
  `node`* (the agent CLI needs Node 18+ / npm). To avoid the classic
  `npm install -g` failure where npm's global prefix is the **read-only Nix
  store**, the module points npm at a writable `~/.npm-global` prefix
  (`NPM_CONFIG_PREFIX`) and puts `~/.npm-global/bin` on `PATH`.
- **The browsers are** — `nixpkgs#playwright-driver.browsers` ships
  Chromium/Firefox/WebKit **with their shared-library closure**. The module
  builds that (anchoring a GC root under `~/.cache/coo-ee/` so it survives
  `nix store gc`, exactly like the Android SDK) and exports
  `PLAYWRIGHT_BROWSERS_PATH` at the store path, plus
  `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and
  `PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1`. So **no `apt`/`install-deps`
  step and nothing fetched from the Playwright CDN** — the only install hosts are
  `cache.nixos.org` (browsers) and `registry.npmjs.org` (the CLI).

This split is deliberate: the npm CLI tracks upstream releases, while the heavy,
OS-coupled browser binaries come from Nix where their dependencies are pinned and
cached.

**The version-drift escape hatch.** Playwright expects the browser revisions that
match its bundled core; if the nixpkgs `playwright-driver` revision ever drifts
from the CLI's, set `COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1` to skip the Nix
browsers and let the CLI download its own into `PLAYWRIGHT_BROWSERS_PATH` instead
(this then needs **`cdn.playwright.dev`** on the allowlist and the OS libraries
Playwright's browsers link against). The module also falls back to this path
automatically if the Nix browser build fails.

| Variable | Effect |
| --- | --- |
| `COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1` | Skip the Nix browsers; let `playwright-cli install-browser` download them (needs `cdn.playwright.dev` + OS libraries). |

**Version selection.** The CLI is a *tool an agent runs*, not a dependency a
project locks (that role belongs to `@playwright/test` in the repo's own
`package.json`), so the default is **`@latest`** — like `gh` or `curl`. An
explicit **`playwright[0.1.13]`** pin overrides it, for reproducible installs and
as a second escape hatch when `@latest` ships a core whose browser revision the
nixpkgs driver lacks. The precedence is simply `explicit param > latest`.

> **Lockfile awareness — later.** A third tier — *detect the project's Playwright
> version and align the CLI + browsers to it* — would give CLI↔test parity, but
> it only pays off paired with `COOEE_PLAYWRIGHT_DOWNLOAD_BROWSERS=1`: the pinned
> nixpkgs browser closure can't serve an arbitrary project-pinned revision, so
> matching a lockfile means downloading that revision from the CDN. That's a
> distinct install mode with its own host/OS-dep story, so it's deferred until a
> concrete need rather than built speculatively.

**Agent skills.** The CLI ships optional skills for coding agents
(`playwright-cli install --skills`). Those are per-project, so the module doesn't
run it for you — invoke it inside the repo where you want the skills. (For
*Claude Code* skills, see the [`skills`](#parameterized-modules) module instead.)

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
| `COOEE_NO_DEPS=1` | Skip [build-dependency prefetch](#build-dependency-prefetch) — install the toolchain only, don't resolve the project's dependencies. |
| `COOEE_GRADLE_DEPS_TASK` | Run a specific Gradle task for the prefetch (e.g. `assemble -x test`) instead of the default whole-graph artifact resolution. |
| `COOEE_BASE_URL` | Service base URL baked into the installed SessionStart hook (default `https://env.coo.ee`). |

The [devenv.sh backend](#devenvsh-backend) is selected per request with the
`?devenv` query flag, not an environment variable.

The provisioning stamp lives at `~/.config/coo-ee/provisioned` (the canonical
module set); delete it to force the next run to re-probe.

## devenv.sh backend

By default each module installs its package straight into the default Nix
profile (`nix profile install nixpkgs#…`). Add the `?devenv` query flag and the
server renders the script with the [devenv.sh](https://devenv.sh/) backend
instead:

```bash
curl -fsSL 'https://env.coo.ee/java,node?devenv' | bash
```

The picker exposes this as a **Use devenv.sh** toggle, which appends `?devenv=1`
to the request URL — the module list (and thus the path) is unchanged; only the
backend differs. The choice is resolved **at render time**: the renderer splices
in one of two backend driver fragments (`modules/_backend-nix.sh` or
`modules/_backend-devenv.sh`) right after the header, so the rendered script
carries only the selected backend's code — there is no run-time `if devenv`
branch. Each fragment implements the same contract — `nix_ensure` plus the
`cooee_backend_*` hooks the modules call — so a module fragment never needs to
know which backend it's running under. With the devenv fragment spliced in:

- `base` installs Nix as usual, then its `cooee_backend_setup` hook installs the
  prebuilt `nix profile install nixpkgs#devenv` and seeds a minimal devenv
  project under `~/.config/coo-ee/devenv` (a `devenv.yaml` pinning
  nixpkgs-unstable, plus a git repo).
- Every module's `nix_ensure nixpkgs#<pkg>` appends the attr to a generated
  `devenv.nix` (`packages = [ pkgs.<pkg> … ]`); devenv builds the environment
  and its profile `bin` (the stable `.devenv/profile` symlink) is prepended to
  `PATH`, now and in the persisted env, so tools resolve exactly as the
  Nix-profile backend's do.

We write a real `devenv.nix` rather than using devenv's newer ad-hoc
`--option packages:pkgs` flag, so it works on any devenv version and avoids the
fresh-directory edge cases ad-hoc invocations hit.

Everything else — adoption of already-present tools, host preflight, env
persistence, [auto-activation](#auto-activation), and
[build-dependency prefetch](#build-dependency-prefetch) — is unchanged.
Modules that build a derivation directly (the Android SDK, Playwright browsers)
still use `nix build`, since Nix is present either way. devenv builds resolve
faster when its binary cache (`devenv.cachix.org`) is reachable, but fall back
to building from `cache.nixos.org`, which is already required.

An end-to-end CI job (`.github/workflows/devenv.yml`) keeps this honest: it
renders a `go,java[17,21],node?devenv` script and runs it on a clean runner —
installing Nix, installing devenv, generating `devenv.nix`, building the
environment — then asserts the three tools resolve from the devenv profile, the
JDK collapse fired, the npm build-dependency prefetch ran against the
devenv-provided node, and a re-run short-circuits.

**Limitations.** A single devenv profile is one `buildEnv`, so it can't hold two
JDKs at once (the per-install `--priority` the nix-profile backend uses isn't
available): a multi-version request like `java[17,21]` — including the
`java`+`android` default of `17,21` — falls back to the first major with a
warning.

## Build-dependency prefetch

Installing the toolchain is only half the job — the first real build still has
to download the project's dependencies, and in a sandbox that's exactly when
egress may be locked down. So once a language module finishes, it **warms the
build cache** while the registries are still reachable:

- **`java`** resolves every resolvable configuration's *files* across all
  projects (via a transient init script), so the dependency **artifacts** — not
  just the metadata that the `dependencies` report task alone fetches — land in
  the Gradle cache, along with the Gradle distribution and plugins, without
  compiling. It prefers the project's `./gradlew` (pinned version) over any
  system `gradle`. Set `COOEE_GRADLE_DEPS_TASK` to run a specific task instead
  (e.g. `assemble -x test`).
- **`node`** runs `npm ci` when there's a clean lockfile (falling back to
  `npm install`), otherwise `npm install`.

The step targets the consuming project (`$CLAUDE_PROJECT_DIR`, else the current
directory) and is a no-op when there's no Gradle build / `package.json` there.
It is **best-effort**: a failure (e.g. a registry host that isn't allowlisted)
warns but never fails provisioning, since the toolchain itself is already in
place. Opt out entirely with `COOEE_NO_DEPS=1`.

The trivial Gradle project under [`examples/gradle-sample/`](examples/gradle-sample)
exercises this end-to-end: the [`prefetch`](.github/workflows/prefetch.yml)
workflow renders the `java` module, runs it against the sample, and asserts the
dependency JAR is downloaded into the Gradle cache (and that `COOEE_NO_DEPS=1`
skips it).

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
source of truth. [`api/env/render.js`](./api/env/render.js) is the renderer the
live service goes through, so there is only one way to produce a script. To
render a module set locally and syntax-check it after editing the fragments:

```bash
node -e 'process.stdout.write(require("./api/env/render").render("java,android").body)' | bash -n -
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

Below the one-liner the picker shows the **required hosts** for the current
selection — the union of every active module's `need_host` declarations
(`base` plus your picks plus anything they imply), deduped and each with the
reason it's needed. A small **target** toggle (Claude / Codex / GitHub) tailors
the guidance and the copy format to the environment you're configuring: *Copy
hosts* drops the bare hostnames straight into the chosen target's allowlist —
newline-separated for Claude Code (Network access → Custom → Allowed domains)
and GitHub Actions egress policies, or comma-separated for Codex's domain
allowlist, which wants a single CSV line. The choice is remembered across
visits. A collapsible *Recommended for builds* list adds the `want_host`
entries — the registries a build needs but the install doesn't — with a *Copy
all* for the full set. This is the same host set the rendered script probes and
prints on a blocked install, surfaced up front so you can configure egress
before the first run.

The picker's module list isn't hardcoded — it fetches
[`/api/modules`](./api/modules.js), which derives the catalog (each module's
name + `software:` blurb, the params it takes, what it implies, and its
`need_host`/`want_host` set) straight from the `modules/` fragments. Add or
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

## Tests

Two complementary suites, mirrored by two CI workflows:

- **Renderer unit tests** ([`test/`](./test), `node --test`, run by
  [`render.yml`](./.github/workflows/render.yml)) — the pure
  renderer/recommender: canonicalization, params, implications, recommendations.
  No browser, no network.
- **End-to-end tests** ([`tests/`](./tests),
  [`@playwright/test`](https://playwright.dev/), run by
  [`e2e.yml`](./.github/workflows/e2e.yml)) — the browser behaviour of the
  landing-page picker (`public/index.html`): autocomplete, chip selection, the
  live `curl … | bash` one-liner, the host allowlist, clipboard copy, and
  `#hash` sharing, plus committed screenshot baselines.

```bash
npm test            # renderer unit tests (node --test)
npm run test:e2e    # Playwright UI tests + screenshot comparison
npm run serve       # serve the app locally on :3000 (the picker + /api/*)
```

`tests/server.js` is a tiny stand-in for `vercel dev` (which needs a Vercel
login): it serves `public/` and mounts the real `api/**` handlers with the same
routing as `vercel.json`, so the picker behaves identically with no account or
secrets. Playwright boots it automatically via the `webServer` block in
[`playwright.config.js`](./playwright.config.js).

**Screenshots.** Each meaningful state yields two images: a committed
visual-regression baseline in
[`tests/__screenshots__/`](./tests/__screenshots__) (compared on every run, so a
UI change that alters pixels fails CI) and a labelled artifact PNG in
[`screenshots/`](./screenshots) (living documentation of the UI). Because
baselines are font/OS-sensitive, both the CI job and the baselines run **inside
the matching Playwright container** (`mcr.microsoft.com/playwright:v<version>`)
so rendering is identical. Regenerate them the same way after an intentional UI
change:

```bash
docker run --rm --ipc=host --network=host -v "$PWD":/work -w /work \
  mcr.microsoft.com/playwright:v1.60.0-noble npm run test:e2e:update
```

## Hosting roadmap

- **M1 — hardcoded.** *(superseded by M2)* Began as a single checked-in
  pre-rendered `java,android` artifact — zero infrastructure, demonstrating the
  contract — now removed in favour of the renderer below.
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
