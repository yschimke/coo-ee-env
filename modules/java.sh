
# ===========================================================================
#  module: java
#    software : Temurin JDK (via Nix), JAVA_HOME, JDK TLS fix
#    params   : java[17,21] picks the JDK majors. With no param, defaults to the
#               JDK the project pins for its Gradle build (toolchainVersion in
#               gradle/gradle-daemon-jvm.properties), else 21 — or 17 + 21 when
#               android is also being installed.
#    hosts    : cache.nixos.org (install)
#             : Gradle / Maven / toolchain registries (build, advisory)
#  Host set mirrors skills/compose-preview/references/agent-cloud.md.
# ===========================================================================
register_module java
provides_tool java java   # adopt an existing JDK (warm box or cloud base image)
need_host cache.nixos.org      "prebuilt Temurin JDK from the Nix cache"
want_host services.gradle.org  "Gradle distributions (wrapper download)"
want_host repo.gradle.org      "Gradle libraries / tooling artifacts"
want_host central.sonatype.com "Maven Central artifacts"
want_host api.foojay.io        "Java distro metadata for Gradle toolchains"
want_host api.adoptium.net     "JDK/toolchain provisioning API"
want_host jitpack.io           "dependencies published via JitPack"

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
    ok "java: adopted existing $(java -version 2>&1 | head -1) (JAVA_HOME=$JAVA_HOME)."
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

  ok "java ready: $(java -version 2>&1 | head -1)"
}
