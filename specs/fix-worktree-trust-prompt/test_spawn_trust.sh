#!/usr/bin/env bash
# End-to-end harness for fix-worktree-trust-prompt.feature: runs the real
# scripts/sub-spawn.sh in a fully sandboxed environment and asserts the three
# scenarios against the child tmux pane.
#
# Sandbox:
#   - $HOME   replaced (its settings.json mirrors a real user policy, which
#             prepare_child_agent_dir must forward or replace with an
#             explicit decision);
#   - treehouse stub: every lease mints a brand-new git worktree path;
#   - pi stub: reproduces pi's documented project-trust resolution order
#     (docs/security.md): protected resources -> (1) CLI --approve, (2)
#     saved decision for cwd/parents in the agent-dir trust.json, (3)
#     agent-dir defaultProjectTrust, (4) otherwise the interactive
#     folder-trust prompt that blocks until Enter decides (the default
#     option persists the decision, exactly like pi);
#   - isolated tmux server via TMUX_TMPDIR, so no live session is touched.
#
# The spawn runs twice, once per level mapping: once with the repository's own
# config.json and once with a scratch mapping naming a made-up model id and an
# unknown thinking level (specs/model-agnostic-tests — config.json is the
# owner's to retune by hand, so no assertion here may depend on what it
# names). The mutated pass also asserts non-vacuity: the resolved options
# sub-spawn.sh prints must carry that made-up id, so its green cannot come
# from the mapping being ignored.
#
# Usage: bash specs/fix-worktree-trust-prompt/test_spawn_trust.sh
set -u

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$HERE/../.." && pwd)
SPAWN="$REPO_ROOT/scripts/sub-spawn.sh"
COMMON="$REPO_ROOT/scripts/_sub-common.sh"

TASK="test-trust-prompt"
SESS="pi-$TASK"
PASS=0
FAIL=0
SANDBOX=""
SOCKDIR=""

# The mutated mapping's model id / thinking level. They are written nowhere
# else in the repository on purpose: no future config.json retune can make
# them "already true", so the mutated pass stays a real test.
MUTANT_MODEL="nowhere/trust harness model"
MUTANT_THINKING="ludicrous"

say()  { printf '%s\n' "$*"; }
fail() { printf '%s\n' "$*"; return 1; }

pane() {
  # Plain session name: the harness talks to its own isolated tmux server
  # (TMUX_TMPDIR), so the name is unambiguous. Note `=name` is only valid for
  # has-session, never as a pane target (see AGENTS.md, sub-report.sh).
  env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux capture-pane -t "$SESS" -p \
    2>/dev/null || true
}

session_alive() {
  env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux has-session -t "$SESS" 2>/dev/null
}

# Poll the pane for a literal string; $2 = seconds (default 10).
wait_pane_has() {
  local pat=$1 tries=$((${2:-10} * 2)) i
  for ((i = 0; i < tries; i++)); do
    if pane | grep -qF -- "$pat"; then return 0; fi
    sleep 0.5
  done
  return 1
}

# The same, against the pane with every space, newline and printf %q
# backslash removed: a launch line long enough to wrap across pane rows is
# still a single match, so an assertion about the typed line never depends on
# where tmux broke it.
wait_flat_pane_has() {
  local pat=$1 tries=$((${2:-10} * 2)) i
  for ((i = 0; i < tries; i++)); do
    if pane | tr -d '\\[:space:]' | grep -qF -- "$pat"; then return 0; fi
    sleep 0.5
  done
  return 1
}

dump_pane() {
  if ! session_alive; then
    say "(tmux session $SESS is not running on the sandbox socket)"
    return 0
  fi
  pane | grep -v '^[[:space:]]*$' | tail -n 15 | sed 's/^/      | /'
}

# --- scenarios (names mirror the .feature file) ----------------------------

scenario_req1() {
  if ! wait_pane_has "PI-STUB: trust resolved" 10; then
    say "pi never resolved project trust; the pane still shows:"
    dump_pane
    return 1
  fi
  if pane | grep -qF "PI-STUB: trust granted by keystroke"; then
    fail "a trust-granting keystroke was sent to the child session"
    return 1
  fi
  return 0
}

scenario_req2() {
  local user_store="$SANDBOX/home/.pi/agent/trust.json"
  local user_settings="$SANDBOX/home/.pi/agent/settings.json"
  if [ -e "$user_store" ] || [ -L "$user_store" ]; then
    fail "the user trust store was created/modified: $user_store"
    return 1
  fi
  if ! cmp -s "$user_settings" "$SANDBOX/settings.snap"; then
    fail "the user settings file changed during the spawn"
    return 1
  fi
  return 0
}

scenario_req3() {
  if ! wait_pane_has "PI-STUB: kickoff accepted: Read the task brief at" 10; then
    say "the kickoff was never accepted (stranded); the pane shows:"
    dump_pane
    return 1
  fi
  return 0
}

# [model-agnostic REQ-1] The stub must take the positional kickoff whatever
# option values the launch line carries. Asserted here, against the stub
# alone — no spawn, no config.json: the old parser took --model's value as
# the kickoff, which made the [REQ-3] outcome a property of the shipped
# mapping instead of of the harness.
scenario_kickoff_parsing() {
  local out
  out=$(cd "$SANDBOX" && HOME="$SANDBOX/home" "$STUB_BIN/pi" \
    --model "$MUTANT_MODEL" --thinking "$MUTANT_THINKING" \
    -n some-task --no-extensions -e "$SANDBOX/ext.ts" --approve \
    'Read the task brief at /nowhere/brief.md' 2>&1)
  if ! grep -qF -- 'PI-STUB: kickoff accepted: Read the task brief at /nowhere/brief.md' <<<"$out"; then
    fail "the positional message was not taken as the kickoff (an option value
was taken instead); the stub said:
$out"
    return 1
  fi
  return 0
}

# [model-agnostic REQ-3] Non-vacuity: the mutated mapping really reached the
# launch line. Without it the pass below could go green with the mapping
# ignored — passing for the wrong reason, which is exactly the bug this
# harness had.
scenario_mutated_options_reached_the_launch_line() {
  local out="$SANDBOX/spawn.out"
  # The handles print the resolved option words already printf %q-escaped,
  # which is the form the launch line carries.
  local model thinking
  printf -v model '%q' "$MUTANT_MODEL"
  printf -v thinking '%q' "$MUTANT_THINKING"
  if ! grep -qF -- "--model $model --thinking $thinking" "$out"; then
    fail "the mutated mapping never reached the resolved launch options:
$(grep -E '^ *launch:' "$out" 2>/dev/null)"
    return 1
  fi
  # …and on the line the shell actually ran, not only in the handles echo:
  # the handles print CHILD_LAUNCH_FLAGS, so they stay green even if
  # pi_launch_command dropped the option words from the launch line.
  if ! wait_flat_pane_has "${MUTANT_MODEL// /}" 10; then
    fail "the mutated mapping never reached the typed launch line; the pane shows:"
    dump_pane
    return 1
  fi
  return 0
}

supp_lint() {
  if ! shellcheck -S warning "$SPAWN" "$COMMON" "$0"; then
    fail "shellcheck reported warnings or errors (severity >= warning)"
    return 1
  fi
  return 0
}

run_scenario() {
  local name=$1 fn=$2 out
  if out=$("$fn" 2>&1); then
    PASS=$((PASS + 1))
    printf "PASS  test( '%s' )\n" "$name"
  else
    FAIL=$((FAIL + 1))
    printf "FAIL  test( '%s' )\n" "$name"
    [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/      /'
  fi
  return 0
}

# --- sandbox ---------------------------------------------------------------

write_stubs() {
  cat > "$STUB_BIN/treehouse" <<'STUB'
#!/usr/bin/env bash
# treehouse stub: every lease mints a brand-new git worktree path.
set -u
: "${STUB_POOL:?STUB_POOL not set}"
: "${STUB_ORIGIN:?STUB_ORIGIN not set}"
mkdir -p "$STUB_POOL"
case "${1:-}" in
  status)
    printf '[]\n'
    ;;
  get)
    n=1
    while [ -e "$STUB_POOL/$n" ]; do n=$((n + 1)); done
    path="$STUB_POOL/$n"
    git clone -q "$STUB_ORIGIN" "$path" >&2
    printf '%s\n' "$path"
    ;;
  return)
    shift
    [ "${1:-}" = "--force" ] && shift
    rm -rf "${1:?missing worktree path}"
    ;;
  *)
    printf 'treehouse stub: unexpected command: %s\n' "${1:-}" >&2
    exit 1
    ;;
esac
STUB

  cat > "$STUB_BIN/pi" <<'STUB'
#!/usr/bin/env bash
# pi stub: reproduces pi's documented project-trust resolution order
# (docs/security.md, "How Pi chooses a trust decision") and the blocking
# folder-trust prompt, including the default option persisting the decision
# to the agent-dir trust.json.
set -u

approved=0
kickoff=""
args=("$@")
idx=0
# Options that take a value: their value is the next argv element and can
# never be the positional kickoff. The table mirrors pi's own option list
# (pi --help); an option that grows one only makes the stub skip one more
# token, which is exactly the safe direction. Values arrive here already
# unescaped and whole (the shell built the argv), so a model id may contain
# spaces.
value_opts=" --provider --model --api-key --system-prompt --append-system-prompt
  --mode --session --session-id --session-dir --fork --name --models --tools
  --exclude-tools --thinking --extension --skill --prompt-template --theme
  --use-theme --export --tui-mode -n -e -t -xt "
positionals_only=0
while [ "$idx" -lt "${#args[@]}" ]; do
  arg=${args[$idx]}
  if [ "$positionals_only" = 1 ]; then
    [ -z "$kickoff" ] && kickoff=$arg
  else
    case "$arg" in
      --) positionals_only=1 ;;
      --approve | -a) approved=1 ;;
      --*=*) ;;                       # the value rides in the option itself
      -*) case "$value_opts" in *" $arg "*) idx=$((idx + 1)) ;; esac ;;
      *) [ -z "$kickoff" ] && kickoff=$arg ;;
    esac
  fi
  idx=$((idx + 1))
done

agent_dir=${PI_CODING_AGENT_DIR:-${HOME:?HOME not set}/.pi/agent}

protected=0
for res in .pi/settings.json .pi/extensions .pi/skills .pi/prompts \
           .pi/themes .pi/SYSTEM.md .pi/APPEND_SYSTEM.md; do
  [ -e "$PWD/$res" ] && protected=1
done

resolved=""
if [ "$protected" = 0 ]; then
  resolved="no protected resources"
elif [ "$approved" = 1 ]; then
  resolved="command-line override"
else
  store="$agent_dir/trust.json"
  dir=$PWD
  while :; do
    if [ -e "$store" ] && jq -e --arg d "$dir" 'has($d)' "$store" >/dev/null 2>&1; then
      resolved="saved decision for $dir"
      break
    fi
    [ "$dir" = "/" ] && break
    dir=$(dirname "$dir")
  done
  if [ -z "$resolved" ] && [ -f "$agent_dir/settings.json" ]; then
    policy=$(jq -r '.defaultProjectTrust // "ask"' \
      "$agent_dir/settings.json" 2>/dev/null || printf 'ask')
    [ "$policy" = "always" ] && resolved="defaultProjectTrust=always"
    [ "$policy" = "never" ] && resolved="defaultProjectTrust=never (declined)"
  fi
fi

if [ -n "$resolved" ]; then
  printf 'PI-STUB: trust resolved (%s); prompt suppressed\n' "$resolved"
  printf 'PI-STUB: kickoff accepted: %s\n' "$kickoff"
  exit 0
fi

parent=$(dirname "$PWD")
cat <<PROMPT
 Trust project folder?
 $PWD
 This allows pi to load .pi settings and resources, install missing project
 packages, and execute project extensions.
 → Trust
   Trust parent folder ($parent)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)
 ↑↓ navigate  enter select  escape/ctrl+c cancel
PROMPT

if read -r _keystroke; then
  store="$agent_dir/trust.json"
  [ -L "$store" ] && store=$(readlink "$store")
  printf '{"%s": true}\n' "$PWD" > "$store"
  printf 'PI-STUB: trust granted by keystroke and persisted to trust.json\n'
  printf 'PI-STUB: kickoff accepted: %s\n' "$kickoff"
  exit 0
fi
printf 'PI-STUB: session closed with the trust prompt unanswered\n'
exit 1
STUB

  chmod +x "$STUB_BIN/treehouse" "$STUB_BIN/pi"
}

setup_sandbox() {
  SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/spawn-trust.XXXXXX")
  SOCKDIR="$SANDBOX/tmux"
  STUB_BIN="$SANDBOX/bin"
  mkdir -p "$SOCKDIR" "$STUB_BIN"

  # User-level policy mirrors the real machine: defaultProjectTrust=always
  # exists globally, yet children still prompt because the isolated agent
  # dir carries no such key — the root cause this harness reproduces.
  mkdir -p "$SANDBOX/home/.pi/agent"
  cat > "$SANDBOX/home/.pi/agent/settings.json" <<'EOF'
{
  "defaultProvider": "stub-provider",
  "defaultModel": "stub-model",
  "enabledModels": ["stub-provider/stub-model"],
  "defaultProjectTrust": "always"
}
EOF
  cp "$SANDBOX/home/.pi/agent/settings.json" "$SANDBOX/settings.snap"

  # Scratch main checkout with a development branch and a protected
  # project resource (.pi/settings.json) in every worktree.
  MAIN="$SANDBOX/main"
  git init -q -b development "$MAIN"
  mkdir -p "$MAIN/.pi"
  printf '{\n  "defaultModel": "stub-project-model"\n}\n' \
    > "$MAIN/.pi/settings.json"
  git -C "$MAIN" add .pi/settings.json
  git -C "$MAIN" -c user.email=test@example.invalid -c user.name=test \
    commit -qm "project-local model"
  git clone -q --bare "$MAIN" "$SANDBOX/origin.git"

  BRIEF="$SANDBOX/brief.md"
  printf 'Trust-harness brief: never read; the pi stub only reports it.\n' \
    > "$BRIEF"

  # The mutated level mapping: a model id that exists nowhere in the
  # repository (spaces included, so the quoting of printf %q is exercised)
  # and a thinking level pi has never heard of.
  cat > "$SANDBOX/mutant-levels.json" <<EOF
{
  "taskLevels": {
    "default": "mutated",
    "levels": {
      "mutated": { "model": "$MUTANT_MODEL", "thinking": "$MUTANT_THINKING" }
    }
  }
}
EOF

  write_stubs
}

# run_spawn <task> [levels-config] — boot a child in the sandbox with a
# clean level environment: SUB_LEVEL/SUB_MODEL/SUB_THINKING/SUB_LEVELS_CONFIG
# are always cleared, so neither an ambient override nor the second pass can
# decide what the first one resolves. With no <levels-config> the child
# inherits the repository's own config.json.
run_spawn() {
  local task=$1 levels_cfg=${2:-}
  local -a cfg_env=()
  [ -n "$levels_cfg" ] && cfg_env=("SUB_LEVELS_CONFIG=$levels_cfg")
  env -u TMUX -u MAIN_SESSION -u MAIN_PANE -u PI_BIN -u SCRATCH_DIR \
    -u SUB_LEVEL -u SUB_MODEL -u SUB_THINKING -u SUB_LEVELS_CONFIG \
    "${cfg_env[@]+"${cfg_env[@]}"}" \
    TMUX_TMPDIR="$SOCKDIR" \
    HOME="$SANDBOX/home" \
    PATH="$STUB_BIN:$PATH" \
    STUB_POOL="$SANDBOX/pool" \
    STUB_ORIGIN="$SANDBOX/origin.git" \
    SUB_SPAWN_NO_VIEWER=1 \
    PI_BOOT_DELAY=2 \
    bash "$SPAWN" "$task" "$MAIN" "$BRIEF" > "$SANDBOX/spawn.out" 2>&1
}

cleanup() {
  if [ "${KEEP_SANDBOX:-0}" = 1 ] && [ -n "$SANDBOX" ]; then
    say "(sandbox kept for inspection: $SANDBOX)"
    [ -n "$SOCKDIR" ] && [ -d "$SOCKDIR" ] && \
      { say "--- tmux sessions ---"
        env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux ls 2>&1 | sed 's/^/      /'; }
    [ -f "$SANDBOX/spawn.out" ] && \
      { say "--- spawn.out ---"
        sed 's/^/      /' "$SANDBOX/spawn.out"; }
    return 0
  fi
  if [ -n "$SOCKDIR" ] && [ -d "$SOCKDIR" ]; then
    env -u TMUX TMUX_TMPDIR="$SOCKDIR" tmux kill-server 2>/dev/null || true
  fi
  [ -n "$SANDBOX" ] && rm -rf "$SANDBOX"
  return 0
}
trap cleanup EXIT

# --- run -------------------------------------------------------------------

setup_sandbox

# The stub's own argv parsing, before anything is spawned (model-agnostic
# REQ-1).
run_scenario "Take the positional kickoff whatever option values carry [model-agnostic REQ-1]" \
  scenario_kickoff_parsing

say ""
say "--- pass 1: the repository's own config.json ---"
if ! run_spawn "$TASK"; then
  say "FAIL  sub-spawn.sh exited non-zero during setup:"
  sed 's/^/      | /' "$SANDBOX/spawn.out"
  exit 1
fi

run_scenario "Resolve project trust on a fresh worktree without a keystroke [REQ-1]" scenario_req1
run_scenario "Leave no persistent trust decision behind [REQ-2]" scenario_req2
run_scenario "Process the kickoff instead of stranding it [REQ-3]" scenario_req3

say ""
say "--- pass 2: a level mapping that exists nowhere in the repository ---"
TASK="test-trust-mapping"
SESS="pi-$TASK"
if ! run_spawn "$TASK" "$SANDBOX/mutant-levels.json"; then
  say "FAIL  sub-spawn.sh exited non-zero under the mutated level mapping:"
  sed 's/^/      | /' "$SANDBOX/spawn.out"
  exit 1
fi

run_scenario "Carry the mutated mapping onto the child's launch line [model-agnostic REQ-3]" \
  scenario_mutated_options_reached_the_launch_line
run_scenario "Resolve project trust on the mutated mapping without a keystroke [REQ-1]" scenario_req1
run_scenario "Leave no persistent trust decision behind under the mutated mapping [REQ-2]" scenario_req2
run_scenario "Process the kickoff instead of stranding it under the mutated mapping [REQ-3]" scenario_req3

run_scenario "Pass shellcheck at warning severity on changed scripts" supp_lint

say ""
say "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
