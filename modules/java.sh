
# ===========================================================================
#  module: java
#    software : Temurin JDK (via Nix), JAVA_HOME, JDK TLS fix
#    params   : java[17,21] picks the JDK majors; default 17 + 21
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

module_java() {
  # Requested JDK majors come from the request params (java[17,21]); default to
  # 17 + 21, the toolchains most repos here pin to. Each maps to a
  # nixpkgs#temurin-bin-<major>.
  local -a versions=("$@")
  (( ${#versions[@]} )) || versions=(17 21)

  # Already provisioned (warm box) or provided by the cloud base image? Adopt
  # the existing JDK — set JAVA_HOME from it and skip the redundant Nix install.
  if [[ "${COOEE_FORCE:-0}" != 1 ]] && command -v java >/dev/null 2>&1; then
    add_env JAVA_HOME "$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
    cooee_trust_cas_in_jdk "$JAVA_HOME"
    ok "java: adopted existing $(java -version 2>&1 | head -1) (JAVA_HOME=$JAVA_HOME)."
    return 0
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
