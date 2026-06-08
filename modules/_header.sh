#!/usr/bin/env bash
# ===========================================================================
#  coo.ee/env — composable dev-environment bootstrapper   (SIMULATION)
# ---------------------------------------------------------------------------
#  This is the HEADER fragment. The hosted service concatenates:
#       _header.sh  +  <module>.sh ...  +  _footer.sh
#  to produce the script served at  https://coo.ee/env/<modules>.
#  The checked-in file  java,android  is one such rendering.
#  Edit fragments here; do not hand-edit the rendered artifact.
#  See README.md.
# ===========================================================================
set -euo pipefail

COOEE_VERSION="0.1.0-sim"

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

# ---- idempotent nix package install ---------------------------------------
# Safe to run repeatedly: installs only what's missing, treats an already
# present package as success, so the whole script is a no-op on a warm box
# and a repair on a cold/partial one.
nix_ensure() {  # nix_ensure <match> <flakeref> [extra nix flags...]
  local match=$1; shift
  if nix profile list 2>/dev/null | grep -qiF -- "$match"; then
    ok "already present: $match"; return 0
  fi
  local out
  if out=$(nix profile install "$@" 2>&1); then
    ok "installed: $match"
  elif grep -qiF "already installed" <<<"$out"; then
    ok "already present: $match"
  else
    printf '%s\n' "$out" >&2
    return 1
  fi
}

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
  local opts="-Djavax.net.ssl.trustStore=$store -Djavax.net.ssl.trustStorePassword=changeit"
  add_env JAVA_TOOL_OPTIONS "${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }$opts"
  ok "JDK now trusts ${#extra[@]} extra CA(s) via JAVA_TOOL_OPTIONS."
}

# ---- module + host registry ----------------------------------------------
# Modules register themselves (so _footer runs them in order) and declare the
# hosts they need, each with a human reason used in the remediation banner.
MODULES=()
declare -A _HOST_REASON=()   # required to INSTALL — probed, hard-fail if blocked
declare -A _WANT_REASON=()   # recommended for BUILDS — advisory only (may be wildcards)
register_module() { MODULES+=("$1"); }
need_host()       { _HOST_REASON["$1"]="$2"; }   # need_host <host> <reason>
want_host()       { _WANT_REASON["$1"]="$2"; }   # want_host <host|*.host> <reason>

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
  local cmd=${_PROVIDES_CMD["$1"]:-}
  [[ -n "$cmd" ]] && command -v "$cmd" >/dev/null 2>&1
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
