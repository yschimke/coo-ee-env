// Behavioural tests for tools[attr@version] and the Multiverse Fast backend.
// The rendered Bash is exercised with Nix and uname replaced by shell functions,
// so these tests verify command construction/profile handling without network or
// a real Nix-store mutation.
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { render } = require("../api/env/render");

function run(snippet, opts = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "cooee-mvs-"));
  const file = path.join(dir, "run.sh");
  const body = render("tools[ripgrep@14.1.1]", opts.render).body.replace(
    /^main "\$@"$/m,
    ":",
  );
  fs.writeFileSync(file, `${body}\n${snippet}\n`);
  return execFileSync("bash", [file], {
    encoding: "utf8",
    env: {
      ...process.env,
      TEST_DIR: dir,
      COOEE_PROFILE: path.join(dir, "env.sh"),
      COOEE_HARNESS_ENV: path.join(dir, "env.harness"),
      COOEE_MULTIVERSE_PROFILES: path.join(dir, "profiles"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  }).trim();
}

const nixStub = String.raw`
  uname() { [[ "$1" == -s ]] && echo Linux || echo x86_64; }
  nix() {
    printf '%s\n' "$*" >> "$TEST_DIR/nix.log"
    if [[ "$1" == build ]]; then
      echo /nix/store/test-ripgrep-14.1.1
      return 0
    fi
    if [[ "$1 $2" == "profile install" ]]; then
      local prev="" arg profile=""
      for arg in "$@"; do
        [[ "$prev" == --profile ]] && profile="$arg"
        prev="$arg"
      done
      mkdir -p "$profile/bin"
    fi
    return 0
  }
`;

test("versioned tools use the pinned Fast selector and a dedicated profile", () => {
  const out = run(`${nixStub}
    cooee_init_profile
    module_tools ripgrep@14.1.1 >/dev/null 2>&1
    cat "$TEST_DIR/nix.log"
    printf 'PATH=%s\n' "$PATH"
  `);
  assert.match(
    out,
    /github:fzakaria\/nixpkgs-multiverse\/4745826df4b3d554ea546d8a428767b790dd19da#fast\.versions\.ripgrep\."14\.1\.1"\.out/,
  );
  assert.match(out, /profile install --profile .*\/profiles\/ripgrep \/nix\/store\/test-ripgrep-14\.1\.1/);
  assert.match(out, /PATH=.*\/profiles\/ripgrep\/bin/);
});

test("changing a pin clears only its coo.ee-owned tool profile", () => {
  const out = run(`${nixStub}
    mkdir -p "$COOEE_MULTIVERSE_PROFILES/ripgrep/bin"
    cooee_init_profile
    module_tools ripgrep@14.1.1 >/dev/null 2>&1
    cat "$TEST_DIR/nix.log"
  `);
  assert.match(out, /profile list --profile .*\/profiles\/ripgrep/);
  assert.match(out, /profile remove --profile .*\/profiles\/ripgrep --all/);
  assert.match(out, /profile install --profile .*\/profiles\/ripgrep \/nix\/store\/test-ripgrep-14\.1\.1/);
});

test("the devenv backend rejects version pins without an eval fallback", () => {
  const body = render("tools[ripgrep@14.1.1]", { devenv: true }).body;
  assert.match(body, /not supported by the devenv backend/);
  assert.ok(!body.includes("#fast.versions.${attr}"));
});

test("nested versioned attributes are rejected before reaching Nix", () => {
  const out = run(`${nixStub}
    cooee_init_profile
    module_tools nodePackages.prettier@3.6.2 2>&1
    [[ ! -f "$TEST_DIR/nix.log" ]] && echo NO_NIX
  `);
  assert.match(out, /nested, but Multiverse versions only top-level/);
  assert.match(out, /NO_NIX/);
});
