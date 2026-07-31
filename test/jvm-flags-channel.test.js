// Tests for how the cloud JVM flags (proxy, extra-CA truststore, UTF-8) reach a
// build, and — just as important — how they DON'T.
//
// Harnesses replay their env files as unquoted shell, one KEY=value line per
// line, inlined into every command. JAVA_TOOL_OPTIONS is unavoidably
// space-separated and its nonProxyHosts value is pipe-separated, so forwarding
// it turns each later command into
//   JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=p   # assignment
//   -Dhttp.proxyPort=8080                  # "command not found"
//   a | b | c                              # a pipeline of more not-founds
// for the rest of the session. So it stays shell-only, is restored to its entry
// value before exit, and Gradle gets the flags through org.gradle.jvmargs.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("java").body.replace(/^main "\$@"$/m, ":");

/** `env` values of null delete that variable, so a test can run with it unset. */
function run(snippet, env = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-jf-"));
  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  const merged = { ...process.env, ...env };
  for (const [k, v] of Object.entries(env)) if (v === null) delete merged[k];
  return execFileSync("bash", [file], { encoding: "utf8", env: merged }).trim();
}

function scratch(name) {
  return fs.mkdtempSync(path.join(os.tmpdir(), `cooee-${name}-`));
}

test("JAVA_TOOL_OPTIONS is never written to a harness env file", () => {
  const out = run(`
    export CLAUDE_ENV_FILE="$(mktemp)"
    COOEE_PROFILE="$(mktemp)"; COOEE_HARNESS_ENV="$(mktemp)"
    add_env JAVA_TOOL_OPTIONS "-Dhttp.proxyHost=p -Dhttp.nonProxyHosts=a|b"
    add_env ANDROID_HOME /opt/android-sdk
    cat "$CLAUDE_ENV_FILE"
  `);
  assert.equal(out, "ANDROID_HOME=/opt/android-sdk");
});

test("…nor to the replayable harness-env mirror", () => {
  const harness = path.join(scratch("h"), "env.harness");
  const out = run(`
    COOEE_PROFILE="$(mktemp)"; COOEE_HARNESS_ENV="${harness}"
    add_env JAVA_TOOL_OPTIONS "-Dhttp.proxyHost=p -Dx=y"
    add_env LANG C.UTF-8
    cat "${harness}"
  `);
  assert.equal(out, "LANG=C.UTF-8");
});

test("but it IS exported for this run and persisted, shell-quoted, to the profile", () => {
  const profile = path.join(scratch("p"), "env.sh");
  const out = run(`
    COOEE_PROFILE="${profile}"; COOEE_HARNESS_ENV="$(mktemp)"
    add_env JAVA_TOOL_OPTIONS "-Dhttp.proxyHost=p -Dhttp.nonProxyHosts=a|b"
    echo "live=[$JAVA_TOOL_OPTIONS]"
  `);
  assert.equal(out, "live=[-Dhttp.proxyHost=p -Dhttp.nonProxyHosts=a|b]");

  // The persisted line must survive a re-source with the value intact — which is
  // exactly what quoting buys, and what the harness path lacks.
  const back = run(`
    unset JAVA_TOOL_OPTIONS
    . "${profile}"
    echo "restored=[$JAVA_TOOL_OPTIONS]"
  `);
  assert.equal(back, "restored=[-Dhttp.proxyHost=p -Dhttp.nonProxyHosts=a|b]");
});

test("the profile line is a single assignment, not shell-splittable", () => {
  const profile = path.join(scratch("p"), "env.sh");
  run(`
    COOEE_PROFILE="${profile}"; COOEE_HARNESS_ENV="$(mktemp)"
    add_env JAVA_TOOL_OPTIONS "-Da=1 -Db=2"
  `);
  const line = fs.readFileSync(profile, "utf8").trim();
  // %q quoting — the value must not sit bare with a space in it.
  assert.ok(!/^export JAVA_TOOL_OPTIONS=-Da=1 -Db=2$/.test(line), `unquoted: ${line}`);
});

test("JAVA_TOOL_OPTIONS is restored to its entry value", () => {
  const out = run(`
    COOEE_PROFILE="$(mktemp)"; COOEE_HARNESS_ENV="$(mktemp)"
    cooee_add_jvm_flag "-Dfile.encoding=UTF-8"
    echo "during=[$JAVA_TOOL_OPTIONS]"
    cooee_restore_java_tool_options
    echo "after=[$JAVA_TOOL_OPTIONS]"
  `, { JAVA_TOOL_OPTIONS: "-Doriginal=1" });
  assert.equal(out, "during=[-Doriginal=1 -Dfile.encoding=UTF-8]\nafter=[-Doriginal=1]");
});

test("an unset JAVA_TOOL_OPTIONS is restored to unset, not to empty", () => {
  const out = run(`
    COOEE_PROFILE="$(mktemp)"; COOEE_HARNESS_ENV="$(mktemp)"
    cooee_add_jvm_flag "-Dfile.encoding=UTF-8"
    cooee_restore_java_tool_options
    [ -n "\${JAVA_TOOL_OPTIONS+x}" ] && echo set || echo unset
  `, { JAVA_TOOL_OPTIONS: null });
  assert.equal(out, "unset");
});

test("cooee_add_jvm_flag records flags for the Gradle pin", () => {
  const out = run(`
    COOEE_PROFILE="$(mktemp)"; COOEE_HARNESS_ENV="$(mktemp)"
    cooee_add_jvm_flag "-Djavax.net.ssl.trustStore=/s/cacerts"
    cooee_add_jvm_flag "-Dhttp.proxyHost=p" "-Dhttp.proxyPort=8080"
    echo "$COOEE_JVM_FLAGS"
  `);
  assert.equal(out, "-Djavax.net.ssl.trustStore=/s/cacerts -Dhttp.proxyHost=p -Dhttp.proxyPort=8080");
});

test("the flags land on org.gradle.jvmargs when there is no file", () => {
  const guh = scratch("guh");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JVM_FLAGS="-Dfile.encoding=UTF-8 -Dhttp.proxyHost=p"
    cooee_gradle_props_jvmargs >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(out, "org.gradle.jvmargs=-Dfile.encoding=UTF-8 -Dhttp.proxyHost=p");
});

test("an existing jvmargs line is extended, not replaced", () => {
  const guh = scratch("guh");
  fs.writeFileSync(path.join(guh, "gradle.properties"), "org.gradle.jvmargs=-Xmx4g\n");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JVM_FLAGS="-Dfile.encoding=UTF-8"
    cooee_gradle_props_jvmargs >/dev/null
    cat "${guh}/gradle.properties"
  `);
  assert.equal(out, "org.gradle.jvmargs=-Xmx4g -Dfile.encoding=UTF-8");
});

test("a property the user already set is never overridden", () => {
  const guh = scratch("guh");
  fs.writeFileSync(
    path.join(guh, "gradle.properties"),
    "org.gradle.jvmargs=-Xmx4g -Dfile.encoding=ISO-8859-1\n",
  );
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_JVM_FLAGS="-Dfile.encoding=UTF-8 -Dhttp.proxyHost=p"
    cooee_gradle_props_jvmargs >/dev/null
    cat "${guh}/gradle.properties"
  `);
  // Their charset survives; the flag they hadn't set is still added.
  assert.equal(out, "org.gradle.jvmargs=-Xmx4g -Dfile.encoding=ISO-8859-1 -Dhttp.proxyHost=p");
});

test("re-running adds nothing once every flag is present", () => {
  const guh = scratch("guh");
  const twice = `
    GRADLE_USER_HOME="${guh}"
    COOEE_JVM_FLAGS="-Dfile.encoding=UTF-8 -Dhttp.proxyHost=p"
    cooee_gradle_props_jvmargs >/dev/null
    cooee_gradle_props_jvmargs >/dev/null
    cat "${guh}/gradle.properties"
  `;
  assert.equal(run(twice), "org.gradle.jvmargs=-Dfile.encoding=UTF-8 -Dhttp.proxyHost=p");
});

test("COOEE_NO_GRADLE_PROPS=1 leaves gradle.properties alone", () => {
  const guh = scratch("guh");
  const out = run(`
    GRADLE_USER_HOME="${guh}"
    COOEE_NO_GRADLE_PROPS=1
    COOEE_JVM_FLAGS="-Dfile.encoding=UTF-8"
    cooee_gradle_props_jvmargs >/dev/null
    [ -e "${guh}/gradle.properties" ] && echo written || echo untouched
  `);
  assert.equal(out, "untouched");
});
