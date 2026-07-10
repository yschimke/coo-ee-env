#!/usr/bin/env bash
# ===========================================================================
#  coo.ee/env — composable dev-environment bootstrapper
# ---------------------------------------------------------------------------
#  This is the HEADER fragment. The hosted service concatenates:
#       _header.sh  +  <module>.sh ...  +  _footer.sh
#  to produce the script served at  https://env.coo.ee/<modules>.
#  The checked-in file  java,android  is one such rendering.
#  Edit fragments here; do not hand-edit the rendered artifact.
#  See README.md.
# ===========================================================================
set -euo pipefail

COOEE_VERSION="0.1.0"

# ---- GitHub Actions awareness ---------------------------------------------
# GitHub is just another cloud target, but it has its own log + env protocol.
# Inside a runner we mirror our output into the workflow log: collapsible
# ::group:: sections per module (see _footer) and ::warning::/::error::
# annotations that surface on the run summary. No-op everywhere else.
COOEE_GHA=0
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && COOEE_GHA=1
gha_group()    { [[ $COOEE_GHA == 1 ]] && printf '::group::%s\n' "$*" >&2 || true; }
gha_endgroup() { [[ $COOEE_GHA == 1 ]] && printf '::endgroup::\n'     >&2 || true; }

# ---- logging --------------------------------------------------------------
if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'
  _c_blu=$'\033[34m'; _c_rst=$'\033[0m'
else
  _c_red=; _c_yel=; _c_grn=; _c_blu=; _c_rst=
fi
log()  { printf '%s[coo.ee]%s %s\n'   "$_c_blu" "$_c_rst" "$*" >&2; }
ok()   { printf '%s[coo.ee] OK%s %s\n' "$_c_grn" "$_c_rst" "$*" >&2; }
warn() { printf '%s[coo.ee] !!%s %s\n' "$_c_yel" "$_c_rst" "$*" >&2
         [[ $COOEE_GHA == 1 ]] && printf '::warning::%s\n' "$*" >&2 || true; }
die()  { printf '%s[coo.ee] XX%s %s\n' "$_c_red" "$_c_rst" "$*" >&2
         [[ $COOEE_GHA == 1 ]] && printf '::error::%s\n' "$*" >&2 || true; exit 1; }

# ---- persisted environment ------------------------------------------------
# Everything we export is also written to a profile file so a *new* shell can
# pick it up, and forwarded to the host harness env files when present
# (Claude Code SessionStart: $CLAUDE_ENV_FILE, GitHub Actions: $GITHUB_ENV).
#
# Two files are kept: COOEE_PROFILE is `export KEY=value` (source-able in a
# shell), COOEE_HARNESS_ENV is raw `KEY=value` (the format harness env files
# want). They are truncated lazily — only when we actually (re)provision — so
# the already-provisioned short-circuit can replay the PREVIOUS run's values.
COOEE_PROFILE="${COOEE_PROFILE:-$HOME/.config/coo-ee/env.sh}"
COOEE_HARNESS_ENV="${COOEE_HARNESS_ENV:-$HOME/.config/coo-ee/env.harness}"
mkdir -p "$(dirname "$COOEE_PROFILE")"

cooee_init_profile() { : > "$COOEE_PROFILE"; : > "$COOEE_HARNESS_ENV"; }

# Append a raw KEY=value line to whichever harness env files this run has.
cooee_forward_to_harness() {  # cooee_forward_to_harness KEY=value
  local kv=$1
  [[ -n "${CLAUDE_ENV_FILE:-}" ]] && printf '%s\n' "$kv" >> "$CLAUDE_ENV_FILE" || true
  [[ -n "${GITHUB_ENV:-}"     ]] && printf '%s\n' "$kv" >> "$GITHUB_ENV"     || true
  return 0
}

add_env() {  # add_env KEY VALUE — export now and persist for later shells
  local key=$1 val=$2
  export "${key}=${val}"
  printf 'export %s=%q\n' "$key" "$val" >> "$COOEE_PROFILE"
  printf '%s=%s\n'        "$key" "$val" >> "$COOEE_HARNESS_ENV"
  cooee_forward_to_harness "${key}=${val}"
}

# Short-circuit replay: re-export the last run's env into THIS session without
# reinstalling anything.
cooee_forward_persisted_env() {
  # shellcheck disable=SC1090
  [[ -f "$COOEE_PROFILE" ]] && . "$COOEE_PROFILE" || true
  if [[ -f "$COOEE_HARNESS_ENV" ]]; then
    local line
    while IFS= read -r line; do
      [[ -n "$line" ]] && cooee_forward_to_harness "$line"
    done < "$COOEE_HARNESS_ENV"
  fi
}

# ---- activation: make the env auto-apply without a manual `source` ----------
# Persisting the env to a file isn't enough on its own — a future shell or agent
# session still has to load it. So, as part of a normal run, we wire that up:
#   * append a guarded line to the common shell rc files (every future shell
#     sources the persisted env), and
#   * install/merge a Claude Code SessionStart hook into the *consuming* project
#     so future web sessions re-run this same bootstrap (idempotent, cheap).
# This is generic plumbing for whatever project pulls in coo.ee/env — never tied
# to one repo. GitHub Actions has its own activation ($GITHUB_ENV/$GITHUB_PATH),
# so we skip it there; COOEE_NO_ACTIVATE=1 opts out everywhere.
COOEE_BASE_URL="${COOEE_BASE_URL:-https://env.coo.ee}"

# Rebuild the canonical request segment (modules + their params) so a hook can
# re-run exactly what was asked for, e.g. "java[17,21],android[34]".
cooee_request_segment() {
  local m seg=() p
  for m in "${MODULES[@]}"; do
    [[ "$m" == base ]] && continue
    p="${_MODULE_PARAMS[$m]:-}"
    if [[ -n "$p" ]]; then seg+=("$m[$p]"); else seg+=("$m"); fi
  done
  local IFS=,; printf '%s' "${seg[*]}"
}

# Append a guarded activation block to the usual shell rc files. Idempotent via
# marker lines; touches ~/.zshrc only when zsh is actually in play.
cooee_install_shell_rc() {
  local begin='# >>> coo.ee/env >>>' end='# <<< coo.ee/env <<<'
  local block="${begin}
[ -f \"${COOEE_PROFILE}\" ] && . \"${COOEE_PROFILE}\"
${end}"
  local -a rcs=("$HOME/.bashrc" "$HOME/.profile")
  [[ -f "$HOME/.zshrc" || "${SHELL:-}" == *zsh || -n "${ZSH_VERSION:-}" ]] && rcs+=("$HOME/.zshrc")
  local rc updated=0
  for rc in "${rcs[@]}"; do
    if [[ -f "$rc" ]] && grep -qF "$begin" "$rc" 2>/dev/null; then
      updated=1; continue   # already activated here
    fi
    printf '\n%s\n' "$block" >> "$rc" && { ok "activation: ${rc/#$HOME/\~} now sources the persisted env."; updated=1; }
  done
  (( updated )) || warn "activation: could not update any shell rc file."
}

# Install/merge a SessionStart hook AND the toolchain's permission allowlist
# into the consuming project's .claude/settings.json, so future Claude Code
# sessions auto-provision and aren't prompted for the tools this environment
# just installed (e.g. `Bash(gradle:*)` for java — see provides_perms). Uses
# jq/python3/node to merge an existing file; writes a fresh one otherwise; warns
# (with the snippet) if a file exists but no JSON tool is available.
cooee_install_session_hook() {
  local dir
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then dir="$CLAUDE_PROJECT_DIR"
  elif [[ -d "$PWD/.git" || -d "$PWD/.claude" ]]; then dir="$PWD"
  else warn "activation: no project dir (CLAUDE_PROJECT_DIR unset, $PWD isn't a repo) — skipping SessionStart hook."; return 0; fi

  local seg cmd settings="$dir/.claude/settings.json" perms_json
  seg="$(cooee_request_segment)"
  perms_json="$(cooee_perms_json)"
  # Degrade gracefully: if a future session can't reach the service (offline, or
  # env.coo.ee not on that environment's allowlist), the hook logs and continues
  # rather than failing session startup. The trailing `|| echo` guarantees a 0
  # exit even under `set -o pipefail`, where `curl -f` failing would otherwise
  # propagate through the pipe and abort the session.
  cmd="curl -fsSL ${COOEE_BASE_URL}/${seg} | bash || echo 'coo.ee/env: setup skipped (offline or host not allowlisted)' >&2"

  # Nothing to do if the hook is already wired and every permission rule we'd
  # add is already listed. Checking the raw rule strings keeps this cheap and
  # tool-free (the merge itself dedupes, so a false "missing" only re-merges).
  if [[ -f "$settings" ]] && grep -qF "$cmd" "$settings" 2>/dev/null; then
    local rule missing=0
    while IFS= read -r rule; do
      [[ -z "$rule" ]] && continue
      grep -qF "$rule" "$settings" 2>/dev/null || { missing=1; break; }
    done < <(cooee_collect_perms)
    if (( ! missing )); then
      ok "activation: SessionStart hook + permissions already present in ${settings/#$HOME/\~}."
      return 0
    fi
  fi
  mkdir -p "$dir/.claude"

  if [[ ! -f "$settings" ]]; then
    local perms_block=""
    [[ "$perms_json" != "[]" ]] && perms_block=",
  \"permissions\": { \"allow\": ${perms_json} }"
    cat > "$settings" <<JSON
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "${cmd}" } ] }
    ]
  }${perms_block}
}
JSON
    ok "activation: wrote SessionStart hook + permissions to ${settings/#$HOME/\~}."
    return 0
  fi

  # Merge into the existing settings without clobbering other keys: add the hook
  # only if it isn't already there, and union the permission rules (dedup).
  local add_hook=1
  grep -qF "$cmd" "$settings" 2>/dev/null && add_hook=0
  local tmp; tmp="$(mktemp)"
  if command -v jq >/dev/null 2>&1; then
    if jq --arg c "$cmd" --argjson add_hook "$add_hook" --argjson perms "$perms_json" '
        (if $add_hook == 1 then
           .hooks //= {} | .hooks.SessionStart //= []
           | .hooks.SessionStart += [ { hooks: [ { type: "command", command: $c } ] } ]
         else . end)
        | (if ($perms | length) > 0 then
             .permissions //= {} | .permissions.allow //= []
             | .permissions.allow = (.permissions.allow + $perms | unique)
           else . end)' \
        "$settings" > "$tmp" 2>/dev/null && mv "$tmp" "$settings"; then
      ok "activation: merged SessionStart hook + permissions into ${settings/#$HOME/\~} (jq)."; return 0
    fi
  elif command -v python3 >/dev/null 2>&1; then
    if python3 - "$settings" "$cmd" "$add_hook" "$perms_json" <<'PY' 2>/dev/null
import json, sys
path, cmd, add_hook, perms = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
with open(path) as f: data = json.load(f)
if add_hook == "1":
    hooks = data.setdefault("hooks", {}).setdefault("SessionStart", [])
    hooks.append({"hooks": [{"type": "command", "command": cmd}]})
if perms:
    allow = data.setdefault("permissions", {}).setdefault("allow", [])
    data["permissions"]["allow"] = sorted(set(allow) | set(perms))
with open(path, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
PY
    then ok "activation: merged SessionStart hook + permissions into ${settings/#$HOME/\~} (python3)."; return 0; fi
  elif command -v node >/dev/null 2>&1; then
    if node -e '
        const fs = require("fs"), [p, c, addHook, permsRaw] = process.argv.slice(1);
        const d = JSON.parse(fs.readFileSync(p, "utf8")), perms = JSON.parse(permsRaw);
        if (addHook === "1") {
          (d.hooks ||= {}).SessionStart ||= [];
          d.hooks.SessionStart.push({ hooks: [{ type: "command", command: c }] });
        }
        if (perms.length) {
          (d.permissions ||= {}).allow ||= [];
          d.permissions.allow = [...new Set([...d.permissions.allow, ...perms])].sort();
        }
        fs.writeFileSync(p, JSON.stringify(d, null, 2) + "\n");
      ' "$settings" "$cmd" "$add_hook" "$perms_json" 2>/dev/null; then
      ok "activation: merged SessionStart hook + permissions into ${settings/#$HOME/\~} (node)."; return 0; fi
  fi
  rm -f "$tmp"
  warn "activation: ${settings/#$HOME/\~} exists but no jq/python3/node to merge it safely."
  warn "activation: add this SessionStart hook command manually: ${cmd}"
}

# Run both activation steps unless opted out / on GitHub Actions.
cooee_install_activation() {
  [[ "${COOEE_NO_ACTIVATE:-0}" == 1 ]] && { log "activation: skipped (COOEE_NO_ACTIVATE=1)."; return 0; }
  [[ "$COOEE_GHA" == 1 ]] && { log "activation: GitHub Actions uses \$GITHUB_ENV/\$GITHUB_PATH; skipping shell-rc/hook install."; return 0; }
  cooee_install_shell_rc
  cooee_install_session_hook
}

# ---- privilege helper -----------------------------------------------------
# Run a command as root: directly when already root, via sudo when available,
# otherwise return 127 so the caller can degrade gracefully (warn, not die).
cooee_sudo() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then "$@"
  elif command -v sudo >/dev/null 2>&1; then sudo "$@"
  else return 127; fi
}

# ---- provisioning backend (resolved at render time) -----------------------
# The renderer splices in exactly one backend driver fragment right after this
# header — _backend-nix.sh by default, _backend-devenv.sh for a `?devenv`
# request. Each defines nix_ensure (install a nixpkgs package) plus the
# cooee_backend_* hooks the modules and base call, so there is never a runtime
# `if devenv` branch in the rendered script: only the selected backend's code
# is present. See modules/_backend-*.sh.

# ---- cloud-specific fixes -------------------------------------------------
# Sandboxes (Claude Code, etc.) route HTTPS through a TLS-terminating proxy
# whose CA is trusted in the *system* store. A Nix-provided JDK ships its own
# read-only cacerts and ignores the system store, so Java/Gradle downloads die
# with "PKIX path building failed" right after the JDK lands. Fix: make a
# writable copy of the JDK truststore, import any extra/local CAs, and point
# Java at the copy. No-op on a laptop with no extra CAs.
cooee_extra_ca_files() {
  local f
  for f in /usr/local/share/ca-certificates/*.crt \
           /etc/pki/ca-trust/source/anchors/*.crt \
           "${NODE_EXTRA_CA_CERTS:-}" "${COOEE_EXTRA_CA:-}"; do
    [[ -n "$f" && -f "$f" ]] && printf '%s\n' "$f"
  done
}

cooee_trust_cas_in_jdk() {  # cooee_trust_cas_in_jdk <java_home>
  local java_home=$1
  command -v keytool >/dev/null 2>&1 || { warn "keytool missing; skipping JDK TLS fix."; return 0; }
  local src="$java_home/lib/security/cacerts"
  [[ -f "$src" ]] || { warn "no cacerts under $java_home; skipping JDK TLS fix."; return 0; }

  local -a extra
  mapfile -t extra < <(cooee_extra_ca_files | sort -u)
  if (( ${#extra[@]} == 0 )); then
    log "No extra/proxy CAs detected; JDK default truststore is fine."
    return 0
  fi

  local store="$HOME/.config/coo-ee/cacerts"
  install -m 0644 "$src" "$store"          # writable copy (Nix store path is read-only)
  local n=0 crt
  for crt in "${extra[@]}"; do
    n=$((n+1))
    if keytool -importcert -noprompt -trustcacerts \
         -keystore "$store" -storepass changeit \
         -alias "cooee-extra-$n" -file "$crt" >/dev/null 2>&1; then
      ok "trusted extra CA: $crt"
    else
      warn "could not import CA: $crt"
    fi
  done

  # Append, don't clobber, any JAVA_TOOL_OPTIONS already in the environment.
  # Deliberately a single, space-free option: we point only at the truststore
  # and omit -Djavax.net.ssl.trustStorePassword. The password is needed solely
  # to verify the keystore's integrity hash, not to read its certificates, so a
  # CA truststore loads and is trusted fine without it. Keeping the value to one
  # whitespace-free token means the persisted env line (and any naive consumer
  # that word-splits it) can't break it into a bogus second command — the source
  # of the stray "...trustStorePassword=changeit: command not found" noise.
  local opts="-Djavax.net.ssl.trustStore=$store"
  add_env JAVA_TOOL_OPTIONS "${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }$opts"
  ok "JDK now trusts ${#extra[@]} extra CA(s) via JAVA_TOOL_OPTIONS."
}

# Cloud fix: the JVM ignores the http(s)_proxy env vars that curl honors, so in
# a sandbox where ALL egress is forced through a proxy (Claude Code on the web),
# the Gradle wrapper + daemon die with "UnknownHostException: services.gradle.org"
# even when the host is allowlisted. Translate the proxy env into JVM system
# properties (via JAVA_TOOL_OPTIONS, which every JVM — wrapper, daemon, plain
# java — reads) so Gradle routes through the proxy. No-op when no proxy is set
# (the laptop case), so it's always safe to call.
cooee_jvm_proxy_opts() {
  local proxy="${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}"
  [[ -n "$proxy" ]] || { log "No http(s) proxy in the environment; JVM proxy flags not needed."; return 0; }

  # Parse host:port out of a proxy URL: strip scheme, any user:pass@, any path.
  local hp="${proxy#*://}"; hp="${hp##*@}"; hp="${hp%%/*}"
  local host="${hp%%:*}" port=""
  [[ "$hp" == *:* ]] && port="${hp##*:}"
  [[ -n "$host" ]] || { warn "could not parse proxy host from '$proxy'; skipping JVM proxy flags."; return 0; }

  # Never proxy loopback; carry NO_PROXY through (comma list -> Java's pipe list,
  # leading-dot suffixes -> *. wildcards).
  local nph="localhost|127.0.0.1|[::1]" entry
  local raw="${NO_PROXY:-${no_proxy:-}}"
  if [[ -n "$raw" ]]; then
    local -a parts; IFS=',' read -ra parts <<< "$raw"
    for entry in "${parts[@]}"; do
      entry="${entry//[[:space:]]/}"; [[ -z "$entry" ]] && continue
      [[ "$entry" == .* ]] && entry="*$entry"
      nph="$nph|$entry"
    done
  fi

  local opts="-Dhttp.proxyHost=$host -Dhttps.proxyHost=$host"
  [[ -n "$port" ]] && opts="$opts -Dhttp.proxyPort=$port -Dhttps.proxyPort=$port"
  opts="$opts -Dhttp.nonProxyHosts=$nph"

  # Append to (not clobber) any JAVA_TOOL_OPTIONS already set (e.g. the JDK CA fix).
  add_env JAVA_TOOL_OPTIONS "${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }$opts"
  ok "JVM routed through proxy $host${port:+:$port} (Gradle wrapper/daemon will reach the network)."
}

# Cloud fix: force a UTF-8 locale + JVM file encoding so the JVM and Gradle can
# read/write non-ASCII text. Many sandbox base images boot with a C/POSIX
# (ASCII) locale, which makes the JVM derive sun.jnu.encoding=ANSI_X3.4-1968.
# That's the encoding the JVM uses for *file names*, so the moment Gradle writes
# a report path containing a non-ASCII char (the —/·/× in test/report names) the
# build dies with "Malformed input or input contains unmappable characters" —
# a pure locale artifact, unrelated to the build itself. The two levers:
#   * LANG/LC_ALL -> a UTF-8 locale. This is what actually fixes sun.jnu.encoding
#     (it's read from the native locale at JVM startup; a -Dsun.jnu.encoding flag
#     is NOT honored by HotSpot, so the env var is the only lever that works).
#     C.UTF-8 is chosen because it's always available on glibc without generating
#     a locale, so it's safe in a bare sandbox.
#   * -Dfile.encoding=UTF-8 -> pins the JVM's default charset for stream/reader
#     content too. JDK 18+ already defaults this to UTF-8 (JEP 400), but JDK 17
#     (the Android/AGP toolchain) still follows the locale, so set it explicitly.
# Both are inherited by every JVM that reads JAVA_TOOL_OPTIONS / the process
# locale — the Gradle client, its daemon, and any forked test/worker JVM. A
# deliberate UTF-8 locale already in the environment is left untouched.
cooee_jvm_utf8_opts() {
  case "${LC_ALL:-${LANG:-}}" in
    *[Uu][Tt][Ff]-8 | *[Uu][Tt][Ff]8)
      log "UTF-8 locale already set (${LC_ALL:-$LANG}); leaving LANG/LC_ALL as-is." ;;
    *)
      add_env LANG   C.UTF-8
      add_env LC_ALL C.UTF-8
      ok "Locale set to C.UTF-8 (JVM sun.jnu.encoding + tool I/O now UTF-8)." ;;
  esac

  # Append to (not clobber) any JAVA_TOOL_OPTIONS already set (proxy/CA fixes).
  add_env JAVA_TOOL_OPTIONS "${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Dfile.encoding=UTF-8"
  ok "JVM file.encoding pinned to UTF-8 (Gradle client/daemon/workers)."
}

# ---- build dependency prefetch --------------------------------------------
# Once a language toolchain is ready, optionally warm its build cache by
# resolving the project's dependencies now — while the build/registry hosts are
# still reachable — so a later build (under possibly tighter egress, or none)
# can run from cache. Best-effort: a failure here warns but never fails
# provisioning. The work itself lives in each language module (cooee_prefetch_*),
# which calls these shared helpers; opt out everywhere with COOEE_NO_DEPS=1.

# The consuming project's root: the harness-provided project dir when set,
# otherwise the current directory (where the bootstrap was invoked).
cooee_project_dir() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then printf '%s' "$CLAUDE_PROJECT_DIR"
  else printf '%s' "$PWD"; fi
}

# False when dependency prefetch is opted out (COOEE_NO_DEPS=1). A module's
# prefetch step calls this first and skips quietly when it returns non-zero.
cooee_deps_enabled() { [[ "${COOEE_NO_DEPS:-0}" != 1 ]]; }

# ---- module + host registry ----------------------------------------------
# Modules register themselves (so _footer runs them in order) and declare the
# hosts they need, each with a human reason used in the remediation banner.
MODULES=()
declare -A _HOST_REASON=()   # required to INSTALL — probed, hard-fail if blocked
declare -A _WANT_REASON=()   # recommended for BUILDS — advisory only (may be wildcards)
declare -A _MODULE_PARAMS=() # request params per module (comma-joined), injected by the renderer
register_module() { MODULES+=("$1"); }
# True when <module> is part of this run's requested set (every fragment calls
# register_module at source time, before the footer runs the modules, so this is
# reliable inside a module_* function). Lets a module vary its defaults by what
# else is being installed — e.g. java defaulting differently when android is in.
cooee_module_requested() {  # cooee_module_requested <module>
  local m
  for m in "${MODULES[@]}"; do [[ "$m" == "$1" ]] && return 0; done
  return 1
}
need_host()       { _HOST_REASON["$1"]="$2"; }   # need_host <host> <reason>
want_host()       { _WANT_REASON["$1"]="$2"; }   # want_host <host|*.host> <reason>
set_params()      { _MODULE_PARAMS["$1"]="$2"; } # set_params <module> <comma-joined params>

# ---- provisioning state + cloud built-in awareness ------------------------
# Each module declares the command that proves its tool is ALREADY present (on
# a warm box, or shipped by the cloud provider's base image), and — when a
# provider exposes a first-class version selector — which env var to point the
# user at so they prefer the built-in over a redundant Nix install.
declare -A _PROVIDES_CMD=()     # module -> command that resolves when present
declare -A _BUILTIN_ENVVAR=()   # module -> provider env var that selects it
provides_tool() {               # provides_tool <module> <command> [provider_env_var]
  _PROVIDES_CMD["$1"]="$2"
  [[ -n "${3:-}" ]] && _BUILTIN_ENVVAR["$1"]="$3"
  return 0
}
module_present() {              # module_present <module> -> 0 if its tool is on PATH
  # A module may define cooee_present_<module> for a richer check than "is the
  # command on PATH" — e.g. android adopts an SDK an image shipped on disk but
  # never exported, where `command -v adb` fails yet the SDK is right there.
  if declare -F "cooee_present_$1" >/dev/null 2>&1; then
    "cooee_present_$1"; return
  fi
  local cmd=${_PROVIDES_CMD["$1"]:-}
  [[ -n "$cmd" ]] && command -v "$cmd" >/dev/null 2>&1
}

# ---- Claude Code permission hints -----------------------------------------
# Each module declares the tool-invocation permissions a Claude Code session
# will want pre-approved so the agent isn't prompted for the toolchain the
# environment just installed (e.g. `Bash(gradle:*)` for java). These are folded
# into the project's .claude/settings.json alongside the SessionStart hook (see
# cooee_install_session_hook). The strings are Claude Code permission rules:
# https://docs.claude.com/en/docs/claude-code/settings#permissions
declare -A _PROVIDES_PERMS=()   # module -> newline-separated permission rules
provides_perms() {              # provides_perms <module> <rule> [rule...]
  local m="$1"; shift
  local existing="${_PROVIDES_PERMS["$m"]:-}" rule
  for rule in "$@"; do
    existing+="${existing:+$'\n'}$rule"
  done
  _PROVIDES_PERMS["$m"]="$existing"
  return 0
}

# nixpkgs attribute -> the command name it actually puts on PATH, for the cases
# where they differ. Used to turn a `tools[...]` request into permission rules
# for the binaries it installs. Anything not listed is assumed to match its
# nixpkgs leaf name (jq -> jq, fd -> fd, gh -> gh, nodePackages.prettier ->
# prettier). Keep this to the well-known mismatches — a wrong guess just means
# one extra permission prompt, never a broken rule.
declare -A _TOOL_CMD_ALIAS=(
  [ripgrep]=rg
  [fd-find]=fd
  [the_silver_searcher]=ag
  [neovim]=nvim
)

# Emit the permission rules for the requested modules, one per line, deduped and
# sorted. Static per-module rules come from _PROVIDES_PERMS; the `tools` module
# additionally contributes a rule per binary it was asked to install.
cooee_collect_perms() {
  local m
  {
    for m in "${MODULES[@]}"; do
      [[ -n "${_PROVIDES_PERMS[$m]:-}" ]] && printf '%s\n' "${_PROVIDES_PERMS[$m]}"
      if [[ "$m" == tools && -n "${_MODULE_PARAMS[tools]:-}" ]]; then
        local -a want; local t leaf cmd
        IFS=',' read -r -a want <<< "${_MODULE_PARAMS[tools]}"
        for t in "${want[@]}"; do
          [[ "$t" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || continue
          leaf="${t##*.}"
          cmd="${_TOOL_CMD_ALIAS[$t]:-${_TOOL_CMD_ALIAS[$leaf]:-$leaf}}"
          printf 'Bash(%s:*)\n' "$cmd"
        done
      fi
    done
  } | LC_ALL=C sort -u   # empty input -> sort exits 0 (safe under pipefail)
}

# Render the collected permission rules as a compact JSON array string, e.g.
# ["Bash(gradle:*)","Bash(node:*)"]. Empty rule set renders as [].
cooee_perms_json() {
  local first=1 rule out='['
  while IFS= read -r rule; do
    [[ -z "$rule" ]] && continue
    out+="$( ((first)) || printf ',' )\"${rule//\"/\\\"}\""
    first=0
  done < <(cooee_collect_perms)
  printf '%s]' "$out"
}

# Stamp of the last successfully provisioned module set, used to short-circuit.
COOEE_STAMP="${COOEE_STAMP:-$HOME/.config/coo-ee/provisioned}"

# Detect the hosting agent so we can prefer its built-in toolchains. Codex ships
# a base image whose languages are version-selected via CODEX_ENV_*_VERSION;
# Claude Code / Gemini expose themselves through their own env markers.
COOEE_PROVIDER=unknown
COOEE_PROVIDER_LABEL="this environment"
cooee_detect_provider() {
  if compgen -v 2>/dev/null | grep -q '^CODEX_'; then
    COOEE_PROVIDER=codex;  COOEE_PROVIDER_LABEL="the Codex base image"
  elif [[ -n "${CLAUDECODE:-}" || -n "${CLAUDE_CODE_ENTRYPOINT:-}" || -n "${CLAUDE_ENV_FILE:-}" ]]; then
    COOEE_PROVIDER=claude; COOEE_PROVIDER_LABEL="the Claude Code environment"
  elif [[ -n "${GEMINI_CLI:-}" || -n "${GOOGLE_CLOUD_AGENT:-}" || -n "${ANTIGRAVITY:-}" ]]; then
    COOEE_PROVIDER=gemini; COOEE_PROVIDER_LABEL="the Gemini / Antigravity sandbox"
  fi
}

# ---- preconditions: tools, OS, and host reachability ----------------------
probe_host() {
  # Reachable == we got *any* HTTP response (even 403/404). "000" == the
  # connection itself was blocked (DNS/proxy/TLS), which is the allowlist case.
  local host=$1 code
  code=$(curl -sS -o /dev/null -w '%{http_code}' \
           --connect-timeout 5 --max-time 12 "https://${host}/" 2>/dev/null) || true
  [[ -n "$code" && "$code" != "000" ]]
}

print_allowlist_help() {
  local missing=("$@") h
  {
    echo
    echo "${_c_yel}+- Network not configured -------------------------------------${_c_rst}"
    echo "${_c_yel}|${_c_rst} The sandbox cannot reach the hosts this install needs."
    echo "${_c_yel}|${_c_rst} Add these to your environment's allowed hosts:"
    echo "${_c_yel}|${_c_rst}"
    for h in "${missing[@]}"; do
      printf '%s|%s     %s   %s(%s)%s\n' \
        "$_c_yel" "$_c_rst" "$h" "$_c_yel" "${_HOST_REASON[$h]}" "$_c_rst"
    done
    echo "${_c_yel}|${_c_rst}"
    echo "${_c_yel}|${_c_rst} Where to set it:"
    echo "${_c_yel}|${_c_rst}   - Claude Code on the web: environment -> Network access ->"
    echo "${_c_yel}|${_c_rst}       Custom -> Allowed domains (keep the default package list)."
    echo "${_c_yel}|${_c_rst}   - OpenAI Codex: environment -> Internet access -> On ->"
    echo "${_c_yel}|${_c_rst}       add to the domain allowlist (allow GET/HEAD)."
    echo "${_c_yel}|${_c_rst}   - Antigravity / Gemini Managed Agents: declare the hosts"
    echo "${_c_yel}|${_c_rst}       in the sandbox network allowlist."
    echo "${_c_yel}|${_c_rst}   - GitHub Actions: hosted runners have open egress, so this"
    echo "${_c_yel}|${_c_rst}       rarely fires; on self-hosted/firewalled runners, allow"
    echo "${_c_yel}|${_c_rst}       these in the runner network policy or corporate proxy."
    echo "${_c_yel}+-------------------------------------------------------------${_c_rst}"
    echo
  } >&2
}

check_preconditions() {
  command -v curl >/dev/null 2>&1 || die "curl is required but not installed."
  [[ "$(uname -s)" == "Linux" ]] || warn "Designed for Linux sandboxes; $(uname -s) is untested."

  log "Checking ${#_HOST_REASON[@]} required host(s)..."
  local missing=() h
  for h in "${!_HOST_REASON[@]}"; do
    if probe_host "$h"; then ok "reachable  $h"
    else warn "BLOCKED    $h  (${_HOST_REASON[$h]})"; missing+=("$h"); fi
  done

  if (( ${#missing[@]} )); then
    print_allowlist_help "${missing[@]}"
    if [[ "${COOEE_IGNORE_HOST_CHECK:-0}" == "1" ]]; then
      warn "COOEE_IGNORE_HOST_CHECK=1 set — continuing despite blocked hosts."
    else
      die "${#missing[@]} required host(s) blocked. Fix the allowlist above, or re-run with COOEE_IGNORE_HOST_CHECK=1 to try anyway."
    fi
  else
    ok "All required hosts reachable."
  fi

  print_recommended_hosts   # advisory: build-time hosts, never fatal
}

# Build-time hosts (Gradle/Maven/Android registries, possibly wildcards) are
# not needed to install, so we don't probe them — we just remind you to allow
# them before the project actually builds.
print_recommended_hosts() {
  (( ${#_WANT_REASON[@]} )) || return 0
  local h
  {
    echo
    echo "${_c_blu}i Recommended for builds${_c_rst} — add these too if you'll build the project:"
    for h in "${!_WANT_REASON[@]}"; do
      printf '    %s   %s(%s)%s\n' "$h" "$_c_blu" "${_WANT_REASON[$h]}" "$_c_rst"
    done
    echo
  } >&2
}
