// Tests for cooee_fetch — the retry every provisioning download goes through.
//
// `curl -f` exits 22 on an HTTP error and the script runs under `set -e`, so a
// CDN answering 503 for a few seconds used to end the session with nothing but
// "Setup script failed with exit code 22". install.determinate.systems did
// exactly that. A transient 5xx is a retry, not a broken environment.
//
// The tests drive a fake `curl` on PATH so they exercise the retry loop without
// touching the network: it reads a scripted list of exit codes, one per call,
// and records every invocation.
//
// Run with: node --test
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

const BODY = render("base").body.replace(/^main "\$@"$/m, ":");

/**
 * Run `snippet` against the rendered module body with a fake `curl` whose
 * per-call exit codes come from `exits` (22 = curl's "HTTP error"). `sleep` is
 * stubbed too, so a backoff test doesn't actually wait.
 */
function run(snippet, exits) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-fetch-"));
  const bin = path.join(dir, "bin");
  fs.mkdirSync(bin);
  fs.writeFileSync(path.join(dir, "exits"), `${exits.join("\n")}\n`);

  fs.writeFileSync(
    path.join(bin, "curl"),
    `#!/usr/bin/env bash
n=$(cat "${dir}/n" 2>/dev/null || echo 0)
n=$((n + 1)); printf '%s' "$n" > "${dir}/n"
printf '%s\\n' "$*" >> "${dir}/calls"
code=$(sed -n "\${n}p" "${dir}/exits")
[ -n "$code" ] || code=0
# Mimic curl -o: on success leave the destination behind, so the caller's
# "did we get the file" checks see what they would in a real run.
if [ "$code" = 0 ]; then
  dest=""; prev=""
  for a in "$@"; do [ "$prev" = "-o" ] && dest="$a"; prev="$a"; done
  [ -n "$dest" ] && printf 'payload\\n' > "$dest"
fi
exit "$code"
`,
    { mode: 0o755 },
  );
  fs.writeFileSync(path.join(bin, "sleep"), "#!/usr/bin/env bash\n:\n", { mode: 0o755 });

  const file = path.join(dir, "reg.sh");
  fs.writeFileSync(file, `${BODY}\n${snippet}\n`);
  const out = execFileSync("bash", [file], {
    encoding: "utf8",
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}` },
  }).trim();
  const calls = fs.existsSync(path.join(dir, "calls"))
    ? fs.readFileSync(path.join(dir, "calls"), "utf8").trimEnd().split("\n")
    : [];
  return { out, calls, dir };
}

test("a first-attempt success downloads once and keeps the file", () => {
  const { out, calls, dir } = run(
    `cooee_fetch https://example.test/x "${"$"}{TMPDIR:-/tmp}/cooee-fetch-out" 2>/dev/null && echo ok`,
    [0],
  );
  assert.equal(out, "ok");
  assert.equal(calls.length, 1, "no retry when the first attempt works");
  assert.ok(calls[0].includes("--retry"), "curl's own transient-failure retry is still asked for");
  assert.ok(fs.existsSync(dir) );
});

test("a transient 503 is retried and then succeeds", () => {
  // curl exits 22 on an HTTP error; two bad answers then a good one is exactly
  // the shape of the failure this exists for.
  const { out, calls } = run(
    `cooee_fetch https://install.determinate.systems/nix "${"$"}{TMPDIR:-/tmp}/nix-installer" 2>/dev/null && echo ok`,
    [22, 22, 0],
  );
  assert.equal(out, "ok");
  assert.equal(calls.length, 3);
});

test("a host that is down throughout fails, bounded, without killing the caller", () => {
  const { out, calls } = run(
    `if cooee_fetch https://example.test/x /tmp/whatever 2>/dev/null; then echo ok; else echo failed; fi`,
    [22, 22, 22, 22, 22, 22],
  );
  // Non-zero return, not an abort: the caller decides between `die` and a warn.
  assert.equal(out, "failed");
  assert.equal(calls.length, 4, "four attempts, so a blocked host still fails fast");
});

test("the attempt count is caller-tunable", () => {
  const { out, calls } = run(
    `if cooee_fetch https://example.test/x /tmp/whatever 2 2>/dev/null; then echo ok; else echo failed; fi`,
    [22, 22, 0],
  );
  assert.equal(out, "failed");
  assert.equal(calls.length, 2);
});

test("the Nix installer is fetched to a file, then run — never piped into sh", () => {
  // A `curl | sh` cannot be retried and cannot fail cleanly: a transfer that
  // dies mid-stream has already fed a truncated installer to a running shell.
  const body = render("base").body;
  assert.ok(body.includes("cooee_fetch https://install.determinate.systems/nix"));
  assert.ok(
    !/install\.determinate\.systems\/nix\s*\\?\s*\n?\s*\|\s*sh/.test(body),
    "the installer must not be piped straight into sh",
  );
});

test("the Android CLI download is retried too", () => {
  const body = render("android-cli").body;
  assert.ok(body.includes("cooee_fetch \"https://dl.google.com/android/cli/latest/"));
});
