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
    env: { ...process.env, ...env },
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

test("org.gradle.java.home is written, and someone else's value is respected", () => {
  const guh = scratch("guh");
  const mine = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JDK_GL_DIR=/wrap
    cooee_gradle_props_java_home /wrap/17 >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(mine, "org.gradle.java.home=/wrap/17");

  const other = scratch("guh2");
  fs.writeFileSync(
    path.join(other, "gradle.properties"),
    "org.gradle.java.home=/opt/my/jdk\n",
  );
  const kept = run(`
    GRADLE_USER_HOME="${other}"
    COOEE_JDK_GL_DIR=/wrap
    cooee_gradle_props_java_home /wrap/17 >/dev/null
    cat "${other}/gradle.properties"
  `);
  assert.equal(kept, "org.gradle.java.home=/opt/my/jdk");
});

test("our own stale org.gradle.java.home is refreshed, not duplicated", () => {
  const guh = scratch("guh3");
  fs.writeFileSync(
    path.join(guh, "gradle.properties"),
    "org.gradle.jvmargs=-Xmx2g\norg.gradle.java.home=/wrap/17\n",
  );
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JDK_GL_DIR=/wrap
    cooee_gradle_props_java_home /wrap/21 >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(out, "org.gradle.jvmargs=-Xmx2g\norg.gradle.java.home=/wrap/21");
});

test("COOEE_NO_GRADLE_PROPS=1 leaves gradle.properties alone", () => {
  const guh = scratch("guh4");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_NO_GRADLE_PROPS=1
    cooee_gradle_props_java_home /wrap/17 >/dev/null
    [ -e "${guh}/gradle.properties" ] && echo written || echo untouched
  `);
  assert.equal(out, "untouched");
});
