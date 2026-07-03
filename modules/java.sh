
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
need_host cache.nixos.org      "prebuilt Temurin JDK from the Nix cache"
want_host services.gradle.org  "Gradle distributions (wrapper download; 307-redirects to GitHub releases)"
want_host github.com           "Gradle distribution redirect target (gradle/gradle-distributions releases)"
want_host api.github.com       "GitHub release API for JDK/tool provisioning (Adoptium et al. resolve download URLs here)"
want_host release-assets.githubusercontent.com "GitHub release-asset CDN serving the Gradle distribution zip (current host)"
want_host objects.githubusercontent.com "GitHub release-asset CDN (legacy host; still used for some assets)"
want_host downloads.gradle.org "Gradle direct-download host (legacy/non-wrapper distribution URLs)"
want_host repo.gradle.org      "Gradle libraries / tooling artifacts"
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
    ok "java: adopted existing $(java -version 2>&1 | head -1) (JAVA_HOME=$JAVA_HOME)."
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

  ok "java ready: $(java -version 2>&1 | head -1)"

  cooee_prefetch_gradle
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
