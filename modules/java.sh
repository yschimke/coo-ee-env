
# ===========================================================================
#  module: java
#    software : Temurin JDK (via Nix), JAVA_HOME, JDK TLS fix
#    params   : java[17,21] picks the JDK majors. With no param, defaults to the
#               JDK the project pins for its Gradle build (toolchainVersion in
#               gradle/gradle-daemon-jvm.properties), else 21 — or 17 + 21 when
#               android is also being installed.
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

module_java() {
  # Requested JDK majors come from the request params (java[17,21]).
  local -a versions=("$@")

  # Already provisioned (warm box) or provided by the cloud base image? Adopt
  # the existing JDK — set JAVA_HOME from it and skip the redundant Nix install.
  # A ready JDK is the right answer regardless of the requested/detected version.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v java >/dev/null 2>&1; then
    add_env JAVA_HOME "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    cooee_trust_cas_in_jdk "$JAVA_HOME"
    cooee_jvm_proxy_opts
    cooee_jvm_utf8_opts
    ok "java: adopted existing $(java -version 2>&1 | head -1) (JAVA_HOME=$JAVA_HOME)."
    cooee_seed_gradle_wrapper
    cooee_prefetch_gradle
    return 0
  fi

  # With no explicit param, pick a default. Prefer the JDK the project itself
  # pins for its Gradle build (gradle/gradle-daemon-jvm.properties), so the env
  # matches what `./gradlew` runs on without repeating the version in the URL.
  # Otherwise default to 21 (the current LTS most repos here run on) — or 17 + 21
  # when android is also being installed, since the Android toolchain (AGP/Gradle)
  # still pins to 17 while app code targets 21. Each major maps to a
  # nixpkgs#temurin-bin-<major>.
  if (( ! ${#versions[@]} )); then
    local detected; detected=$(cooee_java_project_version)
    if [[ -n "$detected" ]]; then
      versions=("$detected")
      log "java: defaulting to JDK ${detected} pinned by the project's Gradle daemon (gradle/gradle-daemon-jvm.properties)."
    elif cooee_module_requested android; then
      versions=(17 21)
    else
      versions=(21)
    fi
  fi

  # Let the backend decide which of the requested majors it can install: the nix
  # backend keeps them all (each gets its own --priority below), the devenv
  # backend keeps only the first (one buildEnv can't hold two colliding JDKs).
  mapfile -t versions < <(cooee_backend_jdks "${versions[@]}")

  log "Installing Temurin JDK (${versions[*]}) via Nix..."
  # Multiple JDKs ship colliding files (e.g. lib/modules), so a single profile
  # can't hold them at the same priority — `nix profile add` aborts. Give each a
  # distinct priority (lower wins), ascending from 5 in request order. Params are
  # canonicalized ascending, so the lowest JDK owns the java/javac symlinks (the
  # toolchain most repos here pin to) and the rest stay discoverable by Gradle
  # toolchain resolution.
  local v prio=5
  for v in "${versions[@]}"; do
    nix_ensure "temurin-bin-$v" "nixpkgs#temurin-bin-$v" --accept-flake-config --priority "$prio"
    prio=$((prio + 1))
  done

  # JAVA_HOME -> the active (priority-winning) JDK, i.e. the lowest requested.
  command -v java >/dev/null 2>&1 || die "java not on PATH after install."
  add_env JAVA_HOME "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"

  # Cloud fix: a Nix JDK ignores the system trust store, so teach it about the
  # sandbox proxy CA now (otherwise Gradle HTTPS fails with PKIX errors).
  cooee_trust_cas_in_jdk "$JAVA_HOME"
  # Cloud fix: route the JVM through the sandbox proxy (it ignores http(s)_proxy),
  # so the Gradle wrapper/daemon can actually reach services.gradle.org et al.
  cooee_jvm_proxy_opts
  # Cloud fix: force a UTF-8 locale + JVM file encoding so Gradle report paths
  # with non-ASCII chars don't die with "unmappable character" under a C locale.
  cooee_jvm_utf8_opts

  ok "java ready: $(java -version 2>&1 | head -1)"

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
  local root="${COOEE_CHECKOUTS_DIR:-}"
  if [[ -z "$root" ]]; then
    local dir; dir=$(cooee_project_dir)
    root=$(dirname "$dir")   # workspace root = the parent holding the checkouts
    # Never root the scan at a broad system directory — fall back to the project
    # dir itself, so a single-repo layout still gets its own wrapper seeded.
    case "$root" in ""|.|/|/home|/Users|/root|/usr|/var|/opt|/tmp) root="$dir" ;; esac
  fi
  [[ -d "$root" ]] || return 0
  find "$root" -maxdepth 5 -type f \
    -path '*/gradle/wrapper/gradle-wrapper.properties' 2>/dev/null | sort
}

# distributionUrl from a gradle-wrapper.properties, unescaping the properties-file
# '\:' -> ':' and stripping any trailing CR. Empty output when absent.
cooee_gradle_distribution_url() {
  local props="$1" url
  [[ -f "$props" ]] || return 0
  url=$(sed -n 's/^[[:space:]]*distributionUrl[[:space:]]*=[[:space:]]*//p' "$props" | head -1)
  url="${url%$'\r'}"; url="${url//\\:/:}"
  printf '%s' "$url"
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

  # Where the wrapper looks: <dists>/<distname>/<hash>/, hash = base36(md5(url)).
  # GRADLE_USER_HOME defaults to ~/.gradle; distributionPath to wrapper/dists.
  local hash; hash=$(cooee_gradle_wrapper_hash "$url") \
    || { warn "java: couldn't compute the wrapper cache hash for $repo; leaving the wrapper download to Gradle."; return 0; }
  local dest="${GRADLE_USER_HOME:-$HOME/.gradle}/wrapper/dists/$distname/$hash"

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
