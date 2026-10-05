# AGENTS.md

Guidance for agents (and humans) working in this directory.

## tmux sessions

Use tmux to run long-lived or background work (dev servers, watchers, long
builds) so the work survives disconnects and can be re-attached later.

### Start a new session

```bash
# Named session (recommended)
tmux new -s <name>

# Detached session you can attach to later
tmux new -d -s <name>
```

### List sessions

```bash
tmux ls
```

### Attach to a session

```bash
tmux attach -t <name>
```

### Detach (from inside the session)

Press `Ctrl+b` then `d`. The session keeps running in the background.

### Send a command to a session without attaching

```bash
tmux send-keys -t <name> "npm run dev" Enter
```

### Capture output of a pane (useful for agents)

```bash
tmux capture-pane -t <name> -p | tail -50
```

### Kill a session

```bash
tmux kill-session -t <name>
```

### Conventions

- Use descriptive, kebab-case session names (e.g. `dev-server`, `tests-watch`).
- One concern per session; create a new session instead of overloading an
  existing one.
- Always prefer a named session over the default so it can be found later
  with `tmux ls`.
- When child panes are active, keep the main pane on the left and arrange child
  panes tiled on the right.
- If a session with the desired name already exists, attach to it or pick a
  new name; do not kill someone else's session without asking.

## treehouse (worktree pool)

`treehouse` (v2.3.0, at `~/.local/bin/treehouse`) maintains a pool of
reusable, pre-warmed git worktrees so multiple agents can work on the same
repo in parallel. Run it from *inside* a git repository; by default the pool
lives under `$HOME` (`--root .` or `root = "."` in `treehouse.toml` keeps it
in-project).

### Core commands

```bash
treehouse init              # create a default treehouse.toml (once per repo)
treehouse status            # list worktrees in the pool (name = number)
treehouse get               # acquire a free worktree and open a subshell in it
treehouse get --lease       # non-interactive: lease + print path to stdout
treehouse enter <name>      # open a subshell in an existing worktree (even in use)
treehouse return <path>     # kill lingering processes and give the worktree back
treehouse prune             # remove stale worktrees and opted-in orphans
treehouse destroy           # remove worktrees from the pool (safely by default)
```

- `get` acquires, fetches, and resets; `enter` only cd's in and leaves all pool
  state untouched — use it to attach to a worktree another agent is using.
- `return --force` cleans and resets without prompting.

### Base branch: `development` when it exists, else the default branch

Every child starts from the latest `development` base when it exists; if it
does not exist, the spawn falls back to the repository's **default branch** as
advertised by `origin/HEAD` (commonly `master`). Do **not** switch a
pooled worktree directly to `development`: the main checkout commonly
already owns that branch, and Git forbids checking it out in two linked
worktrees. Instead, create a unique task branch from it:

```bash
# the resolved base ref is printed in the spawn handles as "base:"
git -C "$WT" switch -c task/<task-name> "$BASE_REF"
```

Worktrees are created **detached HEAD** at the inferred default
(`origin/HEAD` → checked-out branch → `init.defaultBranch`). The helper
uses `treehouse get --lease`, fetches `origin/development` when available,
then creates `task/<task-name>` from `origin/development` (or local
`development` when there is no remote); only when neither exists does it fall
back to the `origin/HEAD` default and warn about the fallback. This works
with the installed treehouse CLI, whose `get` does not expose a `--base`
flag.

In repos whose dev branch is named differently (`main`, `master`, `dev`), use
that name instead — check with `git -C "$WT" remote show origin | grep HEAD`
if unsure. Set `DEV_BRANCH` when using the helpers with a repository whose
base branch has another name; a `DEV_BRANCH` that exists always wins, and
only a genuinely missing branch triggers the `origin/HEAD` fallback — a
failed fetch of an existing branch does not. The comparison helpers
(`sub-changes.sh`, `sub-land.sh`, `sub-retire.sh`) resolve the same base
through the shared resolver, so their commit lists, diff stats and the
retirement safety check follow the same fallback.

### Init scripts: not run by default

`treehouse init` only *writes* `treehouse.toml` — treehouse runs **no repo
scripts** on `get`/creation, and "pre-warmed" only means a *reused*
worktree keeps its old `node_modules`/build cache. A freshly created
worktree may have no dependencies installed.

**This machine has a `post_create` hook configured** in the user-level
`~/.config/treehouse/config.toml`, pointing at
`/home/jseto/programming-projects/mu-commander/scripts/worktree-setup.sh`, which runs in each newly provisioned or reset
worktree right before `get` hands it over:

- picks the JS package manager by lockfile (`pnpm-lock.yaml` →
  `pnpm install --frozen-lockfile`, `yarn.lock` → `yarn install --immutable`,
  bun lock → `bun install`, `package-lock.json` → `npm ci`, bare
  `package.json` → `npm install`), plus `flutter/dart pub get`,
  `cargo fetch`, and `go mod download` when their manifests exist;
- **skips the JS install when `node_modules` exists and the lockfile is not
  newer** — a warm cache from a reused worktree is left alone (that cache is
  the point of the pool); it refreshes only when the lockfile changed;
- **provisions `shellcheck`, a declared dependency of this repository**
  (pinned `SHELLCHECK_VERSION` + per-platform sha256 in the script): the
  official release binary is installed under `$XDG_DATA_HOME` and linked to
  `~/.local/bin/shellcheck`, so `command -v shellcheck` works in every
  worktree with no manual installs. It is idempotent (skips when the pinned
  version is already in place), refreshes its own managed link when the pin
  changes, and only warns — never overwrites — when a different shellcheck
  occupies that path or when PATH resolves shellcheck elsewhere;
- **activates the repository's versioned git hooks** — sets the relative
  `core.hooksPath` to `.githooks` (resolved per worktree) when it is unset
  and the worktree has a `.githooks/` directory; a foreign `core.hooksPath`
  and a repository without `.githooks/` are left untouched, and the step
  never fails the setup (specs/skills-sync-hook);
- logs `[worktree-setup] …` to stderr (stdout stays clean for
  `get --lease`); a failing step is reported but does **not** fail the
  `get`. The strict package-manager fallback is forced after a failed frozen
  install, so a partial `node_modules` directory cannot suppress the retry.

Things to know:

- Hooks are **user-level only** — hooks in a repo-level `treehouse.toml`
  are ignored on purpose (no executing checked-in shell from untrusted
  clones); treehouse warns on stderr if you declare them there.
- `pre_destroy` also exists (runs before `destroy`/`prune --yes` deletes a
  worktree) but is not configured.
- **Seed gitignored files** with a committed `.worktreeinclude` manifest
  (`.env*`, local config, …); selected ignored files are copied from the
  main checkout on every acquire.
- For repos needing different setup, still say so in the task brief — the
  hook is best-effort, and what it skips (e.g. a build step) is on the
  child to run.

### Using treehouse inside a tmux session

Interactive mode — the worktree subshell lives in a tmux pane so it survives
disconnects:

```bash
tmux new -s <name>          # session inside the repo
# inside the pane:
treehouse get               # acquire a worktree and drop into its subshell
# detach with Ctrl+b then d; the subshell keeps running
```

Agent/non-interactive mode — lease first, then drive everything through tmux:

```bash
# 1. Lease a worktree (prints only its absolute path to stdout)
WT=$(treehouse get --lease --lease-holder <agent-name>)

# 2. Run the long-lived work inside a named tmux session rooted there
tmux new -d -s <name> -c "$WT"
tmux send-keys -t <name> "npm run dev" Enter
tmux capture-pane -t <name> -p | tail -50   # check on it

# 3. When done, stop the work and return the worktree
tmux kill-session -t <name>
treehouse return --force "$WT"
```

### Conventions

- Give the tmux session a kebab-case name that hints at the worktree's task
  (e.g. `fix-auth`, `dep-bump`), not the default name.
- Always pair `get --lease` with a `return` (or `return --force`) when the
  work is finished; a leased worktree is never reused or pruned until then.
- Before disposing of a worktree (returned, force-returned, pruned, or
  destroyed), if it is dirty (uncommitted changes or untracked work), notify
  the user and get confirmation before discarding the changes.
- Set `TREEHOUSE_LEASE_HOLDER` (or pass `--lease-holder`) so leases are
  attributable when several agents share a pool.
- Use `treehouse status` (or `--json`) before acquiring to avoid grabbing a
  worktree another agent is already in.
- Never `treehouse destroy`/`prune` a worktree someone else is in without
  asking first — same rule as tmux sessions.

## pi sessions (orchestrated through tmux)

`pi` (v0.87.1, on PATH via nvm) is the AI coding assistant used here. A pi
session inside tmux survives disconnects, and tmux doubles as the control
channel: one **main pi session** (the orchestrator) opens and drives
**child pi sessions**, and the children report back to the main session.

This machine already has the pi-in-tmux key handling configured in
`~/.tmux.conf` (`extended-keys on` + `csi-u`, tmux 3.6), so `Shift+Enter`
(newline) vs `Enter` (submit) work inside panes.

### Open one pi session inside tmux

```bash
tmux new -d -s pi-main -c <repo>     # detached, inside the repo
tmux send-keys -t pi-main "pi -n main" Enter
tmux attach -t pi-main                # interact; detach with Ctrl+b d
```

Headless one-shots need no TUI — run and exit:

```bash
pi -p "<prompt>"                      # print mode: process prompt and exit
```

### Helper scripts (`scripts/`)

The orchestrator flow is scripted in `scripts/` (relative to this directory).
Prefer these over hand-rolled command sequences:

Because the project repositories are sibling directories, the scripts are not
inside each project's worktree. In a main session, set this once and use the
absolute directory:

```bash
SCRIPTS=/home/jseto/programming-projects/mu-commander/scripts
```

| Script | Does |
|---|---|
| `sub-spawn.sh <task> <repo> [brief-file]` | Lease worktree (holder = task), base on `$DEV_BRANCH` (falling back to the `origin/HEAD` default branch when it is gone), write brief, boot `pi -n <task> --no-extensions "<kickoff>"` in tmux `pi-<task>` (kickoff passed as pi's initial message, so it cannot strand in the composer) with an isolated agent directory that provides no extensions or packages while retaining non-extension resources, open a live viewer window in the invoking tmux session without stealing the cursor focus (skippable with `SUB_SPAWN_NO_VIEWER=1`), print all handles |
| `sub-status.sh <task> [repo] [lines]` | Lease + git state + pane tail + report tail for one subsession |
| `sub-changes.sh <task> [repo]` | Read-only: status, commits not on the resolved base branch (`$DEV_BRANCH` or the `origin/HEAD` default), diff stats |
| `sub-send.sh <task> "message"` | Send a literal follow-up instruction to an existing child pi session and confirm it was submitted (re-types/retries `Enter` via `tmux_send_line`) |
| `sub-report.sh <task> "message"` | Push a `[task] message` notice into `$MAIN_SESSION` (used by children) |
| `sub-land.sh <task> [repo] [--patch]` | Read-only: what would be lost, commits to publish, push + `gh pr create` commands; `--patch` exports the work to `tmp/pi-sub/reports/<task>.patch` |
| `sub-retire.sh <task> [repo] [--force] [--keep-files] [--no-branch-cleanup]` | Kill `pi-<task>`, `treehouse return --force`, delete the task's scratch brief/report/patch, best-effort clean up the task's merged local/remote branches (`--no-branch-cleanup` skips that), and append a conversation-log entry recording the retirement with the child's session cost; **refuses** when uncommitted or unpublished work would be destroyed (overridable with `--force`; `--keep-files` retains the scratch docs) |
| `sub-clean.sh [repo] [--yes]` | Sweep scratch docs for tasks with no lease and no running tmux session (dry-run unless `--yes`) |
| `conversation-log.sh append <kind> <message>` | Append one entry to the weekly conversation/operation log in gitignored `logs/conversations/` (6-month retention sweep runs on every call; **logs are only read to resolve operational issues** — never during normal operation); kinds: `prompt`, `reply`, `child-out`, `child-in`, `operation` — see *Conversation logging* |
| `start-main.sh [--detach\|-d]` | Start the orchestrator's main pi session in tmux `pi-main` (name follows `$MAIN_SESSION`): create it detached at the main checkout of this repo, launch plain `$PI_BIN` (default `pi`, no child flags, submission verified via `tmux_send_line`), set the `main-pane-width 50%` / `main-vertical` convention, then attach — `--detach`/`-d` only starts or points at it; an existing session is reported (name + cwd) and re-attached, never restarted |
| `worktree-setup.sh` | treehouse `post_create` hook: installs dependencies in each new worktree (lockfile-aware; see *Init scripts* below) |

Details:

- Worktrees are looked up by **lease holder = task name** (`sub-spawn.sh`
  passes `--lease-holder <task>`); don't lease manually with another holder
  if you want the scripts to find the worktree.
- Scratch exchange files live in the **main checkout**: `tmp/pi-sub/tasks/<task>.md`
  and `tmp/pi-sub/reports/<task>.md`. They are outside any worktree, so they
  survive `return --force`, and they are **gitignored** via the global excludes
  file (`~/.config/git/ignore`) so they are never committed. `sub-retire.sh`
  deletes them when the task is retired (use `--keep-files` to keep them);
  `sub-clean.sh` sweeps leftovers from crashed sessions.
- Overrides: `DEV_BRANCH` (default `development`; when it resolves to
  neither `origin/<dev>` nor a local branch, the spawn and the comparison
  helpers fall back to the `origin/HEAD` default), `MAIN_SESSION` (default
  `pi-main`), `SCRATCH_DIR` (default `tmp/pi-sub`), `PI_BIN`, `PI_BOOT_DELAY`
  (default `3`).
- `sub-spawn.sh` always creates a unique `task/<name>` branch from the
  resolved base branch; it never commits directly to the shared
  `development` branch. If setup fails after leasing, it cleans up the lease.
- All scripts are safe to run from anywhere; they resolve the repo
  themselves and print `ERROR:` lines to stderr on misuse.

### Delegation mandate — the main session is the middle man

The main session is a **relay between the human and the children, not a
worker**. Its only jobs are: resolve names, transfer the user's queries and
tasks to the proper child (spawn one when none fits), relay the child's
answers back verbatim, run the mechanics of the pattern (spawn / publish /
land / retire, branch cleanup), and talk to you. It must not pick up a task
— or a question — itself; the sole
exception is the last row of the routing table below.

**The new-feature-fix flow must be done EXCLUSIVELY by the children.** You launch a child with the user's input and delegate to it the FULL flow: from atomic specs (Gherkin/design), through implementation (per the `implement` skill), to a code audit (code-auditor). The child goes back to you ONLY when it needs the user's input or when it has completed the full task through to opening a PR. Your job is ONLY to manage child task assignments and handle child feedback (whether a question for the user or a finished task report).

**Do not spell that flow out in a brief** — the child takes it from the
project's own `AGENTS.md`; a brief only says *what* is required (and, at most,
"follow the `new-feature-fix` flow per this repo's AGENTS.md").

**Exception — plain-text docs skip new-feature-fix.** When the task only
edits plain-text documentation (README, Markdown guides, AGENTS.md-style
operational docs, comments-as-docs), do **not** apply the new-feature-fix
flow: no Gherkin scenarios, no `[REQ-n]` chain, no design doc, no
`implement` skill round, no code-auditor pass. Spawn the child with a
direct brief (what to write, what to verify against, existing doc tests
still green if the repo has them) and let it deliver straight to a PR.
Reserve the full new-feature-fix flow for code and behaviour changes.

Routing rule for every incoming message:

| Message is… | Main session does |
|---|---|
| New work (*"fix/implement/refactor …"*) | **Delegate**: spawn a child (or route to the live one). Never starts coding itself. |
| Query about work or the world (*"state of …"*, *"changes in …"*, *"why …"*, *"what does … mean"*) | **Relay**: pass it to the proper child — the live one for that task, or spawn a research child — and report the child's answer back. Local retrieval of raw artifacts (`treehouse status`, `capture-pane`, `tmp/pi-sub/reports/`, `git log\|diff`) is allowed **only** to route or to quote verbatim; interpretation and reasoning belong to the child. |
| Housekeeping (*land*, *retire*, *merge on request*, *branch cleanup*, *"wrap up alpha"*) | Run steps 5-6 itself — the mechanics of being the middle man, not new reasoning. |
| Modify the main session's own behaviour (*"from now on …"*, *"always …"*, edits to this `AGENTS.md`) | **The sole exception**: reason and act by itself, without delegating. |

Hard rules:

- **Always delegate the reasoning to the children**: requirement
  interpretation, root-cause analysis, design and trade-off decisions, and
  investigative *why / what does this mean* work are child work — spawn (or
  route to) a child even when the question starts from read-only inspection.
  The main session only routes, quotes existing artifacts, and reports; it
  must not reason things out itself.
- If the answer or outcome requires **any** `edit`/`write`/mutating command
  in a repo, that is new work → delegate. Doing it in the main session is a
  bug, not a shortcut: it pollutes the orchestrator's context and skips the
  worktree isolation this pattern exists for.
- Exceptions the main session may do itself: read-only inspection needed to
  route or answer (issue tracker, `git status/log/diff`, files under
  `tmp/pi-sub/tasks/` `tmp/pi-sub/reports/`), spawning/publishing/retiring
  children, small direct edits to the orchestration docs themselves
  (e.g. a line or two in this `AGENTS.md`), and **updating `AGENTS.md` directly every time the user modifies the main session's behaviour**.
- When in doubt whether a message is a question or a task: **relay it** —
  questions go to the proper child and its answer comes back verbatim, tasks
  get a spawned or live working child. Only an explicit request to change
  the main session's own behaviour short-circuits the relay.
- **Tests never test documents or config files** (user directive, 2026-10-03,
  "Tests should never test documents nor config files"): no test may assert
  the contents of a document (`README.md`, `AGENTS.md`, …) or of a config file
  (`config.json`, …) — tests exercise behaviour, feeding fixtures as inputs
  when needed, but the shipped document/config content itself is not the
  subject under test.
- **Never touch `README.md`** (user directive, 2026-10-03, "you should never
  touch readme.md file"): the main session never edits a README, and a brief
  must not instruct a child to change one either — if a task would require
  editing a README, ask the user before proceeding.
- **Never do a child's task mechanics on its behalf** (user directive,
  2026-09-30, "this task is not yours"): leasing worktrees, creating
  branches, repo/PR setup, moving files, fixing the child's output, or any
  other step of the assigned task is child work, even when started with good
  intentions or when the child seems blocked. Hand over whatever was already
  prepared and let the child own the task end-to-end. The child must work on
  its own and **ask the user through the main session when it has questions**
  (push a `QUESTION` via `sub-report.sh`; the main session relays the answer
  verbatim, never answering from itself) — and use **lavish** HTML artifacts
  when a question or report is better shown than told. The main session's
  job stays: spawn, route, quote, report, run the lifecycle mechanics.

### Lavish reviews (Telegram)

When the user must be consulted through a Lavish HTML artifact, put **both
links in the chat** in the same message: the local annotation-capable session
link (Tailscale/LAN) and the ht-ml.app share link (private by default —
include the password). Keep the review loop in the chat; do not add Telegram
menu surfaces for it. The `lavish-telegram` extension (pi-config repo)
automates link delivery and the background feedback poll.

### Child model and thinking levels

The difficulty of the task decides the child's model and thinking level.
The levels live in `config.json` at the repository root — a generic,
root-level config file that is ready for future general settings: the
levels are namespaced under its `taskLevels` top-level section, and sibling
top-level keys hold any future setting without touching the level
resolution code (unknown keys are ignored). Edit it to retune.

**`config.json` is the single source of truth for the level → model and
level → thinking mappings: this file names no models and no thinking
levels.** Only the levels themselves are described here:

| Level | When to use |
|---|---|
| `easy` | chores, trims, config/docs edits, small fixes |
| `standard` (default) | features / bug fixes with the full specs flow |
| `hard` | architecture, root-cause analysis, long-haul work |

For what model and thinking each level (or `taskLevels.default`) resolves
to, read — and retune — `config.json`; never copy those values into a
brief or into this file.

Pick the level when writing the brief and pass it at spawn:

```bash
"$SCRIPTS/sub-spawn.sh" <task> <repo> [brief-file] --level easy|standard|hard
```

`--model <pattern>` / `--thinking <level>` override the level's mapping in
whole or in part (env equivalents `SUB_LEVEL`, `SUB_MODEL`, `SUB_THINKING`;
`SUB_LEVELS_CONFIG` relocates the config file). Without any override the
`taskLevels.default` level applies; when the config cannot be read the child
inherits `defaultThinkingLevel` / `modelThinkingLevels` / `defaultProjectTrust`
from the global pi settings instead — no config problem can break a spawn.
Spec: `specs/child-task-levels/`, tests: `tests/task-levels.test.sh`.

**Free-provider fallback.** The free provider mapped to `easy` (whatever
`taskLevels.levels.easy.model` currently names in `config.json`) can exhaust
its quota and answer
every request with `FreeUsageLimitError` (HTTP 429); pi treats that error as
terminal (no retry), so the child stalls. A second free-provider rejection
wedges a child the same way: pi's compaction/summarization calls answered
with HTTP 403 `FreeTierError` block auto-compaction and leave the child
stuck. `config.json` names the recovery
for exactly those cases, inside the same `taskLevels` section: the entries
`taskLevels.fallbackModel` (the model to switch a stuck child to) and
`taskLevels.fallbackThinking` (the thinking level to leave it on). Those two
entries are the **single source of truth** for the fallback values — this
file deliberately names no fallback model or level; edit `config.json` to
retune them.

When a child is stuck on one of those failures, recover it with:

```bash
"$SCRIPTS/sub-fallback.sh" <task>
```

The helper detects either failure in the child's pane (it never switches
speculatively), drives `/model <fallbackModel>` into the running child through
the verified tmux send, waits until the child's status bar shows the model id
as a delimited token (an id that merely extends it does not count as
"already on"), and leaves the child on `/thinking <fallbackThinking>` when
the model switch did not already clamp there. No error, or a child already
on the fallback, is a no-op with a clear message; with an error present but
no `fallbackModel` configured it fails loudly and changes nothing — the other
`sub-*` helpers never read the fallback entry, so an absent or malformed one
cannot break them. `SUB_FALLBACK_MODEL` / `SUB_FALLBACK_THINKING` override the
config values. `fallbackThinking` must name a level `fallbackModel` accepts
(pi validates `/thinking` strictly against the current model); when the two
entries drift apart the model switch still recovers the child and the helper
reports the mismatch as a config problem to fix in `config.json`. Spec:
`specs/free-limit-fallback/`, tests: `tests/free-limit-fallback.test.sh`.

### Orchestrator pattern: main session controls the children

Conventions: the main session lives in tmux session `pi-main`; every child
gets its own tmux session named `pi-<task>` (kebab-case), rooted at the
child's leased treehouse worktree. A child pi process must be started with
that worktree as its working directory, never from the main checkout or the
parent repository. The main pi session runs all commands below with its own
bash tool; it is the **only writer** of child prompts. Humans may attach to watch, but should not type into a child pane
while the orchestrator is driving it. **The main session's tmux pane/window must be positioned at the exact left half (50% width) of the screen, while the right half of the screen is reserved for children tmux sessions.** Arranged via `main-vertical` layout and `main-pane-width 50%`.

> **Name the orchestrator `pi-main` — child notices are addressed to it.**
> Children push reports with `sub-report.sh`, which defaults to
> `MAIN_SESSION=pi-main`. The helper sends to the active pane using the exact
> tmux target `=pi-main:`; `=pi-main` alone works for `has-session` but is not a
> valid pane target for `send-keys`. If the main session has a different name
> (e.g. tmux auto-named it `3`), export `MAIN_SESSION=<current>` before
> spawning children or rename it (`tmux rename-session -t <current> pi-main`,
> which does not detach anyone). When `MAIN_SESSION` was not explicitly set,
> `sub-spawn.sh` also prefers the invoking session when its pane is running
> `pi`, avoiding a stale default `pi-main` shell. At startup, verify with
> `tmux display-message -p '#S'`; polling `sub-status.sh` and reading the
> durable report remain the fallback if a live notice cannot be delivered.

**1. Spawn a child session with a task:**

```bash
"$SCRIPTS/sub-spawn.sh" fix-auth <repo> [brief-file]
```

That one call leases a worktree (holder `fix-auth`), bases it on the
resolved base branch (`$DEV_BRANCH`, or the `origin/HEAD` default when that
branch is gone), writes the brief to `tmp/pi-sub/tasks/fix-auth.md`, boots
`pi -n fix-auth --no-extensions` in tmux session `pi-fix-auth` **with the tmux session rooted
at the leased worktree**, using an isolated agent directory that provides no extensions or packages
while retaining non-extension resources, kicks the child off with the brief/report paths, and prints
task, worktree, branch, session, brief, and report handles. The child pi
process therefore starts with the worktree as its current directory, not the
main checkout. The kickoff is passed to pi as its **initial message
argument** (`pi -n <task> --no-extensions "<kickoff>"`), not typed into the composer, so a
keystroke lost while pi initializes can never leave the child sitting idle
with an unsent prompt. (The raw commands behind it: `treehouse get
--lease --lease-holder <task>`, fetch `origin/$DEV_BRANCH`, resolve the base
ref (`origin/$DEV_BRANCH` → local `$DEV_BRANCH` → `origin/HEAD`), create
`task/<task>` from the resolved ref, `tmux new -d -c <worktree>`, then
`tmux_send_line` to launch `pi` with the kickoff.)

**2. Hand follow-up work to the child** — `sub-spawn.sh` already sends the
kickoff; for later instructions use the helper:

```bash
"$SCRIPTS/sub-send.sh" fix-auth "Read the updated brief and continue the implementation"
```

For long or multiline task descriptions, do not fight shell/tmux quoting:
write the task into a file and tell the child to read it.

**Every prompt must be confirmed as submitted — never leave one parked in the
composer.** A bare `tmux send-keys -l '…'` + `Enter` races the child's TUI:
when the Enter lands while pi is mid-redraw (slow extension init, model
switch) it is dropped and the text sits unsent in the input box — the child
looks alive but never works. A completion popup can also swallow the Enter:
pi's editor accepts the highlighted suggestion (typing e.g. `.agents/` after
the prompt) and returns without submitting, so "the pane changed" is no
proof of delivery. `sub-send.sh` and the spawn path go through the shared
`tmux_send_line` helper
([scripts/_sub-common.sh](file://scripts/_sub-common.sh)), which re-types the
text when it did not appear and drives its `Enter` retries from submission
evidence: inside pi the send only succeeds once the prompt has **left the
composer and appears in the transcript** — pane noise, redraws, and
completion mutations never count — and it **fails loudly** after bounded
retries when it cannot confirm. When driving a child with raw
`tmux send-keys` (or any other way), apply the same rule yourself: send the
text first, send a separate `Enter` keystroke, then **verify** it was
submitted (the pane shows the child working, or `sub-status.sh` shows
progress) and press `Enter` again if the prompt is still sitting in the input
buffer.

**3. Monitor a child:**

```bash
"$SCRIPTS/sub-status.sh" fix-auth <repo>  # lease + git + pane + report
"$SCRIPTS/sub-changes.sh" fix-auth <repo> # just the diffs/commits
# fallback: tmux capture-pane -t pi-fix-auth -p | tail -40
```

**4. Reporting — children report to the main session** with two channels:

- *Durable report*: the child writes its findings to
  `tmp/pi-sub/reports/<task>.md` as it works (the main session reads files at
  leisure).
- *Push notice*: when done (or blocked), the child runs from its own shell:

```bash
"$SCRIPTS/sub-report.sh" fix-auth "DONE: migration done, 2 tests failing -> tmp/pi-sub/reports/fix-auth.md"
```

which injects `[fix-auth] DONE: …` into the main session's input through the
shared verified send: `sub-report.sh` **verifies the notice was actually
submitted** (it re-types the text and re-submits via `tmux_send_line`) and
**fails loudly** — `ERROR:` on stderr, non-zero exit — when the main session
is missing, tmux is unavailable, or the notice still cannot be confirmed,
always pointing back at `tmp/pi-sub/reports/<task>.md`. It never reports a
delivery that did not land and never suggests another notification
mechanism. The main session
also polls `sub-status.sh <task>` for children that do not push. Treat the
report file as the source of truth and the push as a notification.

**Relay child completions immediately**: as soon as a `DONE:` / `BLOCKED:`
notice arrives (or a poll shows a child finished — PR opened, tests green),
report it to the user in the very next reply, unprompted: task, PR link, test
status. Never sit on a finished-child report waiting for the user to ask
"what's ready?".

**5. Child pushes branch and creates the PR — never merge into the base branch.**
The child session itself pushes its branch (`git push -u origin task/<name>`) and opens a pull request against the resolved base branch (`$BASE_BRANCH`: `$DEV_BRANCH`, or the `origin/HEAD` default when it is gone) using `gh pr create` as the final step of its work, including the PR link in its report and `DONE` notice. Never run `git merge` / `git cherry-pick` into the base branch from the main checkout.
Do **not** retire the child yet when the PR is open: the child stays alive until the PR is merged (step 6), so it can address review feedback, rebase against new base-branch commits, or answer questions about the work.

**6. Retire a child** — only once its PR is **merged** (or the user explicitly
abandons it). **As soon as the PR is merged, retire the child immediately and
automatically — do not ask the user first** (user directive, 2026-09-26): a
merged PR ends the child's life cycle, so merge ⇒ retire, every time. Keep the
child's tmux session and worktree lease alive between step 5 and the merge;
retiring earlier strands review follow-ups. Before disposing of or retiring
any child, check whether its worktree has uncommitted, unpublished, or
otherwise potentially lost changes. Notify the user if any such changes
exist, and require the user's confirmation before force-discarding them.
A **squash merge** makes `sub-retire.sh` see the branch as "not merged" even
though everything is published: verify content is fully in `origin/development`
with `git diff origin/development..<branch>` (empty diff = nothing lost), then
retry with `--force`.

**Uncommitted changes are handled by instructing the child, not by force.**
When a child returns (or is about to be retired) with uncommitted or
unpublished changes in its worktree, the main session must not discard them
and must not just ask the user what to do: send the child a follow-up
instruction itself (`sub-send.sh <task> "..."`) telling it to commit, push,
and open/complete its PR, then re-check. Only when the child genuinely
cannot finish (or the user explicitly abandons the work) fall back to asking
the user about `--force`.

```bash
"$SCRIPTS/sub-retire.sh" fix-auth <repo>         # refuses lost work
"$SCRIPTS/sub-retire.sh" fix-auth <repo> --force  # after the PR is merged, or discard
```

It kills tmux session `pi-fix-auth` and returns the worktree. Manual
equivalent: `tmux kill-session -t pi-fix-auth; treehouse return --force "$WT"`
(resets the worktree!).

A successful retirement also runs best-effort **branch cleanup**: the local
`task/<name>` is deleted with `git branch -d` only when it is fully merged into
the dev base (kept with a warning otherwise), and the remote branch is deleted
only when its PR is merged or — with no open PR — its tip is merged into
`origin/<dev-base>`; an open PR always keeps the remote branch. Deletion
problems are warnings, never failures; skip it with
`sub-retire.sh <task> --no-branch-cleanup`. GitHub also deletes head branches
automatically on merge (`delete_branch_on_merge` is enabled for this repo).

**Merging a PR also deletes its associated local branch** (user directive,
2026-10-03): whenever you merge a PR yourself — the *merge on request*
housekeeping step, `gh pr merge <n> --squash` and friends — finish the job in
the same step by pulling the dev base and deleting the PR's local branch from
the main checkout: `git branch -D <branch>`. Before deleting, confirm nothing
would be lost with `git diff origin/<dev-base>..<branch>` (empty = safe; a
squash merge makes plain `-d` refuse, hence `-D`). When the diff is not empty,
keep the branch and warn instead. Remote heads are GitHub's business
(`delete_branch_on_merge`), the local branch is yours.

Every successful retirement also appends an `operation` entry to the
conversation log (`retired <task> | session cost: $0.1234`), with the cost
summed from the child's own pi session records in its agent directory. A
missing cost source or a failing log only warns — it never changes the
retirement's outcome.

### Conversation logging — prompts, replies, and child traffic

Besides the `operation` entries the helpers write, the main session keeps a
verbatim transcript of the conversation itself in the same weekly log
(`logs/conversations/`), appended **as the exchange happens**, never batched
at the end:

| kind | What to append |
|---|---|
| `prompt` | The user's prompt, verbatim, right before answering it — one entry per prompt. |
| `reply` | The main session's final answer to that prompt, verbatim, right after sending it. |
| `child-out` | Every message the main session sends to a child: the spawn kickoff (a one-line summary plus the `tmp/pi-sub/tasks/<task>.md` path when the brief lives in a file), every `sub-send.sh` instruction, and relays of the user's answer to a child's `QUESTION`. |
| `child-in` | Every message a child sends back: `DONE:` / `QUESTION:` / `BLOCKED:` notices and the report content relayed to the user, with the `tmp/pi-sub/reports/<task>.md` path. |

Rules:

- One entry per exchange, via `conversation-log.sh append <kind> "<text>"`;
  the script flattens multi-line text into a single log line, so paste the
  text as-is.
- Appends are blind — the log is never read during normal operation, so no
  dedupe or "what already got logged" checks.
- A failing log only warns; it never blocks, delays, or rewrites a reply or
  a piece of child traffic.
- Read side is unchanged: logs are read only to resolve operational issues.

### Prompt template: spawn a subsession

**Minimal trigger — this is enough:**

```text
fix issue #42 in project alpha
```

Given only that, the main session fills in the rest itself:

1. **Locate the repo** — resolve `project alpha` to its checkout (e.g.
   `~/programming-projects/project-alpha`); it is the cwd only if you are
   already in it, otherwise pass it explicitly.
2. **Fetch the requirements** — read the issue
   (`gh issue view 42 -R <owner/project-alpha>`, or the tracker/TUI of
   choice) and turn it into the requirements paragraph; if the issue cannot
   be read, ask instead of guessing.
3. **Infer the task name** from issue + repo (see Naming below), e.g.
   `alpha-42-fix-utf8-login`.
4. Write the brief to `tmp/pi-sub/tasks/<task>.md`, run
   `$SCRIPTS/sub-spawn.sh <task> <repo>` and report back: task name,
   worktree path, branch, tmux session name.

The task name and requirements are therefore **optional in your message**:
include them only to override what the main session would infer. Names in
any message are resolved as described in *Referring to a subsession* below.
Full form (when you want to control the details):

```text
Start a new subsession for this task: <one-paragraph
description of the requirements>.
(Optionally name it <task-name>; omit that and I will derive a kebab-case
name from the task.)

Steps:
1. Pick a kebab-case task name (see Naming in AGENTS.md).
2. Write the full requirements to tmp/pi-sub/tasks/<task-name>.md, including the
   instruction to write the final report to tmp/pi-sub/reports/<task-name>.md.
3. Run: "$SCRIPTS/sub-spawn.sh" <task-name> <repo>
   (leases the worktree holder <task-name>, bases it on the resolved base
   branch, boots pi in tmux session pi-<task-name>, kicks the child off with
   the brief).
4. Read its output and tell me the task name, worktree path, branch, and
   tmux session name.
```

Short form when the main session already knows these conventions:

```text
Spawn a subsession for: <one-paragraph description>.
Infer a kebab-case task name, write the brief to tmp/pi-sub/tasks/<name>.md, run
"$SCRIPTS/sub-spawn.sh" <name> <repo>, and report back the task name, worktree
path, branch, and session name.
```

Include more than the minimal trigger only when something must be explicit:
the **requirements** if they aren't in a readable issue, the **repo** if it
is ambiguous, the **report path** if it should differ from the default
(`tmp/pi-sub/reports/<task-name>.md`), or a **task name** when it must match an
external identifier.

**Briefs never spell out the process flow** (user directive, 2026-10-02):
do not copy the new-feature-fix → implement → code-auditor steps — or any other
process description — into `tmp/pi-sub/tasks/<task>.md`. The child gets the
flow from the **project's own `AGENTS.md`**, which it reads at startup; the
brief carries only the *what*: the requirement/issue, context/constraints, and
deliverables (branch, PR, report path). One line suffices — e.g. *"Follow the
`new-feature-fix` flow per this repo's AGENTS.md."* Never re-derive in a brief a
process the repo already documents.

### Referring to a subsession

Any mention of a project/task name — *"what is the state of alpha"*, *"give
me the changes in alpha"*, *"fix issue #42 in alpha"* — resolves to that
project's subsession(s) before anything else. The main session maps the name
to the artifacts this pattern maintains:

| Artifact | Location |
|---|---|
| Child process/pane | tmux session `pi-<task>` |
| Worktree + branch | the `treehouse` lease whose holder = task name |
| Requirements | `tmp/pi-sub/tasks/<task>.md` |
| Report (source of truth) | `tmp/pi-sub/reports/<task>.md` |

Then it classifies the intent:

- **Query about state** — *"state/status/progress of alpha"*:
  `"$SCRIPTS/sub-status.sh" <task> <repo>` (lease + pane + report in one shot). No
  spawning.
- **Request for artifacts** — *"changes/diffs/results in alpha"*:
  `"$SCRIPTS/sub-changes.sh" <task> <repo>` (status, commits vs `$DEV_BRANCH`, diff
  stats), or read the report file. No spawning.
- **Imperative to do new work** — *"fix issue #42 in alpha"*: run
  `"$SCRIPTS/sub-spawn.sh"` — **unless** a live subsession for that task
  already exists (spawn refuses to double-book anyway), in which case route
  the new instruction to the existing child instead.
- **Ambiguous name** — several live subsessions in the project, or no
  matching subsession but the name looks like a query: list what exists
  (`tmux ls`, `treehouse status`) and ask, don't guess.

`alpha` here is shorthand: it matches the project/repo name **or** a task
name (so *state of fix-utf8-login* and *state of alpha* can point at the same
subsession). With no match at all, say so and offer to start one.

### Naming

Whatever names the session (you or the main session), the task name is the
one identifier the whole pattern keys on: it becomes the tmux session
(`pi-<task>`), the lease label, and the file names (`tmp/pi-sub/tasks/…`,
`tmp/pi-sub/reports/…`). When inferring it from context:

- Make it kebab-case and say *what* the task does, not how
  (`fix-auth-refresh` ✅, `task-1` ❌).
- Keep it short (2-4 words); it is used verbatim in shell commands.
- Reuse an external identifier verbatim when one exists
  (`riak-1234-fix-login` for ticket RIAK-1234).
- Make it unique among live sessions — check `tmux ls` and
  `treehouse status` first; if it collides, disambiguate (`fix-auth-2`)
  rather than reusing the name.

### Conventions

- Prefer the `scripts/sub-*.sh` helpers over raw tmux/treehouse/git command
  sequences; they encode every rule below (and refuse double-booking,
  lost-work retirements, and wrong-base branches for you).
- **Never pipe helper output through a truncating reader** (`… | head -N`,
  `head -c`, `| tail -n +K`): when that reader exits early it closes the
  helper's stdout pipe, the helper's writes die with SIGPIPE (141) under
  `set -euo pipefail`, and its `cleanup_on_error` trap rolls back a
  *healthy* child — killing a freshly booted session and its lease (RCA:
  2026-10-02 `head -14` incident, `tmp/pi-sub/reports/spawn-failure-rca.md`;
  the truncation also swallowed the decisive `WARNING:`). Capture the full
  output into a variable or a temp file first, then read as much or as
  little as you want (`$(cmd …)`, `cmd > f; sed -n '…p' f`); a plain
  `| grep`/`| tail -50` is also safe — only an early-exiting *bounded* read
  closes the pipe. Same rule for `sub-report.sh` notices: never truncate.
- `pi-main` for the orchestrator, `pi-<task>` for each child; one concern per
  session, same rule as every other tmux session. **Verify the orchestrator is
  actually named `pi-main`** (`tmux display-message -p '#S'`) or set
  `MAIN_SESSION` to its real name — children address notices to `pi-main` by
  default, and a misnamed orchestrator silently misses them.
- Children never talk to each other — all coordination goes through the main
  session (star topology); the main session is the only orchestrator.
- **One child per issue** (user directive, 2026-10-05): when a request covers
  2 or more issues, spawn a separate child for each issue — never bundle
  several issues into one child's brief.
- The main session delegates all implementation work (see *Delegation
  mandate*); if it is editing repo files or running mutating commands to
  "just fix it", it is violating the pattern.
- **Keep children alive until their work is fully merged**: opening the PR
  (step 5) does **not** end the child — do not kill its session or return its
  worktree then. It stays up (tmux session + treehouse lease) so it can handle
  review feedback, rebases, and follow-up instructions; retire it (step 6)
  only after the PR is merged, or once the user explicitly abandons the work.
  **Once the PR *is* merged, retire the child right away without prompting** —
  merged ⇒ retired automatically (see step 6).
- **PR before you return**: `return --force` resets the worktree — always
  push the child's branch and open a PR (step 5) before retiring the child, or
  the local commits are lost. The pushed branch is the durable copy; merging
  the PR is the human's job, never the orchestrator's.
- Long tasks go in files (`tmp/pi-sub/tasks/<task>.md`), reports go in files
  (`tmp/pi-sub/reports/<task>.md`); keep `send-keys` payloads to single lines.
  These scratch files are gitignored and deleted on retire (`sub-clean.sh`
  sweeps leftovers), so treat the report as transient — copy anything durable
  into the PR description or an issue before retiring.
- Check `tmux ls` and `treehouse status` before spawning to avoid double
  booking a name or a worktree — or let `sub-spawn.sh` check for you.
- Alternatives to tmux orchestration when you don't need visible panes:
  `pi -p` for one-shot tasks, the subagent extension (in-process delegation,
  `~/.pi/agent/extensions/subagent`), and `pi --mode rpc` for a programmatic
  JSONL control channel.
