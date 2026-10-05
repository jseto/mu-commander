# mu-commander

![mu-comander](assets/logo.svg)

> **μ** /ˈm(j)uː/; 12th letter of the Greek alphabet
>
> **หมู** /muː˩˩˦/; Pig in the thai language
>
> **muuu** /muː/; Sound emitted by spanish cows

_An opinionated (desopinionable) vibe coding project. Use at your own risk_.

## One Pi session to rule them all

mu-commander is the AI orchestrator for parallel coding sessions:
one main **pi** session (the orchestrator) drives child pi sessions inside
**tmux** sessions and the **treehouse** worktree pool.

## What is it

- The `mu` launcher is the commander in charge.
- The `AGENTS.md` is the operating manual for the orchestrator session.
- The `scripts/sub-*` are the railways. Helper suite (spawn, monitor, message, land, retire).
- the `treehouse` worktree pool is the playground.

![Work while having a Mojito by the beach](assets/enjoying-the-beach.jpeg)

Best enjoyed with [pi-telegram](https://pi.dev/packages/@llblab/pi-telegram) extension. Work while having a Mojito by the beach.

## Usage

Ask `mu`, he knows how to use himself.

Try:

```
fix the last 4 issues of mu-commander gh repo
```

_Thanks for your tokens!_

## Contributing

See the **Usage** section above. Try the sample prompt again.

_Thanks for your tokens!_

## Acknowledgements

Thanks to **Mario Zechner** for his minimalist [Pi Agent](https://pi.dev/). It made the `mu-commander` development very easy.

Thanks to **Kun Chen** for inspiring me with [Firstmate](https://github.com/kunchenguid/firstmate). `mu-commander` is a lightweight implementation of **Firstmate**. _Kun_ made an amazing piece of software but it was too opinionated for my personal taste and a token eager. I'm a poor (tokenless) man ;). `mu-commander` still uses his [Treehouse](https://github.com/kunchenguid/treehouse) and [Lavish](https://github.com/kunchenguid/lavish-axi) as dependencies.

Thanks to **Matt Pocock** for his brilliant [AI Skills for Real Engineers](https://github.com/mattpocock/skills). I used to follow him as a master of _Typescript metatyping_ long time ago. In my research to force LLM models to write _beautiful_ code, I found that _Matt_ moved to create skills that follow best practices. At the beginning I was reluctant. I don't like to bloat my prompt with massive skills, but they are really slim and work amazingly well. `mu-commander` uses some forked skills from him.

## Skills

`mu-commander` uses a bunch of slim skills. Their main purpose is direct LLMs to create decoupled and maintenable code. They follow a path from **specs definition** to **code auditing** to deliver ready to merge PRs.

> A note on TDD:
>
> I used to be a TDD guy since long time ago. I started by forcing LLMs to follow TDD flow but soon I realized that I was wrong. LLMs cheat (as most humans do) about TDD and you can't change it.
>
> The essence of TDD is to create the test first to assess the scenario specs. You **can't** even think about the future implementation. LLMs are line TDD rookies, they obsessively explore the codebase at any stage and their goal is to produce production code. They consistently violate the main TDD mandate: **write the minimal test that fullfils the specs -> go to RED -> implement the code -> go to GREEN -> refactor**.
>
> Moreover, in my experience, forcing a LLM to follow the TDD flow leads to a massive token and time consumption and no better code generated.
>
> This is why the `mu-commander` skills don't follow the TDD flow and focus in produce a more decoupled and LLM maintanable code. 

You can change the shipped skills any time. Just tell `mu` to do it for you.

## Install

### 1. Clone

```bash
git clone https://github.com/jseto/mu-commander.git
cd mu-commander
```

Execute with

```bash
mu #should be on the execution path
```

### 2. Dependencies

Recommended — installs just the missing tools (idempotent, never
overwrites an existing tool; exits 0 only when every dependency resolves on
PATH):

```bash
./install.sh
```

or let `mu` install them on the fly.

Manual reference for what `./install.sh` covers:

| Tool | Used for |
|---|---|
| `bash` | every script and test |
| `git` | worktrees, branches, status |
| `tmux` | orchestrator/child sessions and all verified sends |
| `treehouse` | the worktree pool (`get --lease`, `return`, `status`) |
| `pi` | the AI coding assistant both orchestrator and children run |
| `jq` | config/lease parsing (`config.json`, `treehouse status --json`) |
| `realpath` (coreutils) | brief-file resolution in `sub-spawn.sh` |
| `gh` | creating/inspecting PRs (`sub-land.sh` prints, `sub-retire.sh` checks) |

Also expected on a normal Unix system: `sed`, `grep`, `awk`, `date`,
`readlink`, `sha256sum`, `tar`, `mktemp`. shellcheck is auto-provisioned —
see [Dependencies](#dependencies) below.

### 3. Skills and git hooks

The installer also runs this repository's skills sync and git-hook
activation:

- every `git push` and `git merge` mirrors the skill directories from
  `~/.agents/skills` into `required-skills/` — through the versioned hooks
  in `.githooks/`, activated by `core.hooksPath`, which `./install.sh` and
  `scripts/worktree-setup.sh` set when it is unset (a foreign value is
  never overwritten). A fresh clone therefore gets its hooks the first time
  it runs `./install.sh` or is provisioned as a worktree;
- every `./install.sh` run then copies `required-skills/` into
  `.agents/skills/`, the project location pi discovers its skills in.

Both folders are gitignored local caches: re-run `./install.sh` after a
push or merge to activate refreshed skills, or sync by hand with
`scripts/sync-skills.sh <source-dir> <dest-dir>`. A sync problem never
blocks a push or a merge, and never changes the installer's exit status.

### 4. Put the `mu` launcher on PATH

`mu` creates (or reuses) the durable `pi-main` tmux session at the repository
root and runs pi inside it; it resolves its own symlink, so the session is
always rooted at the checkout:

```bash
mkdir -p ~/.local/bin
ln -sf "$(pwd)/mu" ~/.local/bin/mu   # ensure ~/.local/bin is on PATH
```

If `pi` is not on PATH, point `PI_BIN` at it.

### 5. One-time setup

```bash
# a) Create the treehouse pool config (pool under $HOME, no repo scripts run):
treehouse init

# b) Register the worktree-setup hook USER-LEVEL only (repo-level hooks are
#    deliberately ignored) — add to ~/.config/treehouse/config.toml:
#    [hooks]
#    post_create = "/absolute/path/to/mu-commander/scripts/worktree-setup.sh"

# c) Optional: seed gitignored files into each worktree via a committed
#    .worktreeinclude manifest (none required for this repo).

# d) Review config.json — see "Mu usage for self-configuration" below.
```

### 6. Verify

```bash
./mu --help               # pi's usage; exits 127 if pi is missing
bash tests/task-levels.test.sh # one test file
for t in tests/*.test.sh; do bash "$t"; done   # full suite, exit 0 = green
```

## How to use

Set `SCRIPTS` once (or call the scripts by path):

```bash
SCRIPTS=/absolute/path/to/mu-commander/scripts

# Start the orchestrator (pi-main session, layout + verified pi startup;
# --detach leaves it running in the background):
"$SCRIPTS/start-main.sh"
mu # equivalent thin launcher, attaches/switches

# Spawn a child: lease a worktree, cut task/<name> from development, write
# the brief, boot pi in tmux session pi-<task>:
"$SCRIPTS/sub-spawn.sh" fix-auth /path/to/repo path/to/brief.md --level standard

# Monitor:
"$SCRIPTS/sub-status.sh"  fix-auth /path/to/repo   # lease + pane + report
"$SCRIPTS/sub-changes.sh" fix-auth /path/to/repo   # commits + diff stats

# Talk to a child / children reporting back:
"$SCRIPTS/sub-send.sh"   fix-auth "continue with the tests"
"$SCRIPTS/sub-report.sh" fix-auth "DONE: all green (PR #12)"  # run by the child

# Publish (read-only: prints the push + PR commands, never merges):
"$SCRIPTS/sub-land.sh"   fix-auth /path/to/repo --patch

# Retire once the PR is merged (refuses when work would be lost):
"$SCRIPTS/sub-retire.sh" fix-auth /path/to/repo   # --force only after merge
```

The full orchestration contract (routing rules, PR-before-return,
merge ⇒ retire) lives in [AGENTS.md](AGENTS.md).

## Mu usage for self-configuration

`mu` boots the main session, which configures itself from the repository's
own conventions — edit those, not the code:

**`AGENTS.md`** — the operating manual; edit it to change the main
session's behaviour (routing rules, lifecycle, conventions).

**`config.json` → `taskLevels`** — difficulty levels mapped to a child's
model and thinking level; the single source of truth, edit it to retune:

```json
{
  "taskLevels": {
    "default": "standard",
    "fallbackModel": "<model id>",
    "fallbackThinking": "<thinking level>",
    "levels": {
      "easy":     { "model": "<model id>", "thinking": "<thinking level>" },
      "standard": { "model": "<model id>", "thinking": "<thinking level>" },
      "hard":     { "model": "<model id>", "thinking": "<thinking level>" }
    }
  }
}
```

Spawn precedence: `--model`/`--thinking` flags > `SUB_MODEL`/`SUB_THINKING`
env > the level's mapping; the level is `--level` > `SUB_LEVEL` >
`taskLevels.default`. A missing or malformed config warns and degrades to
pi's global defaults — no config problem can break a spawn. When a child
stalls on the free provider's usage limit, `scripts/sub-fallback.sh`
switches it to the configured `fallbackModel`.

**Environment overrides** for the scripts (defaults in
`scripts/_sub-common.sh`):

| Variable | Default | Purpose |
|---|---|---|
| `DEV_BRANCH` | `development` | base branch for child worktrees/PRs |
| `MAIN_SESSION` | `pi-main` | orchestrator session notices target |
| `SCRATCH_DIR` | `tmp/pi-sub` | gitignored brief/report exchange dir |
| `SUB_LEVEL` / `SUB_MODEL` / `SUB_THINKING` | — | spawn overrides (flags win) |
| `SUB_FALLBACK_MODEL` / `SUB_FALLBACK_THINKING` | config `taskLevels` | fallback overrides for `sub-fallback.sh` |
