// Tests for the GL-aware render JDK the compose module builds.
//
// Compose Desktop renders through skiko, whose libskiko-linux-x64.so has
// DT_NEEDED entries on libGL/libX11/libfontconfig/libstdc++. Handing those to the
// render JVM via LD_LIBRARY_PATH only works if every hop exports it, and Claude
// Code's web sessions don't: they replay the SessionStart hook's environment as
// bare `KEY=value` assignments with no `export`, so a *new* variable never
// reaches the Gradle daemon or the render worker it forks. The fix is to stop
// relying on the variable — bake the GL dir into a wrapper JDK and point
// JAVA_HOME at it. These tests pin that wrapper's shape and the cases where it
// deliberately does nothing.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("compose").body.replace(/^main "\$@"$/m, ":");

function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-gl-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    // GRADLE_USER_HOME defaults to a scratch dir, never the real ~/.gradle: the footer hook
    // writes an init script there and rewrites gradle.properties, so a test that forgot to
    // point it somewhere safe would provision the machine running the suite. A snippet that
    // sets it itself still wins.
    env: { ...process.env, GRADLE_USER_HOME: path.join(dir, "gradle-user-home"), ...env },
  }).trim();
}

/** A minimal fake JDK: bin/java that echoes its own argv, plus the usual dirs. */
function fakeJdk(root, { major = "17" } = {}) {
  fs.mkdirSync(path.join(root, "bin"), { recursive: true });
  fs.mkdirSync(path.join(root, "lib"), { recursive: true });
  fs.mkdirSync(path.join(root, "conf"), { recursive: true });
  fs.writeFileSync(path.join(root, "release"), `JAVA_VERSION="${major}.0.1"\n`);
  fs.writeFileSync(
    path.join(root, "bin", "java"),
    '#!/bin/sh\necho "real-java ${LD_LIBRARY_PATH:-unset}"\n',
    { mode: 0o755 },
  );
  fs.writeFileSync(path.join(root, "bin", "javac"), "#!/bin/sh\n:\n", { mode: 0o755 });
  return root;
}

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

test("the wrapper's java prepends the GL dir and execs the real launcher", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "real"));
  const out = run(`
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    w=$(cooee_build_gl_jdk_wrapper "${real}" /opt/gl/lib 17)
    "$w/bin/java" -version
  `);
  assert.equal(out, "real-java /opt/gl/lib");
});

test("an inherited LD_LIBRARY_PATH is prepended to, never replaced", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "real"));
  const out = run(`
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    w=$(cooee_build_gl_jdk_wrapper "${real}" /opt/gl/lib 17)
    LD_LIBRARY_PATH=/caller/lib "$w/bin/java" -version
  `);
  assert.equal(out, "real-java /opt/gl/lib:/caller/lib");
});

test("every other JDK entry is symlinked through to the real JDK", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "real"));
  const out = run(`
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    w=$(cooee_build_gl_jdk_wrapper "${real}" /opt/gl/lib 17)
    # release/lib/conf resolve, javac is a symlink, java is a real file (the shim)
    head -1 "$w/release"
    [ -L "$w/lib" ] && echo lib-linked
    [ -L "$w/bin/javac" ] && echo javac-linked
    [ -L "$w/bin/java" ] || echo java-is-shim
  `);
  assert.equal(out, 'JAVA_VERSION="17.0.1"\nlib-linked\njavac-linked\njava-is-shim');
});

test("rebuilding drops stale entries from a previous JDK", () => {
  const first = fakeJdk(path.join(scratch("jdk"), "first"));
  const second = fakeJdk(path.join(scratch("jdk"), "second"));
  fs.writeFileSync(path.join(first, "bin", "jshell"), "#!/bin/sh\n:\n", { mode: 0o755 });
  const out = run(`
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    cooee_build_gl_jdk_wrapper "${first}" /opt/gl/lib 17 >/dev/null
    w=$(cooee_build_gl_jdk_wrapper "${second}" /opt/gl/lib 17)
    [ -e "$w/bin/jshell" ] && echo stale-jshell-kept || echo stale-jshell-gone
  `);
  assert.equal(out, "stale-jshell-gone");
});

test("store JDKs are wrapped; ordinary ones are left alone", () => {
  const out = run(`
    cooee_jdk_loader_reads_system_cache /nix/store/abc-temurin-17 && echo nix-reads || echo nix-blind
    cooee_jdk_loader_reads_system_cache /gnu/store/abc-openjdk-21 && echo guix-reads || echo guix-blind
    cooee_jdk_loader_reads_system_cache /usr/lib/jvm/temurin-17 && echo sys-reads || echo sys-blind
  `);
  assert.equal(out, "nix-blind\nguix-blind\nsys-reads");
});

test("no GL provisioning means no wrapper and no JAVA_HOME change", () => {
  const out = run(`
    COOEE_DESKTOP_GL_LIB=""
    JAVA_HOME=/nix/store/abc-temurin-17
    cooee_compose_wrap_render_jdk
    echo "JAVA_HOME=$JAVA_HOME"
  `);
  assert.equal(out, "JAVA_HOME=/nix/store/abc-temurin-17");
});

test("a non-store JAVA_HOME is left untouched — its loader finds system libs", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "sys"));
  const out = run(`
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null
    echo "JAVA_HOME=$JAVA_HOME"
  `);
  assert.equal(out, `JAVA_HOME=${real}`);
});

// ---------------------------------------------------------------------------
// Who is allowed to SEE the store libraries. compose-ai-tools#3690: a
// session-wide LD_LIBRARY_PATH reaches every JVM, and a store lib inside a JVM
// linked against the system glibc is a hard dlopen failure, not a degraded one.
// So the wrapper JDK is the only carrier, and the environment stays clean.
// ---------------------------------------------------------------------------

/** Env pointing the profile / harness files at scratch paths, never the real ones. */
function envFiles() {
  const dir = scratch("envfiles");
  return {
    COOEE_PROFILE: path.join(dir, "env.sh"),
    COOEE_HARNESS_ENV: path.join(dir, "env.harness"),
    CLAUDE_ENV_FILE: path.join(dir, "claude.env"),
  };
}

test("a wrapped store JDK carries the libs alone — nothing lands on LD_LIBRARY_PATH", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "store"));
  const files = envFiles();
  // A previous run of this module forwarded the variable; this run must retire it, since the
  // harness replays that file into every command it spawns.
  fs.writeFileSync(
    files.CLAUDE_ENV_FILE,
    "ANDROID_HOME=/opt/sdk\nLD_LIBRARY_PATH=/nix/store/gl/lib\n",
  );

  const out = run(
    `
    cooee_jdk_loader_reads_system_cache() { return 1; }   # pretend a store JDK
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    COOEE_NO_GRADLE_PROPS=1
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null
    echo "LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:-unset}"
    echo "JAVA_HOME=$JAVA_HOME"
  `,
    files,
  );

  assert.match(out, /^LD_LIBRARY_PATH=unset$/m);
  assert.match(out, /JAVA_HOME=.*\/17$/m);
  // Retired from the harness file, and only that key — other hooks' lines are not ours to drop.
  const harness = fs.readFileSync(files.CLAUDE_ENV_FILE, "utf8");
  assert.equal(harness.includes("LD_LIBRARY_PATH"), false);
  assert.equal(harness.includes("ANDROID_HOME=/opt/sdk"), true);
});

test("a non-store JDK gets no GL environment at all, and a stale one is retired", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "sys"));
  const files = envFiles();
  fs.writeFileSync(files.CLAUDE_ENV_FILE, "LD_LIBRARY_PATH=/nix/store/gl/lib\n");

  const out = run(
    `
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null
    echo "LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:-unset}"
  `,
    files,
  );

  assert.equal(out, "LD_LIBRARY_PATH=unset");
  assert.equal(fs.readFileSync(files.CLAUDE_ENV_FILE, "utf8").includes("LD_LIBRARY_PATH"), false);
});

test("when the wrapper can't be built, LD_LIBRARY_PATH is still the fallback", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "store"));
  const files = envFiles();

  const out = run(
    `
    cooee_jdk_loader_reads_system_cache() { return 1; }   # pretend a store JDK
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR=/proc/nowhere/jdk-gl                 # mkdir will fail here
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null 2>&1
    echo "LD_LIBRARY_PATH=\${LD_LIBRARY_PATH:-unset}"
  `,
    files,
  );

  // A possibly-mismatched search path still beats a certainly-missing libGL, and the render
  // plugin prunes the store dirs for a non-store render JVM anyway.
  assert.equal(out, "LD_LIBRARY_PATH=/opt/gl/lib");
  assert.match(fs.readFileSync(files.CLAUDE_ENV_FILE, "utf8"), /^LD_LIBRARY_PATH=\/opt\/gl\/lib$/m);
});

// ---------------------------------------------------------------------------
// org.gradle.java.home. Pinning the wrapper there was how the daemon used to be
// given the GL libs, and Gradle 9 rejects the daemon it produces outright — the
// daemon reports java.home from the REAL JDK (where its libjli lives), so the
// context check can never match the wrapper path that asked for it, and every
// daemon build in the session dies with "The newly created daemon process has a
// different context than expected". Warm boxes still carry the line.
// ---------------------------------------------------------------------------

test("our own wrapper pin is removed, and the rest of the file is left intact", () => {
  const guh = scratch("guh");
  fs.writeFileSync(
    path.join(guh, "gradle.properties"),
    "org.gradle.jvmargs=-Xmx2g\norg.gradle.java.home=/wrap/17\norg.gradle.caching=true\n",
  );
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JDK_GL_DIR=/wrap
    cooee_gradle_props_unpin_java_home >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(out, "org.gradle.jvmargs=-Xmx2g\norg.gradle.caching=true");
});

test("someone else's org.gradle.java.home is never touched", () => {
  const guh = scratch("guh2");
  fs.writeFileSync(path.join(guh, "gradle.properties"), "org.gradle.java.home=/opt/my/jdk\n");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JDK_GL_DIR=/wrap
    cooee_gradle_props_unpin_java_home >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(out, "org.gradle.java.home=/opt/my/jdk");
});

test("wrapping a store JDK no longer pins it as the daemon JVM", () => {
  const real = fakeJdk(path.join(scratch("jdk"), "store"));
  const guh = scratch("guh3");
  fs.writeFileSync(path.join(guh, "gradle.properties"), "org.gradle.caching=true\n");
  const wrapDir = scratch("wrap");
  const out = run(
    `
    cooee_jdk_loader_reads_system_cache() { return 1; }   # pretend a store JDK
    GRADLE_USER_HOME="${guh}"
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR="${wrapDir}"
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null
    echo "JAVA_HOME=$JAVA_HOME"
    cat "${guh}/gradle.properties"
  `,
    envFiles(),
  );
  // JAVA_HOME still points at the wrapper — a bare `java` render is worth fixing — but Gradle
  // is left to choose the daemon JVM itself, and the fork boundary does the rest.
  assert.match(out, new RegExp(`^JAVA_HOME=${wrapDir}/17$`, "m"));
  assert.equal(out.includes("org.gradle.java.home"), false);
  assert.match(out, /^org\.gradle\.caching=true$/m);
});

test("a stale pin is retired even when this run builds no wrapper at all", () => {
  const guh = scratch("guh4");
  fs.writeFileSync(path.join(guh, "gradle.properties"), "org.gradle.java.home=/wrap/17\n");
  const out = run(
    `
    GRADLE_USER_HOME="${guh}"
    COOEE_DESKTOP_GL_LIB=""            # GL provisioning skipped or failed this run
    COOEE_JDK_GL_DIR=/wrap
    JAVA_HOME=/nix/store/abc-temurin-17
    cooee_compose_wrap_render_jdk >/dev/null
    cat "${guh}/gradle.properties"
  `,
    envFiles(),
  );
  assert.equal(out, "");
});


// ---------------------------------------------------------------------------
// The fork boundary. The wrapper fixes the JVM it launches and nothing it
// forks: `exec java` with LD_LIBRARY_PATH exported hands the store GL dir to
// every descendant of the Gradle daemon, whatever JDK that descendant runs on.
// On a mixed fleet — a Nix JDK 17 beside the image's own system JDK 21 —
// `jvmToolchain(21)` forks a system-glibc worker out of a store-glibc daemon and
// skiko dies on `GLIBC_ABI_DT_X86_64_PLT'. So a Gradle init script retunes
// LD_LIBRARY_PATH per fork, in both directions.
// ---------------------------------------------------------------------------

const INIT_REL = path.join("init.d", "cooee-desktop-gl.init.gradle");

test("the init script hands the GL dir to store JDKs and withholds it from the rest", () => {
  const guh = scratch("guh-init");
  run(`
    GRADLE_USER_HOME="${guh}"
    cooee_gradle_init_desktop_gl /opt/gl/lib >/dev/null
  `);
  const init = fs.readFileSync(path.join(guh, INIT_REL), "utf8");

  assert.match(init, /def glDir = '\/opt\/gl\/lib'/);
  // Store prefixes decide, exactly as cooee_jdk_loader_reads_system_cache does.
  assert.match(init, /'\/nix\/store\/'/);
  assert.match(init, /'\/gnu\/store\/'/);
  // Both directions: our dir is always dropped first, and re-added only for a JDK that can use it.
  assert.match(init, /if \(p != glDir\) parts\.add\(p\)/);
  assert.match(init, /if \(wantsGl\(jdkHome\(task\)\)\) parts\.add\(0, glDir\)/);
  // Test workers and JavaExec forks are the two ways a render JVM is started.
  assert.match(init, /org\.gradle\.api\.tasks\.testing\.Test/);
  assert.match(init, /org\.gradle\.api\.tasks\.JavaExec/);
});

test("rewriting the init script tracks a moved GL dir instead of stacking rules", () => {
  const guh = scratch("guh-init2");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    cooee_gradle_init_desktop_gl /old/gl/lib >/dev/null
    cooee_gradle_init_desktop_gl /new/gl/lib >/dev/null
    ls "${guh}/init.d" | wc -l
  `);
  assert.equal(out, "1");
  const init = fs.readFileSync(path.join(guh, INIT_REL), "utf8");
  assert.match(init, /def glDir = '\/new\/gl\/lib'/);
  assert.equal(init.includes("/old/gl/lib"), false);
});

test("no GL dir retires an init script an earlier run left behind", () => {
  const guh = scratch("guh-init3");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    cooee_gradle_init_desktop_gl /opt/gl/lib >/dev/null
    cooee_gradle_init_desktop_gl "" >/dev/null
    [ -e "${guh}/${INIT_REL}" ] && echo kept || echo retired
  `);
  assert.equal(out, "retired");
});

test("the init script is opt-out, by its own flag and by the Gradle-props one", () => {
  for (const flag of ["COOEE_NO_GRADLE_INIT", "COOEE_NO_GRADLE_PROPS"]) {
    const guh = scratch(`guh-init-${flag}`);
    const out = run(`
      GRADLE_USER_HOME="${guh}"
      ${flag}=1
      cooee_gradle_init_desktop_gl /opt/gl/lib >/dev/null
      [ -e "${guh}/${INIT_REL}" ] && echo written || echo skipped
    `);
    assert.equal(out, "skipped", `${flag} should suppress the init script`);
  }
});

test("a non-store JAVA_HOME still gets the init script — the fork boundary is its own problem", () => {
  // The daemon JVM needing no wrapper says nothing about the JDKs Gradle forks: a system-JDK
  // daemon can still fork a store toolchain worker, which is the one hop the wrapper can never
  // reach (Gradle canonicalises a detected toolchain past the shim, to the real launcher).
  const real = fakeJdk(path.join(scratch("jdk"), "sys"));
  const guh = scratch("guh-init4");
  const out = run(
    `
    GRADLE_USER_HOME="${guh}"
    COOEE_DESKTOP_GL_LIB=/opt/gl/lib
    COOEE_JDK_GL_DIR="${scratch("wrap")}"
    JAVA_HOME="${real}"
    cooee_compose_wrap_render_jdk >/dev/null
    grep -c "def glDir = '/opt/gl/lib'" "${guh}/${INIT_REL}"
  `,
    envFiles(),
  );
  assert.equal(out, "1");
});
