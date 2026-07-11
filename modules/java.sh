
# ===========================================================================
#  module: java
#    software : Temurin JDK (via Nix), JAVA_HOME, JDK TLS fix
#    params   : java[17,21] picks the JDK majors. With no param, defaults to
#               BOTH 17 and 21 (the LTS majors this fleet builds against — AGP /
#               Gradle still pin 17 while app code targets 21), plus any distinct
#               toolchainVersion the project pins in gradle/gradle-daemon-jvm.properties.
#               Missing majors are installed via Nix; ones the base image already
#               ships are adopted, so "17 + 21" is cheap when one is present.
#    hosts    : cache.nixos.org (install)
#             : Gradle / Maven / toolchain registries (build; used by the
#               best-effort dependency prefetch, advisory — opt out COOEE_NO_DEPS=1)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
# ===========================================================================
register_module java
provides_tool java java   # adopt an existing JDK (warm box or cloud base image)
# Pre-approve the JVM build toolchain for Claude Code sessions.
provides_perms java "Bash(./gradlew:*)" "Bash(gradle:*)" "Bash(java:*)" "Bash(javac:*)" "Bash(kotlin:*)" "Bash(kotlinc:*)" "Bash(mvn:*)"
need_host cache.nixos.org      "prebuilt Temurin JDK from the Nix cache"
want_host services.gradle.org  "Gradle distributions (wrapper download; 307-redirects to GitHub releases)"
want_host github.com           "Gradle distribution redirect target (gradle/gradle-distributions releases)"
want_host api.github.com       "GitHub release API for JDK/tool provisioning (Adoptium et al. resolve download URLs here)"
want_host release-assets.githubusercontent.com "GitHub release-asset CDN serving the Gradle distribution zip (current host)"
want_host objects.githubusercontent.com "GitHub release-asset CDN (legacy host; still used for some assets)"
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

  ok "java ready: $("$JAVA_HOME/bin/java" -version 2>&1 | head -1) (toolchains: ${versions[*]})"

  cooee_seed_gradle_wrapper
  cooee_prefetch_gradle
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
