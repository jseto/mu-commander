# Design: dependency installer (`install.sh`)

## Summary

One new root-level artifact — `install.sh` — plus a hermetic test suite
`tests/install.test.sh` and a README pointer. The installer walks the
dependency list README.md documents (`bash`, `git`, `tmux`, `treehouse`,
`pi`, `jq`, `realpath`, `gh`, `sed`, `grep`, `awk`, `date`, `readlink`,
`sha256sum`, `tar`, `mktemp`, `shellcheck` — 17 tools) together with the
repository's own `mu` launcher (README.md, Installation -> 4. Put the `mu`
launcher on PATH) — 18 entries in all — partitions it into
*present* (resolves on PATH) and *missing*, and only ever acts on the
missing side:

| Category | Missing → action |
|---|---|
| system tools (14) | one package-manager run: `apt-get install -y` / `dnf install -y` / `pacman -S --noconfirm --needed` / `brew install`, prefixed with `sudo` only when `EUID != 0` and `sudo` exists (never for `brew`); no package manager or no mapped package name → per-tool manual hint, keep going |
| `treehouse` | resolve latest release of `kunchenguid/treehouse` (GitHub API), download `treehouse-v<tag>-<os>-<arch>.tar.gz` + `checksums.txt`, verify with `sha256sum`/`shasum`, install into `~/.local/bin` — never over an existing file |
| `pi` | `npm install -g --ignore-scripts @earendil-works/pi-coding-agent` (the command pi's own README documents; the package `bin` is `pi`); no npm → instructions (Node.js ≥ 22.19, the npm command, `curl -fsSL https://pi.dev/install.sh | sh` as the official alternative), keep going |
| `shellcheck` | delegate: run `scripts/worktree-setup.sh` (the treehouse hook holding the pinned version + sha256 table); the installer declares no pin of its own |
| `mu` | symlink `~/.local/bin/mu` → the **main checkout's** `mu` when git reveals one (the git common dir; pooled worktrees are ephemeral, see `specs/mu-launcher`), else this checkout's `mu`; `mkdir -p ~/.local/bin` first; never over an existing entry — file **or** symlink, even a broken one |

Every install attempt is followed by a `command -v` re-check — the summary
only claims *installed* when the tool actually resolves afterwards. The run
ends with a three-bucket summary (installed / already present / needs manual
action, each manual entry carrying its hint) and exits 0 only when the
missing bucket is empty; a second run with everything present is a pure
no-op.

### Decisions

| Option | Verdict |
|---|---|
| `scripts/install-deps.sh` | rejected: README's "Installation" flows read top-down from the clone step; a root `install.sh` sits exactly where a new user looks, matching `mu` being root-level too. (The brief's suggested primary name.) |
| re-implement `need`-style detection locally | rejected: `install.sh` sources `scripts/_sub-common.sh` and reuses `info`/`warn`/`die`; detection is the same `command -v` convention, but collected per tool (`have`) instead of dying on the first miss, because the installer's contract is "report everything, then summarize" |
| duplicate the shellcheck pin | rejected: `scripts/worktree-setup.sh` is the declared single source of truth (`SHELLCHECK_VERSION` + sha256 table); the installer *runs* it (cwd = repository root, where no target-repo manifests exist, so its other steps are no-ops) and re-checks `command -v shellcheck` |
| `apt`/`dnf`/… auto-detect how? | first of `apt-get`, `dnf`, `pacman`, `brew` on PATH — no `os-release` parsing, trivially sandboxable in tests; on a machine with two managers the first wins (Linuxbrew behind apt is the desired order) |
| pin the treehouse version? | no: the repo has no treehouse pin anywhere (AGENTS.md names "v2.3.0" descriptively, upstream is at v3.1.0) and treehouse self-updates (`treehouse update`); the installer resolves *latest* and sha256-verifies it against the release's own `checksums.txt` |
| exit status when manual action is needed | non-zero: "exit non-zero only on real failure" is read as *a dependency still missing after the run is a real failure of the installer's contract*; the no-op all-present path is the guaranteed 0. Manual-hint runs keep going (REQ-3) but end non-zero (REQ-10) so automation cannot mistake a partial machine for a ready one |
| should the installer put `mu` on PATH? | yes — the installer originally stopped at README's *Installation -> 2. Dependencies*, leaving the separate manual step *-> 4. Put the `mu` launcher on PATH* outside its contract: `./install.sh` could exit 0 while `command -v mu` still failed (the reported "why is mu not executable" symptom — the file itself was mode 755 everywhere). The launcher link is now its own category with the same no-overwrite + re-check contract (REQ-11) |

## Entities

- **`install.sh`** (new, repository root, executable) — sections:
  resolve own dir → source `_sub-common.sh` → tool inventory
  (`SYSTEM_TOOLS`, `CUSTOM_TOOLS`) → partition with `have` → per-category
  installers (`install_system`, `install_treehouse`, `install_pi`,
  `install_shellcheck`, `install_mu`) → `summarize` + exit. `set -uo pipefail`, no
  `set -e`: failures are collected, never fatal mid-run.
- **`tests/install.test.sh`** (new) — one assertion block per `[REQ-n]` plus
  supplementary checks (failed package-manager run doesn't abort other
  categories, treehouse checksum rejection, shellcheck lint). Fully
  hermetic: runs `install.sh` under `env -i` with a **restricted PATH**
  (sandbox-only), a fake `HOME`, and stub `apt-get`/`dnf`/`pacman`/`brew`/
  `sudo`/`curl`/`tar`/`npm` binaries that log their argv and simulate
  installation — no real package manager, network, or home directory is
  touched. "Missing tool" = no entry on the sandbox PATH; "present tool" =
  symlink to the real binary or a stub.
- **`README.md`** (modified) — *Installation → 2. Dependencies* gains the
  recommended `./install.sh` path; the manual table stays as reference.
- **`specs/install-script/`** (new) — this design + `install-script.feature`.

Not touched: `scripts/_sub-common.sh` (sourced read-only),
`scripts/worktree-setup.sh` (invoked, unchanged), every other script.

## Behaviour and data flow

```mermaid
flowchart TD
  A[install.sh] --> B[have() each of 18 tools<br/>command -v, need-style]
  B --> C{anything missing?}
  C -- no --> Z1["all present" + summary<br/>exit 0]
  C -- yes --> D[system tools missing?]
  D --> E{package manager on PATH?<br/>apt-get / dnf / pacman / brew}
  E -- none --> H1[per-tool manual hints]
  E -- yes --> F[pkg_for tool pm:<br/>mapped? → one install run<br/>root? else sudo]
  F --> G[command -v re-check each tool]
  G --> H{resolved?}
  H -- yes --> I[installed]
  H -- no --> H2[failed → manual hint]
  D --> J[treehouse missing?]
  J --> K[existing ~/.local/bin/treehouse?<br/>→ PATH hint, no write]
  K -- no --> L[latest release → tarball + checksums.txt<br/>verify sha256 → install → command -v]
  J --> M[pi missing?]
  M -- npm --> N[npm install -g --ignore-scripts<br/>@earendil-works/pi-coding-agent → command -v]
  M -- no npm --> H3[Node ≥ 22.19 + npm command<br/>+ pi.dev installer hint]
  J --> O[shellcheck missing?]
  O --> P[run scripts/worktree-setup.sh<br/>cwd = repo root → command -v]
  P -- still missing --> H4[point at shared install]
  O --> MU[mu missing?]
  MU --> MU1{existing ~/.local/bin/mu<br/>entry?}
  MU1 -- yes --> H5[PATH / relink hint,<br/>no write]
  MU1 -- no --> MU2[ln -s main-checkout/mu<br/>→ command -v re-check]
  MU2 -- resolves --> I
  MU2 -- off PATH --> H5
  I --> Q[summary:<br/>installed / already present /<br/>needs manual action]
  L --> Q
  N --> Q
  H1 --> Q
  H2 --> Q
  H3 --> Q
  H4 --> Q
  H5 --> Q
  Q --> Z2["missing empty → exit 0,<br/>else exit 1"]
```

Failure handling: a package-manager failure, a checksum mismatch, a missing
downloader, a failed `npm`/hook invocation — each lands its tools in the
*needs manual action* bucket with a printed hint and never aborts the
remaining categories ([REQ-3]/[REQ-10]); the exit status is derived solely
from whether anything is still missing at the end.

## Steps

1. [x] Specs: `install-script.feature` + this design doc.
2. [x] RED: `tests/install.test.sh` (REQ-1…REQ-11 + supplementary),
       observed failing (no `install.sh` yet).
3. [x] GREEN: implement `install.sh`.
4. [x] REFACTOR + full suite green + shellcheck clean on touched files.
5. [x] Docs: README *Installation → 2. Dependencies* recommends the
       installer; manual table retained (covered by REQ-11).
6. [x] Code-auditor pass (see Audit notes) + re-run of the suite.
7. [x] Commit, push, PR against `development`.

Mu-launcher steps (task `diagnose-mu-launcher`, root cause "why is mu not
executable" — the file was executable everywhere; the README -> 4 PATH link
was simply never created):

8. [x] Specs: REQ-11 scenario in the feature + these design rows.
9. [x] RED: `tests/install.test.sh` gains `t_req11` (link created, main-
       checkout preference via the git common dir, no-overwrite, idempotent
       re-run); existing blocks updated for the 18-entry inventory.
10. [x] GREEN: `install_mu` in `install.sh` (`CUSTOM_TOOLS += mu`).
11. [x] Code-auditor pass on the mu change + full-suite re-run.
12. [x] Commit, push, PR against `master`.

## Strengths / Weaknesses

- Strengths: one entry point that is honest about everything it cannot do
  (every skip is a visible hint with an exit status to match); no pin
  duplication (shellcheck) and no invented install paths (treehouse/pi come
  from their upstreams' documented channels, verified in this flow); the
  restricted-PATH sandbox makes all four package-manager branches and the
  download paths testable without touching the machine.
- Weaknesses: package-name mapping is a hand-maintained table (mitigated:
  an unmapped pair degrades to a manual hint instead of a wrong install);
  `brew`'s g-prefixed GNU coreutils means an installed `coreutils` may still
  leave `realpath` unresolved — the post-install re-check reports exactly
  that rather than trusting the package manager; the GitHub API is called
  once per treehouse install (no caching — acceptable for a rare,
  manual-run tool).
- Left out deliberately: `--dry-run`/flags beyond `-h`, `apt-get update`,
  version pinning of system packages, Windows (the repository's scripts are
  bash/tmux throughout).

## Audit notes

Independent audit (code-auditor pass: read from disk
`specs/install-script/install-script.feature` + `install.sh` +
`tests/install.test.sh`; design doc excluded from evidence), evaluated
against the `codebase-design` vocabulary. Findings applied, then the full
suite re-run: **green (14/14 files; `tests/install.test.sh` 16/16
assertions)**, real-machine run still a clean no-op (exit 0).

- **Overview**: the installer is a deep module by this repository's
  standards — one interface (`./install.sh`, observed through its output
  and exit status) hides detection, four package managers, two custom
  download paths, hook delegation, and the summary. The test suite crosses
  exactly that seam (PATH sandbox + fake HOME) and never pokes internals;
  bucket state is derived (partition at start, re-check after every
  attempt), so every outcome path converges on the same three buckets.
  No structural friction was found; the findings were locality nits.
- **Files**: `install.sh` (2 small refactors applied),
  `tests/install.test.sh` (unchanged in the audit).
- **Problems found & applied**:
  1. The supported-package-manager list existed in **three** places
     (`pm_detect`'s loop, `pkg_for`'s guard, and the install-command
     `case`) — adding a manager could silently desync them. Applied: a
     single `PM_LIST` now feeds detection and the guard; the command-word
     `case` remains separate because those words are genuinely per-PM data,
     not a duplicated name list.
  2. The long treehouse no-overwrite hint was **duplicated** at both target
     checks (pre-download and the mid-download race re-check), so a wording
     change could drift between them. Applied: extracted
     `treehouse_offpath_hint`; both sites call it.
- **Noted, deliberately not changed** (each cosmetic, none worth the churn
  in an output-contract-tested script):
  1. `state_of` can return a third state (`manual`) that `summarize` never
     queries — the manual bucket rides on the `MANUAL` lines directly;
     collapsing it would trade the three-bucket vocabulary for one unused
     branch saved.
  2. `install_system` embeds Homebrew's g-prefix PATH advice inside the
     generic post-install check — platform knowledge in the generic path,
     but it sits exactly at the re-check that can observe the condition.
  3. The shellcheck delegation runs `worktree-setup.sh` with cwd =
     repository root, so future target-repo manifests in *this* repo would
     be installed by `./install.sh` — accepted: that is the installer's
     job, and today the repository has no manifests (verified).
- **Benefits**: package-manager knowledge has one home, hint wording is
  single-sourced, and both refactors kept every assertion string intact —
  proof the tests are pinned to behaviour, not implementation layout.
- **Before / After**: three drifting PM name lists → one `PM_LIST` +
  per-PM command words; two copies of the no-overwrite hint → one helper.
- **Recommendation strength**: **Speculative** — nothing rising to
  architectural friction was found; revisit only if a fifth package
  manager or a new dependency category lands.

Audit result: 2 small refactors applied; suite re-run after the audit:
green (14/14).
