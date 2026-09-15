
# ===========================================================================
#  module: java
#    software : Temurin JDK (via Nix), JAVA_HOME, JDK TLS fix, plus
#               build-brief (the Gradle output reducer) when the checkout
#               actually builds with Gradle — see the build-brief section below
#    params   : java[17,21] picks the JDK majors. With no param, defaults to
#               BOTH 17 and 21 (the LTS majors this fleet builds against — AGP /
#               Gradle still pin 17 while app code targets 21), plus any distinct
#               toolchainVersion the project pins in gradle/gradle-daemon-jvm.properties.
#               Missing majors are installed via Nix; ones the base image already
#               ships are adopted, so "17 + 21" is cheap when one is present.
#    hosts    : cache.nixos.org (install)
#             : Gradle / Maven / toolchain registries (build; used by the
#               best-effort dependency prefetch, advisory — opt out COOEE_NO_DEPS=1)
#             : github.com + its release-asset CDN (build-brief; bb.staticvar.dev
#               is the fallback installer — advisory, opt out COOEE_NO_BUILD_BRIEF=1)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
# ===========================================================================
register_module java
provides_tool java java   # adopt an existing JDK (warm box or cloud base image)
# Pre-approve the JVM build toolchain for Claude Code sessions.
provides_perms java "Bash(./gradlew:*)" "Bash(build-brief:*)" "Bash(gradle:*)" "Bash(java:*)" "Bash(javac:*)" "Bash(kotlin:*)" "Bash(kotlinc:*)" "Bash(mvn:*)"
need_host cache.nixos.org      "prebuilt Temurin JDK from the Nix cache"
want_host services.gradle.org  "Gradle distributions (wrapper download; 307-redirects to GitHub releases)"
want_host github.com           "Gradle distribution redirect target (gradle/gradle-distributions releases) + the build-brief release download (static-var/build-brief)"
want_host api.github.com       "GitHub release API for JDK/tool provisioning (Adoptium et al. resolve download URLs here; also the build-brief latest-release fallback)"
want_host release-assets.githubusercontent.com "GitHub release-asset CDN serving the Gradle distribution zip and the build-brief tarball (current host)"
want_host objects.githubusercontent.com "GitHub release-asset CDN (legacy host; still used for some assets)"
want_host bb.staticvar.dev     "build-brief's own install.sh — the fallback when the direct GitHub release download is blocked"
want_host downloads.gradle.org "Gradle direct-download host (legacy/non-wrapper distribution URLs)"
want_host repo.gradle.org      "Gradle tooling artifacts + the github-downloads-proxy that seeds the wrapper distribution (mirrors the GitHub release the wrapper's services.gradle.org URL 307-redirects to, which is often blocked)"
want_host central.sonatype.com "Maven Central artifacts"
want_host api.foojay.io        "Java distro metadata for Gradle toolchains"
want_host api.adoptium.net     "JDK/toolchain provisioning API"
want_host cdn.azul.com         "Azul Zulu JDK builds for Gradle toolchain provisioning"
want_host download.java.net    "OpenJDK reference builds (a Gradle toolchain provisioning source)"
want_host jitpack.io           "dependencies published via JitPack"
# Amazon Corretto (another Gradle toolchain vendor) serves its JDK builds from
# a CloudFront distribution (*.cloudfront.net), which we can't pin to a concrete
# host for the IP firewall — allow *.cloudfront.net manually if you provision it.

# The JDK a Gradle project pins for its build — the toolchainVersion in the
# version file in the gradle directory (gradle/gradle-daemon-jvm.properties),
# the file Gradle's "Daemon JVM criteria" reads to decide which JDK the daemon
# must run on, e.g.
#   toolchainVersion=17
# yields 17. Empty when there is no such file, so the caller falls back to its
# own default. This is the JDK `./gradlew` would select, so matching it here
# means a param-less `java` provisions exactly what the build expects.
cooee_java_project_version() {
  local props=gradle/gradle-daemon-jvm.properties
  [[ -f "$props" ]] || return 0
  sed -n 's/^[[:space:]]*toolchainVersion[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$props" | head -1
}

# The default JDK major set when the request names none: BOTH LTS majors this
# fleet builds against (17 and 21), plus any distinct toolchain major the project
# pins for its Gradle daemon. One per line, unsorted (the caller canonicalizes).
cooee_java_default_versions() {
  local detected; detected=$(cooee_java_project_version)
  printf '17\n21\n'
  [[ -n "$detected" ]] && printf '%s\n' "$detected"
  return 0   # the trailing [[ ]] must not leak a non-zero rc (pipefail-safe)
}

# The feature (major) version of the JDK at the given home, e.g. 17. Prefers the
# `release` file (no JVM start); falls back to `java -version`. Empty on failure.
cooee_jdk_major() {
  local home="$1" v=""
  [[ -x "$home/bin/java" ]] || return 0
  [[ -r "$home/release" ]] && \
    v=$(sed -n 's/^JAVA_VERSION="\([0-9][0-9]*\).*/\1/p' "$home/release" | head -1)
  [[ -n "$v" ]] || v=$("$home/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9][0-9]*\).*/\1/p' | head -1)
  printf '%s' "$v"
}

# Echo the JAVA_HOME of an already-installed JDK of the given feature major, or
# nothing (rc 1). Checks the active `java`, then the common toolchain locations
# Gradle also scans — so we don't reinstall a JDK the base image already ships.
cooee_jdk_home_for_major() {
  local major="$1" home cand
  if command -v java >/dev/null 2>&1; then
    home="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    [[ "$(cooee_jdk_major "$home")" == "$major" ]] && { printf '%s' "$home"; return 0; }
  fi
  for cand in /usr/lib/jvm/* /opt/jdk* /opt/*jdk* "$HOME"/.sdkman/candidates/java/*; do
    [[ -x "$cand/bin/java" ]] || continue
    [[ "$(cooee_jdk_major "$cand")" == "$major" ]] && { printf '%s' "$cand"; return 0; }
  done
  return 1
}

# The store path (JAVA_HOME) of a Nix-installed Temurin JDK of the given major,
# resolved from the flake ref. Needed because a JDK that isn't the profile's
# priority-winner has no bin/java in ~/.nix-profile/bin, so cooee_jdk_home_for_major
# (which scans PATH + on-disk locations) can't see it. Empty (rc 1) on failure.
cooee_nix_jdk_home() {  # <major>
  local major="$1" p
  command -v nix >/dev/null 2>&1 || return 1
  p=$(nix path-info "nixpkgs#temurin-bin-$major" 2>/dev/null | head -1)
  [[ -n "$p" && -x "$p/bin/java" ]] && { printf '%s' "$p"; return 0; }
  return 1
}

# JAVA_HOME of an installed JDK of the given major, from anywhere: an on-disk /
# base-image JDK first (cooee_jdk_home_for_major), else the Nix store. Empty (rc1).
cooee_jdk_home_any() {  # <major>
  local major="$1" h
  h=$(cooee_jdk_home_for_major "$major") && [[ -n "$h" ]] && { printf '%s' "$h"; return 0; }
  cooee_nix_jdk_home "$major"
}

# Symlink a JDK into /usr/lib/jvm — a Gradle "Common Linux Location" for toolchain
# auto-detection, and where agents look for a JDK by major — so a Nix JDK at an
# unguessable /nix/store path (and the non-active majors, absent from PATH) is
# discoverable. A JDK already under /usr/lib/jvm (a base image's own) is left as
# is. Best-effort: warns and skips if the dir isn't writable (needs root).
# Override the link dir with COOEE_JVM_LINK_DIR.
cooee_link_jdk_typical() {  # <java_home> <major>
  local home="$1" major="$2"
  [[ -x "$home/bin/java" ]] || return 0
  local jvmdir="${COOEE_JVM_LINK_DIR:-/usr/lib/jvm}"
  # Already in the conventional dir (base-image JDK)? Nothing to do.
  case "$home/" in "$jvmdir"/*) return 0 ;; esac
  local link="$jvmdir/temurin-$major"
  [[ "$(readlink -f "$link" 2>/dev/null)" == "$(readlink -f "$home" 2>/dev/null)" ]] && return 0
  mkdir -p "$jvmdir" 2>/dev/null || { warn "java: can't create $jvmdir; JDK $major not linked."; return 0; }
  [[ -w "$jvmdir" ]] || { warn "java: $jvmdir not writable; JDK $major not linked (needs root)."; return 0; }
  ln -sfn "$home" "$link" && ok "java: linked $link -> $home (Gradle toolchain auto-detection + guessable path)."
}

module_java() {
  # Requested JDK majors come from the request params (java[17,21]).
  local -a versions=("$@")

  # With no explicit param, default to BOTH LTS majors this fleet builds against
  # (17 and 21) plus any distinct toolchain major the project pins — a box that
  # ships only one of them makes half the builds fail. See cooee_java_default_versions.
  if (( ! ${#versions[@]} )); then
    mapfile -t versions < <(cooee_java_default_versions)
    log "java: no JDK requested; defaulting to 17 + 21 (plus any project-pinned toolchain)."
  fi

  # Canonicalize: ascending + unique, so the lowest major stays first (it owns
  # java/javac + JAVA_HOME) and a project pinning 17/21 doesn't duplicate.
  mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort -un)

  # Let the backend decide which of the requested majors it can install: the nix
  # backend keeps them all (each gets its own --priority below), the devenv
  # backend keeps only the first (one buildEnv can't hold two colliding JDKs).
  mapfile -t versions < <(cooee_backend_jdks "${versions[@]}")

  # Ensure every required major is present: adopt one already on the box (the
  # cloud base image, or a prior run) and install only the MISSING majors via
  # Nix. Detecting what's already there avoids a redundant ~200MB Temurin fetch
  # per JDK — which is what makes "default to 17 + 21" cheap when the image
  # already ships one. COOEE_FORCE=1 reinstalls everything via Nix. (nix_ensure is
  # itself idempotent, so a Nix JDK the dir-scan can't see is still not re-fetched.)
  local -a to_install=()
  local v home
  for v in "${versions[@]}"; do
    if [[ "${COOEE_FORCE:-0}" != 1 ]] && home=$(cooee_jdk_home_for_major "$v") && [[ -n "$home" ]]; then
      ok "java: JDK $v already present ($home); skipping install."
    else
      to_install+=("$v")
    fi
  done

  if (( ${#to_install[@]} )); then
    log "Installing missing Temurin JDK(s) (${to_install[*]}) via Nix..."
    # Multiple JDKs ship colliding files (e.g. lib/modules), so a single profile
    # can't hold them at the same priority — `nix profile add` aborts. Give each a
    # distinct priority (lower wins), ascending from 5 in install order (ascending
    # by major), so the lowest JDK owns the java/javac symlinks and the rest stay
    # discoverable by Gradle toolchain resolution.
    local prio=5
    for v in "${to_install[@]}"; do
      nix_ensure "temurin-bin-$v" "nixpkgs#temurin-bin-$v" --accept-flake-config --priority "$prio"
      prio=$((prio + 1))
    done
  else
    ok "java: all required JDK(s) (${versions[*]}) already present; nothing to install."
  fi

  # JAVA_HOME -> the lowest required major (the toolchain most repos pin to),
  # resolved whether it came from the base image or Nix. Fall back to whatever
  # `java` resolves to if the lowest can't be located (shouldn't happen).
  local jhome; jhome=$(cooee_jdk_home_for_major "${versions[0]}") || jhome=""
  if [[ -z "$jhome" ]]; then
    command -v java >/dev/null 2>&1 || die "java not on PATH after install."
    jhome="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
  fi
  add_env JAVA_HOME "$jhome"

  # Link every provisioned JDK into the conventional /usr/lib/jvm so Gradle
  # toolchain auto-detection (a "Common Linux Location") and agents find each
  # major by a guessable path — a Nix JDK otherwise lives only at an unguessable
  # /nix/store path, and the non-active majors aren't even on PATH. Best-effort.
  local lv lh
  for lv in "${versions[@]}"; do
    if lh=$(cooee_jdk_home_any "$lv") && [[ -n "$lh" ]]; then
      cooee_link_jdk_typical "$lh" "$lv"
    else
      warn "java: couldn't locate JDK $lv on disk to link into /usr/lib/jvm; skipping."
    fi
  done

  # Cloud fixes (applied once — each sets JAVA_TOOL_OPTIONS, which every JVM
  # reads, so a single call covers all the JDKs): a Nix JDK ignores the system
  # trust store, so teach the shared truststore the sandbox proxy CA (else Gradle
  # HTTPS fails with PKIX errors); route the JVM through the sandbox proxy (it
  # ignores http(s)_proxy) so the Gradle wrapper/daemon can reach
  # services.gradle.org et al.; and force a UTF-8 locale + JVM file encoding so
  # Gradle report paths with non-ASCII chars don't die under a C locale.
  cooee_trust_cas_in_jdk "$JAVA_HOME"
  cooee_jvm_proxy_opts
  cooee_jvm_utf8_opts
  # Pin the same flags through Gradle's own canonical channel (user-dir
  # gradle.properties). This is the channel that actually carries them to a
  # build: JAVA_TOOL_OPTIONS is shell-only now and is restored before we exit.
  cooee_gradle_props_jvmargs

  ok "java ready: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1) (toolchains: ${versions[*]})"

  cooee_seed_gradle_wrapper
  cooee_build_brief_setup
  cooee_prefetch_gradle
}

# Cloud fix, the Gradle-native companion to the JAVA_TOOL_OPTIONS flags: pin
# every flag the cloud fixes added (see cooee_add_jvm_flag — proxy host/port +
# nonProxyHosts, the extra-CA truststore, -Dfile.encoding=UTF-8) on
#   org.gradle.jvmargs
# in the *user-dir* gradle.properties ($GRADLE_USER_HOME/gradle.properties,
# default ~/.gradle/gradle.properties).
#
# This is now the PRIMARY channel, not a backstop. JAVA_TOOL_OPTIONS is no longer
# forwarded to harness env files (see COOEE_ENV_SHELL_ONLY: harnesses replay
# those as unquoted shell, and a value with spaces and pipes turns into a spray
# of bogus commands on every command the agent runs) and is restored to its entry
# value before we exit. gradle.properties has neither problem: Gradle parses it
# as properties, it needs no environment inheritance, and it reaches the client,
# its daemon, and every forked worker — including a daemon started by an IDE or a
# bare ./gradlew, which never saw this shell.
#
# Merge-safe and idempotent — never clobbers a user's existing heap/other args:
#   * no gradle.properties / no org.gradle.jvmargs line -> append a fresh line
#     with our flags.
#   * an org.gradle.jvmargs line -> append only the flags whose *property name*
#     (the -Dkey= prefix) isn't already on it, so a value the user chose
#     deliberately (a different charset, their own proxy) always wins.
# Opt out entirely with COOEE_NO_GRADLE_PROPS=1.
cooee_gradle_props_jvmargs() {
  if [[ "${COOEE_NO_GRADLE_PROPS:-0}" == 1 ]]; then
    log "java: skipping user-dir gradle.properties JVM-args write (COOEE_NO_GRADLE_PROPS=1)."
    return 0
  fi
  [[ -n "${COOEE_JVM_FLAGS:-}" ]] || { log "java: no cloud JVM flags to pin in gradle.properties."; return 0; }

  local guh="${GRADLE_USER_HOME:-$HOME/.gradle}"
  local props="$guh/gradle.properties"
  mkdir -p "$guh" 2>/dev/null || {
    warn "java: can't create $guh; skipping user-dir gradle.properties JVM-args write."; return 0; }

  # Existing org.gradle.jvmargs line (empty when absent) — used to decide which
  # of our flags are already represented.
  local existing=""
  [[ -f "$props" ]] && existing=$(grep -E '^[[:space:]]*org\.gradle\.jvmargs[[:space:]]*=' "$props" | head -1)

  local -a add=()
  local flag key
  for flag in $COOEE_JVM_FLAGS; do
    key="${flag%%=*}="                       # -Dfile.encoding=UTF-8 -> -Dfile.encoding=
    [[ "$existing" == *"$key"* ]] && continue
    add+=("$flag")
  done
  if (( ! ${#add[@]} )); then
    log "java: $props already carries every cloud JVM flag; leaving it as-is."
    return 0
  fi

  if [[ -z "$existing" ]]; then
    if printf 'org.gradle.jvmargs=%s\n' "${add[*]}" >> "$props"; then
      ok "java: set org.gradle.jvmargs=${add[*]} in $props."
    else
      warn "java: couldn't write $props; skipping user-dir gradle.properties JVM-args write."
    fi
    return 0
  fi

  # Extend the existing line in place so the user's other JVM args (heap, GC, …)
  # are preserved.
  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/cooee-gradle-props.XXXXXX") || {
    warn "java: couldn't stage a gradle.properties edit; leaving $props unchanged."; return 0; }
  if sed -E "s|^([[:space:]]*org\.gradle\.jvmargs[[:space:]]*=.*)$|\1 ${add[*]}|" \
       "$props" > "$tmp" && mv -f "$tmp" "$props"; then
    ok "java: appended ${add[*]} to org.gradle.jvmargs in $props."
  else
    warn "java: couldn't update $props; leaving it unchanged."; rm -f "$tmp"
  fi
}

# Seed the Gradle wrapper distributions into the wrapper cache from an
# allowlisted mirror, so the first `./gradlew` never has to fetch one over a path
# the sandbox blocks — for EVERY checkout in the workspace, not just the one
# project dir.
#
# The problem: a wrapper's distributionUrl points at services.gradle.org, which
# 307-redirects to a GitHub release
# (github.com/gradle/gradle-distributions/releases/…). Cloud sandboxes routinely
# block github.com's release assets, so the very first `./gradlew` dies fetching
# the distribution — before the build even starts, and before any host we
# allowlist for the *build* matters.
#
# The multi-checkout wrinkle: a session often has several repos checked out side
# by side (the workspace root, i.e. the parent of the project dir), and they can
# pin *different* Gradle versions in their own gradle/wrapper/gradle-wrapper.properties.
# Seeding only cooee_project_dir's wrapper covers one version; the other
# checkouts' first `./gradlew` still dies on the blocked redirect. So we discover
# every wrapper across the local checkouts, dedup by distributionUrl, and seed
# each distinct version.
#
# The fix: repo.gradle.org's github-downloads-proxy serves the identical bytes
# (it proxies the same GitHub release server-side) and is a normal Gradle host
# we already allow. So we fetch the distribution from there, checksum-verify it,
# and drop the zip into $GRADLE_USER_HOME/wrapper/dists exactly where the wrapper
# looks for it — Gradle then unpacks + re-verifies + marks it ready itself on the
# first invocation, with no network. No repo changes: the wrapper properties are
# read, never written.
#
# No-op when there is no wrapper anywhere, when a distribution is already cached
# (warm box / prior run), or when a distributionUrl isn't the services.gradle.org
# default (a custom/self-hosted URL is the project's own call). Best-effort: any
# failure warns and leaves that download to Gradle — it never fails provisioning.
# Runs regardless of COOEE_NO_DEPS, since it's about `./gradlew` working at all,
# not about warming dependencies.
cooee_seed_gradle_wrapper() {
  local -A seen=()
  local props url seeded=0
  while IFS= read -r props; do
    [[ -n "$props" ]] || continue
    url=$(cooee_gradle_distribution_url "$props")
    [[ -n "$url" ]] || continue
    # Same distribution pinned by more than one checkout — seed it once.
    [[ -n "${seen[$url]:-}" ]] && continue
    seen[$url]=1
    cooee_seed_one_gradle_wrapper "$props" "$url"
    seeded=$((seeded + 1))
  done < <(cooee_gradle_wrapper_props)
  (( seeded )) || log "java: no Gradle wrapper found in the local checkouts; nothing to seed."
}

# Every gradle-wrapper.properties across the local checkouts. Repos are typically
# checked out side by side under the workspace root (the parent of the project
# dir); each can pin its own Gradle version. Override the search root with
# COOEE_CHECKOUTS_DIR. Bounded depth keeps the scan cheap and still catches both a
# repo-root wrapper and a nested build's wrapper (e.g. <repo>/android/gradle/…).
cooee_gradle_wrapper_props() {
  local root; root="$(cooee_workspace_root)"   # parent holding the side-by-side checkouts
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 5 -type f \
    -path '*/gradle/wrapper/gradle-wrapper.properties' 2>/dev/null | sort
}

# A property value from a gradle-wrapper.properties, unescaping the properties-file
# '\:' -> ':' and stripping any trailing CR. Empty output when absent.
cooee_gradle_prop() {
  local props="$1" key="$2" v
  [[ -f "$props" ]] || return 0
  v=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$props" | head -1)
  v="${v%$'\r'}"; v="${v//\\:/:}"
  printf '%s' "$v"
}

# distributionUrl from a gradle-wrapper.properties (see cooee_gradle_prop).
cooee_gradle_distribution_url() { cooee_gradle_prop "$1" distributionUrl; }

# Resolve a wrapper store-base keyword (GRADLE_USER_HOME | PROJECT) to a path.
# PROJECT is the build root (the dir holding gradle/wrapper/…); the default and
# any unknown value map to GRADLE_USER_HOME (~/.gradle).
cooee_gradle_store_base() {
  local base="$1" repo="$2"
  case "$base" in
    PROJECT) printf '%s' "$repo" ;;
    *)       printf '%s' "${GRADLE_USER_HOME:-$HOME/.gradle}" ;;
  esac
}

# The wrapper cache dir where Gradle looks for a distribution's downloaded zip:
# <store>/<zipStorePath>/<distname>/<hash>, hash = base36(md5(url)). The zip AND
# the `.ok` marker Gradle writes both live in the zip store (zipStoreBase /
# zipStorePath), not the distribution dir (distributionBase / distributionPath) —
# so honor those rather than assuming the GRADLE_USER_HOME / wrapper/dists
# defaults. A wrapper pinning zipStoreBase=PROJECT or a custom zipStorePath would
# otherwise get the seed placed where Gradle never looks, and it would still fall
# back to the blocked services.gradle.org download. Args: props, url, repo (the
# build root holding gradle/wrapper/…). Empty output + rc 1 if the hash can't be
# computed (no md5 tool).
cooee_gradle_zip_dest() {
  local props="$1" url="$2" repo="$3"
  local zipname="${url##*/}" distname hash zbase zpath store
  distname="${zipname%.zip}"
  hash=$(cooee_gradle_wrapper_hash "$url") || return 1
  zbase=$(cooee_gradle_prop "$props" zipStoreBase); zbase="${zbase:-GRADLE_USER_HOME}"
  zpath=$(cooee_gradle_prop "$props" zipStorePath); zpath="${zpath:-wrapper/dists}"
  store=$(cooee_gradle_store_base "$zbase" "$repo")
  printf '%s/%s/%s/%s' "$store" "$zpath" "$distname" "$hash"
}

# Seed one wrapper's distribution (props file + its already-extracted distributionUrl)
# into the wrapper cache. See cooee_seed_gradle_wrapper for the rationale.
cooee_seed_one_gradle_wrapper() {
  local props="$1" url="$2"
  local repo="${props%/gradle/wrapper/gradle-wrapper.properties}"

  # Only handle the stock services.gradle.org distribution — the one whose GitHub
  # redirect is what gets blocked. A custom distributionUrl is left untouched.
  case "$url" in
    https://services.gradle.org/distributions/*.zip) : ;;
    *) log "java: $repo wrapper distributionUrl isn't the services.gradle.org default ($url); leaving the wrapper download to Gradle."; return 0 ;;
  esac

  local zipname="${url##*/}"                 # gradle-9.6.1-bin.zip
  local distname="${zipname%.zip}"           # gradle-9.6.1-bin
  local ver="${distname#gradle-}"            # 9.6.1-bin
  ver="${ver%-bin}"; ver="${ver%-all}"       # 9.6.1

  # The wrapper cache dir where Gradle looks for the downloaded zip, honoring the
  # wrapper's zipStoreBase/zipStorePath (see cooee_gradle_zip_dest).
  local dest; dest=$(cooee_gradle_zip_dest "$props" "$url" "$repo") \
    || { warn "java: couldn't compute the wrapper cache hash for $repo; leaving the wrapper download to Gradle."; return 0; }

  # Already there? Either Gradle installed it (.ok marker) or a prior seed placed
  # the zip pending unpack. Nothing to do.
  if [[ -f "$dest/$zipname.ok" || -f "$dest/$zipname" ]]; then
    log "java: Gradle $ver already present in the wrapper cache; nothing to seed."
    return 0
  fi

  # Rewrite services.gradle.org -> the github-downloads-proxy, which mirrors the
  # exact GitHub release asset (v<ver>/<zipname>) the redirect points at.
  local mirror="https://repo.gradle.org/gradle/github-downloads-proxy/gradle/gradle-distributions/releases/download/v$ver/$zipname"

  log "java: seeding Gradle $ver into the wrapper cache from repo.gradle.org (services.gradle.org's GitHub redirect is blocked here)..."

  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/cooee-gradle-dist.XXXXXX") \
    || { warn "java: couldn't create a temp dir for the wrapper seed; skipping."; return 0; }
  local zip="$tmp/$zipname"
  if ! curl -fsSL --retry 3 -o "$zip" "$mirror"; then
    warn "java: couldn't download Gradle $ver from $mirror; leaving the wrapper download to Gradle."
    rm -rf "$tmp"; return 0
  fi

  # Verify: prefer the wrapper's pinned distributionSha256Sum, else the mirror's
  # published .sha256. A mismatch means don't trust the bytes — bail, don't seed.
  local want
  want=$(sed -n 's/^[[:space:]]*distributionSha256Sum[[:space:]]*=[[:space:]]*//p' "$props" | head -1)
  want="${want%$'\r'}"
  [[ -n "$want" ]] || want=$(curl -fsSL "$mirror.sha256" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "$want" ]]; then
    local got; got=$(sha256sum "$zip" | cut -d' ' -f1)
    if [[ "$got" != "$want" ]]; then
      warn "java: Gradle $ver checksum mismatch (got $got, want $want); refusing to seed. Leaving the wrapper download to Gradle."
      rm -rf "$tmp"; return 0
    fi
    log "java: Gradle $ver checksum verified ($want)."
  else
    warn "java: no checksum available for Gradle $ver; seeding the download unverified."
  fi

  # Place the verified zip where the wrapper expects it. Gradle finds it there,
  # (re-)checksums it against any pinned sum, unpacks it, and writes the .ok
  # marker on the first `./gradlew` — all offline.
  mkdir -p "$dest" && mv -f "$zip" "$dest/$zipname" || {
    warn "java: couldn't place the Gradle $ver zip in the wrapper cache ($dest); skipping."
    rm -rf "$tmp"; return 0; }
  rm -rf "$tmp"
  ok "java: Gradle $ver seeded into the wrapper cache; ./gradlew will unpack it without fetching the distribution."
}

# base36(md5(s)) — reproduces org.gradle.wrapper.PathAssembler#getHash, the
# scheme Gradle uses to name a distribution's wrapper cache directory from its
# distributionUrl (MD5 of the URL, rendered as an unsigned BigInteger in base
# 36). Pure bash so it needs no python/bc: md5 -> hex, then repeated
# long-division of that base-16 bignum by 36, collecting remainders.
cooee_gradle_wrapper_hash() {
  local url="$1" hex
  if command -v md5sum >/dev/null 2>&1; then hex=$(printf '%s' "$url" | md5sum | cut -d' ' -f1)
  elif command -v md5 >/dev/null 2>&1; then hex=$(printf '%s' "$url" | md5 -q)
  else return 1; fi
  [[ ${#hex} -eq 32 ]] || return 1

  local -a nib=() out=(); local i
  for (( i=0; i<32; i++ )); do nib+=($((16#${hex:i:1}))); done

  local digits="0123456789abcdefghijklmnopqrstuvwxyz"
  while ((${#nib[@]})); do
    local -a q=(); local carry=0 started=0 d val qi
    for d in "${nib[@]}"; do
      val=$(( carry*16 + d )); qi=$(( val/36 )); carry=$(( val%36 ))
      if (( started || qi )); then q+=("$qi"); started=1; fi
    done
    out=("$carry" "${out[@]}")      # prepend this base36 digit (the remainder)
    nib=("${q[@]}")
  done

  local s=""; ((${#out[@]})) || s=0
  for d in "${out[@]}"; do s+="${digits:d:1}"; done
  printf '%s' "$s"
}

# Warm the Gradle build cache: with a JDK ready (and the Gradle/Maven hosts
# reachable), download the project's dependencies now so a later `./gradlew
# build` — possibly under tighter egress — can run from cache. Best-effort and
# never fatal.
#
# By default this resolves every resolvable configuration's *files* via a
# transient init script, so the actual artifact JARs land in the cache — not
# just the metadata that the `dependencies` report task alone fetches — without
# compiling anything. Set COOEE_GRADLE_DEPS_TASK to run a specific task instead
# (e.g. "assemble -x test"); the value is word-split so it can carry flags.
#
# Skipped when there is no Gradle build in the project dir, when neither a
# wrapper nor `gradle` is available, or when COOEE_NO_DEPS=1.
cooee_prefetch_gradle() {
  cooee_deps_enabled || { log "java: skipping Gradle dependency prefetch (COOEE_NO_DEPS=1)."; return 0; }

  local dir; dir=$(cooee_project_dir)
  if ! compgen -G "$dir"/settings.gradle* >/dev/null 2>&1 \
     && ! compgen -G "$dir"/build.gradle* >/dev/null 2>&1; then
    log "java: no Gradle build in $dir; skipping dependency prefetch."
    return 0
  fi

  # Prefer the project's wrapper (pins the exact Gradle version) over any
  # system gradle.
  local gradle
  if [[ -x "$dir/gradlew" ]]; then gradle="$dir/gradlew"
  elif command -v gradle >/dev/null 2>&1; then gradle=gradle
  else log "java: Gradle build present but no wrapper or gradle on PATH; skipping dependency prefetch."; return 0; fi

  local -a inv=(--no-daemon --console=plain)
  local label init=""
  if [[ -n "${COOEE_GRADLE_DEPS_TASK:-}" ]]; then
    # Explicit task override — word-split so it can carry flags.
    local -a task; read -r -a task <<< "$COOEE_GRADLE_DEPS_TASK"
    inv+=("${task[@]}")
    label="task: ${task[*]}"
  else
    # Default: an init script resolves every resolvable configuration's files
    # (leniently, so one unresolvable config can't fail the warm-up), forcing
    # artifact download across all projects. `help` just drives evaluation.
    init=$(mktemp "${TMPDIR:-/tmp}/cooee-gradle-prefetch.XXXXXX") || {
      warn "java: could not create a temp init script; skipping dependency prefetch."; return 0; }
    cat > "$init" <<'GRADLE'
gradle.projectsEvaluated {
  rootProject.allprojects { proj ->
    proj.configurations.each { conf ->
      if (conf.canBeResolved) {
        try { conf.resolvedConfiguration.lenientConfiguration.files }
        catch (Throwable t) { proj.logger.lifecycle("cooee: skip ${proj.path}:${conf.name} (${t.message})") }
      }
    }
  }
}
GRADLE
    inv+=(--init-script "$init" help)
    label="all resolvable configurations"
  fi

  log "java: prefetching Gradle build dependencies ($label)..."
  # Capture output so the success path stays quiet (resolution is noisy);
  # surface it only on failure, for diagnosis.
  local out rc=0
  out=$( cd "$dir" && "$gradle" "${inv[@]}" </dev/null 2>&1 ) || rc=$?
  [[ -n "$init" ]] && rm -f "$init"
  if [[ $rc -eq 0 ]]; then
    ok "java: Gradle build dependencies prefetched ($label)."
  else
    printf '%s\n' "$out" >&2
    warn "java: Gradle dependency prefetch failed (continuing). Allowlist the Gradle/Maven hosts, or set COOEE_NO_DEPS=1 to skip."
  fi
}

# ===========================================================================
#  build-brief — the Gradle output reducer, set up when Gradle is selected
# ===========================================================================
# `build-brief` (https://bb.staticvar.dev, static-var/build-brief, MIT, a single
# Go binary with no runtime deps) sits in front of Gradle: it writes every line
# Gradle emits to a log file and prints only what changes the next move — status,
# failed tasks, failed tests, warnings, build scan URLs, generated output paths.
# The Gradle exit code passes through unchanged, so it is safe anywhere a bare
# `./gradlew` was.
#
# Why this belongs in the *environment* rather than in a repo: an agent session
# runs `check` and full render pipelines in-session, and those bury their one
# real line in thousands — the reducer is what keeps that affordable, and it is
# only useful if the binary is already on PATH when the session starts. It is
# also a hard prerequisite for the shared-host Gradle launchers that repos are
# starting to ship (compose-ai-tools' `scripts/agent-gradle.sh` exits 1 with
# "build-brief is required" when it isn't installed), so provisioning it here is
# what makes those checkouts work unattended.
#
# Everything below is best-effort: a blocked CDN warns and moves on. Gradle
# still builds without the reducer, so this never fails a `java` provision.
#   COOEE_NO_BUILD_BRIEF=1        skip entirely
#   COOEE_BUILD_BRIEF=1           install even when no Gradle build was detected
#   COOEE_BUILD_BRIEF_VERSION=x.y.z   pin a release (default: latest)
#   COOEE_BUILD_BRIEF_BIN_DIR=dir     install location (default ~/.local/bin)
#   COOEE_NO_BUILD_BRIEF_GUIDE=1  install the binary but write no usage guide
COOEE_BUILD_BRIEF_REPO="${COOEE_BUILD_BRIEF_REPO:-static-var/build-brief}"
COOEE_BUILD_BRIEF_BIN_DIR="${COOEE_BUILD_BRIEF_BIN_DIR:-$HOME/.local/bin}"

# True when this environment is being provisioned *for Gradle*, which is the
# only case build-brief is for (it reduces Gradle output and nothing else —
# a Maven-only or plain-JDK checkout has no use for it).
#
# Gradle counts as selected when any of these hold:
#   * a Gradle wrapper exists in one of the side-by-side checkouts — the same
#     scan cooee_seed_gradle_wrapper uses, so "we seeded a distribution for it"
#     and "we install the reducer for it" can never disagree;
#   * `gradle` is already on PATH (a warm box, a base image, or `tools[gradle]`
#     from an earlier run);
#   * `tools[gradle]` is part of *this* request — the tools module may not have
#     run yet, so read the request params rather than PATH.
cooee_gradle_selected() {
  [[ -n "$(cooee_gradle_wrapper_props)" ]] && return 0
  command -v gradle >/dev/null 2>&1 && return 0
  local t; local -a requested=()
  IFS=',' read -r -a requested <<< "${_MODULE_PARAMS[tools]:-}"
  for t in "${requested[@]}"; do
    [[ "$t" == gradle || "$t" == *.gradle ]] && return 0
  done
  return 1
}

# Entry point, called from module_java: gate, adopt or install, then write the
# usage guide so an agent actually knows to reach for it.
cooee_build_brief_setup() {
  if [[ "${COOEE_NO_BUILD_BRIEF:-0}" == 1 ]]; then
    log "java: skipping build-brief (COOEE_NO_BUILD_BRIEF=1)."
    return 0
  fi
  if [[ "${COOEE_BUILD_BRIEF:-0}" != 1 ]] && ! cooee_gradle_selected; then
    log "java: no Gradle build selected (no wrapper in the checkouts, no gradle on PATH, no tools[gradle]); skipping build-brief. Force it with COOEE_BUILD_BRIEF=1."
    return 0
  fi

  # Adopt an existing install (warm box, or a previous run) — but still make
  # sure its dir is on PATH for later shells and that the guide is in place.
  local bin
  if command -v build-brief >/dev/null 2>&1; then
    bin="$(command -v build-brief)"
    cooee_build_brief_path "$(dirname "$bin")"
    ok "java: adopted existing build-brief ($bin, $("$bin" --version 2>/dev/null | head -1))."
    cooee_build_brief_guide
    return 0
  fi

  if cooee_build_brief_install; then
    cooee_build_brief_guide
  fi
  return 0
}

# Put <dir> on PATH for this shell and persist it, unless it is already there.
cooee_build_brief_path() {  # <dir>
  local dir="$1"
  case ":${PATH}:" in
    *":$dir:"*) return 0 ;;
  esac
  add_env PATH "$dir:$PATH"
  export PATH="$dir:$PATH"
}

# This host's build-brief release asset suffix (<os>_<arch>), mirroring the
# upstream install.sh naming. Empty + rc 1 on a platform it doesn't publish for.
cooee_build_brief_platform() {
  local os arch
  case "$(uname -s)" in
    Linux)  os=linux  ;;
    Darwin) os=darwin ;;
    *) return 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch=amd64 ;;
    arm64|aarch64) arch=arm64 ;;
    *) return 1 ;;
  esac
  printf '%s_%s' "$os" "$arch"
}

# The latest published version, without the leading `v`. Resolved from the
# /releases/latest redirect (no API token, no rate limit); falls back to the
# release API when the redirect can't be followed. Empty + rc 1 on failure.
cooee_build_brief_latest_version() {
  local repo="$COOEE_BUILD_BRIEF_REPO" tag=""
  tag=$(curl -fsSL --retry 2 -o /dev/null -w '%{url_effective}' \
          "https://github.com/${repo}/releases/latest" 2>/dev/null \
        | sed -n 's#.*/releases/tag/\([^/?#]*\).*#\1#p' | head -1)
  if [[ -z "$tag" ]]; then
    tag=$(curl -fsSL --retry 2 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
          | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  fi
  [[ -n "$tag" ]] || return 1
  printf '%s' "${tag#v}"
}

# Download, verify and install the binary. Returns non-zero (after warning) when
# anything goes wrong — the caller treats that as "no reducer today", not fatal.
cooee_build_brief_install() {
  command -v curl >/dev/null 2>&1 || { warn "java: curl is required to install build-brief; skipping."; return 1; }
  command -v tar  >/dev/null 2>&1 || { warn "java: tar is required to install build-brief; skipping."; return 1; }

  local platform
  platform=$(cooee_build_brief_platform) || {
    warn "java: no build-brief release for '$(uname -s) $(uname -m)'; skipping (Gradle still builds without it)."
    return 1
  }

  local version="${COOEE_BUILD_BRIEF_VERSION:-}"
  if [[ -z "$version" ]]; then
    version=$(cooee_build_brief_latest_version) || {
      warn "java: couldn't resolve the latest build-brief release (github.com blocked?); trying the upstream installer."
      cooee_build_brief_install_sh; return $?
    }
  fi
  version="${version#v}"

  local repo="$COOEE_BUILD_BRIEF_REPO"
  local asset="build-brief_${version}_${platform}.tar.gz"
  local base="https://github.com/${repo}/releases/download/v${version}"
  local tmp; tmp=$(mktemp -d "${TMPDIR:-/tmp}/cooee-build-brief.XXXXXX") || {
    warn "java: couldn't create a temp dir for the build-brief download; skipping."; return 1; }

  log "java: installing build-brief ${version} (${platform}) from github.com..."
  if ! cooee_fetch "${base}/${asset}" "$tmp/$asset"; then
    rm -rf "$tmp"
    warn "java: couldn't download ${asset} (release-asset CDN blocked?); trying the upstream installer."
    cooee_build_brief_install_sh; return $?
  fi

  # Verify against the release's SHA256SUMS. A missing sums file (or no sha256
  # tool) is a warn-and-continue, exactly as upstream's installer treats it; a
  # *mismatch* is not — don't install bytes that failed their own checksum.
  local want got
  want=$(cooee_fetch "${base}/SHA256SUMS" "$tmp/SHA256SUMS" 2 2>/dev/null \
         && awk -v n="$asset" '$2 == n || $2 == "./"n { print $1; exit }' "$tmp/SHA256SUMS")
  if [[ -z "$want" ]]; then
    warn "java: no published checksum for ${asset}; installing unverified."
  elif command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
    if [[ "$got" != "$want" ]]; then
      rm -rf "$tmp"
      warn "java: build-brief checksum mismatch (got $got, want $want); refusing to install."
      return 1
    fi
  fi

  if ! tar -xzf "$tmp/$asset" -C "$tmp"; then
    rm -rf "$tmp"; warn "java: couldn't unpack ${asset}; skipping build-brief."; return 1
  fi

  local src; src=$(find "$tmp" -type f -name build-brief -print -quit 2>/dev/null)
  if [[ -z "$src" ]]; then
    rm -rf "$tmp"; warn "java: no build-brief binary inside ${asset}; skipping."; return 1
  fi

  local dir="$COOEE_BUILD_BRIEF_BIN_DIR"
  if ! (mkdir -p "$dir" && install -m 755 "$src" "$dir/build-brief"); then
    rm -rf "$tmp"; warn "java: couldn't install build-brief into $dir; skipping."; return 1
  fi
  rm -rf "$tmp"

  cooee_build_brief_path "$dir"
  ok "java: build-brief ready ($dir/build-brief, $("$dir/build-brief" --version 2>/dev/null | head -1))."
  return 0
}

# Fallback path: upstream's own install.sh. Used only when the direct release
# download failed, since it needs one more host (bb.staticvar.dev) and resolves
# the same GitHub asset itself.
cooee_build_brief_install_sh() {
  local dir="$COOEE_BUILD_BRIEF_BIN_DIR"
  mkdir -p "$dir" || { warn "java: couldn't create $dir for build-brief; skipping."; return 1; }
  local args=(--bin-dir "$dir")
  [[ -n "${COOEE_BUILD_BRIEF_VERSION:-}" ]] && args+=(--version "${COOEE_BUILD_BRIEF_VERSION#v}")
  local sh; sh=$(mktemp "${TMPDIR:-/tmp}/cooee-bb-install.XXXXXX") || return 1
  if ! cooee_fetch "https://bb.staticvar.dev/install.sh" "$sh" 2; then
    rm -f "$sh"
    warn "java: build-brief install skipped — neither the GitHub release nor bb.staticvar.dev is reachable. Allowlist github.com (+ its release-asset CDN), or set COOEE_NO_BUILD_BRIEF=1 to silence this."
    return 1
  fi
  if bash "$sh" "${args[@]}" >/dev/null 2>&1; then
    rm -f "$sh"
    cooee_build_brief_path "$dir"
    ok "java: build-brief ready via bb.staticvar.dev ($dir/build-brief)."
    return 0
  fi
  rm -f "$sh"
  warn "java: build-brief's installer failed; continuing without the reducer."
  return 1
}

# ---- the guide -------------------------------------------------------------
# Installing the binary is half the job: a reducer nobody reaches for changes
# nothing. So write the usage rules where an agent will actually read them —
# a managed block in the GLOBAL Claude config's CLAUDE.md
# ($CLAUDE_CONFIG_DIR/CLAUDE.md, default ~/.claude/CLAUDE.md), which every
# session in this container loads regardless of which checkout it opens.
#
# Deliberately NOT `build-brief --install`: that regenerates a managed block in
# the *checkout's* AGENTS.md, a git-tracked file. Dirtying provisioned working
# trees is the thing this project avoids everywhere else (see
# cooee_install_session_hook), and a repo that wants those rules committed
# already has them. The environment's copy carries the same rules plus the
# environment-specific ones (the repo launcher, the raw log path).
#
# The block is delimited by markers and rewritten in place, so re-running
# provisioning updates it rather than stacking copies. Opt out with
# COOEE_NO_BUILD_BRIEF_GUIDE=1.
COOEE_BUILD_BRIEF_MARK_START='<!-- coo.ee/env:build-brief:start -->'
COOEE_BUILD_BRIEF_MARK_END='<!-- coo.ee/env:build-brief:end -->'

cooee_build_brief_guide() {
  if [[ "${COOEE_NO_BUILD_BRIEF_GUIDE:-0}" == 1 ]]; then
    log "java: skipping the build-brief usage guide (COOEE_NO_BUILD_BRIEF_GUIDE=1)."
    return 0
  fi
  local dir; dir="$(cooee_global_claude_dir)"
  local md="$dir/CLAUDE.md"
  mkdir -p "$dir" || { warn "java: couldn't create $dir; skipping the build-brief guide."; return 0; }

  local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/cooee-bb-guide.XXXXXX") || {
    warn "java: couldn't stage the build-brief guide; skipping."; return 0; }

  # Existing content minus any previous block (awk drops start..end inclusive),
  # then the freshly rendered block appended.
  if [[ -f "$md" ]]; then
    if ! awk -v s="$COOEE_BUILD_BRIEF_MARK_START" -v e="$COOEE_BUILD_BRIEF_MARK_END" '
          $0 == s { skip = 1; next }
          skip    { if ($0 == e) skip = 0; next }
          { print }' "$md" > "$tmp"; then
      rm -f "$tmp"; warn "java: couldn't rewrite ${md/#$HOME/\~}; skipping the build-brief guide."; return 0
    fi
    # Collapse the trailing blank lines the removal may have left behind.
    printf '%s\n' "$(cat "$tmp")" > "$tmp.trim" && mv "$tmp.trim" "$tmp"
    [[ -s "$tmp" ]] && printf '\n' >> "$tmp"
  fi

  cooee_build_brief_guide_block >> "$tmp" || {
    rm -f "$tmp"; warn "java: couldn't render the build-brief guide; skipping."; return 0; }

  if mv "$tmp" "$md"; then
    ok "java: build-brief usage guide written to ${md/#$HOME/\~} (opt out: COOEE_NO_BUILD_BRIEF_GUIDE=1)."
  else
    rm -f "$tmp"; warn "java: couldn't write ${md/#$HOME/\~}; skipping the build-brief guide."
  fi
  return 0
}

# The guide itself. Rules 1-6 are build-brief's own documented behaviour (the
# block `build-brief --install` writes); the rest is what this environment adds.
cooee_build_brief_guide_block() {
  printf '%s\n' "$COOEE_BUILD_BRIEF_MARK_START"
  cat <<'MD'
## Gradle: run it through `build-brief`

This environment installed [`build-brief`](https://bb.staticvar.dev) because the
checkout builds with Gradle. It keeps the full log on disk and prints only the
parts that decide what you do next — failed tasks, failed tests, warnings, build
scan URLs, artifact paths — and it preserves Gradle's exit code exactly. Use it
for every Gradle invocation; `check` and render pipelines otherwise bury their
one real line in thousands.

- Prefer `build-brief ./gradlew ...` for the project wrapper, `build-brief gradle ...` for a PATH Gradle.
- Rewrite each Gradle segment of a chained command separately: `build-brief ./gradlew test && build-brief ./gradlew check`.
- The default output is intentionally short on clean success — that is the tool working, not output going missing.
- Report-style commands (`tasks`, `help`, `projects`, `dependencies`, `dependencyInsight`) keep their full bodies, so dependency debugging is unaffected.
- `build-brief ./gradlew --stacktrace ...` when you need Gradle's stack traces. Output-shaping flags (`--quiet`, `--warn`, `--warning-mode`, `--console`) are normalized, and explicit `--daemon` / `--no-daemon` are stripped so daemon reuse still happens.
- Preserve the raw log path it prints when handing a failure to another tool or agent — that file has everything the brief dropped.
- `build-brief doctor` is read-only and never runs Gradle; use it to check the setup.

Two things specific to this environment:

- **If the checkout ships its own Gradle launcher, prefer it.** A repo that caps
  automated builds on a shared host (e.g. `scripts/agent-gradle.sh`) already
  wraps `build-brief` and adds its own worker/priority limits; it requires
  `build-brief` on PATH, which is why this environment installs it. Follow that
  repo's rules for when to take its exclusive/serialized profile (typically
  `check` and broad render pipelines).
- **Don't run `build-brief --install` in a checkout.** It rewrites that repo's
  git-tracked `AGENTS.md`; these rules are installed in the environment instead,
  so a provisioned working tree stays clean.
MD
  printf '%s\n' "$COOEE_BUILD_BRIEF_MARK_END"
}
