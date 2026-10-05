# Design: drop document- and config-content assertions from the test suite

## Summary

A standing rule (user directive, 2026-10-03) says **tests must never assert
the contents of a document or a config file**: the suite exercises
behaviour, may feed fixtures as *inputs*, but the shipped `README.md`,
`AGENTS.md`, spec documents and `config.json` are not the subject under
test. `development` (tip `6e7c335`) violates the rule in three red suites
and a number of green ones; this change removes every such assertion, drops
its Gherkin scenario, and keeps the `[REQ-n]` ↔ scenario ↔ test traceability
consistent. Where a test mixed a shipped-config assertion into otherwise
legitimate behaviour coverage, the behaviour is kept and re-pointed at a
fixture config.

No product code changes: `config.json`, `scripts/*`, `README.md` and
`AGENTS.md` are untouched. Only tests (`tests/*.test.sh`) and their specs
(`specs/*/*.feature`, the `specs/readme/` folder) change.

## The rule

- A test may **drive** a script with a document/config as **input** and
  assert the script's observable behaviour (e.g. a fixture config passed
  through `SUB_LEVELS_CONFIG`).
- A test may **not** grep/compare the shipped content of `README.md`,
  `AGENTS.md`, a `*design.md`/`*.feature`, or `config.json` and fail on a
  wording/value mismatch. That couples the suite to documentation and turns
  every doc/config edit into a test failure.
- A repo-wide invariant that scans *all tracked files* as inputs (e.g. "no
  tracked file names an old project identifier") is not a document-content
  assertion: the document is one input among many to a repository-state
  check, not the subject. It stays.

## Audit — every document/config-content assertion found

| Test file | Scenario | Subject | Disposition |
|---|---|---|---|
| `tests/readme.test.sh` | all `[REQ-1]`…`[REQ-9]` | `README.md` structure/content | **Suite deleted**; `specs/readme/` removed (`README.feature` + `README-design.md`) |
| `tests/install.test.sh` | `[REQ-11]` | `README.md` install wording + dependency table | Test + scenario removed |
| `tests/rename-mu-commander.test.sh` | `[REQ-2]` | `AGENTS.md` checkout paths | Test + scenario removed |
| `tests/rename-mu-commander.test.sh` | `[REQ-4]` | `specs/…/*-design.md` exemption list | Test + scenario removed |
| `tests/rename-mu-commander.test.sh` | `[REQ-5]` | `AGENTS.md` role prose | Test + scenario removed |
| `tests/rename-project.test.sh` | `[REQ-6]` | `AGENTS.md` role prose | Test + scenario removed |
| `tests/retire-cost-log.test.sh` | `[REQ-7]` | `AGENTS.md` cost-log wording | Test + scenario removed |
| `tests/skills-sync.test.sh` | `[supp] README documents…` | `README.md` hooks/skills wording | Supplementary test removed (no scenario) |
| `tests/sub-report.test.sh` | `[REQ-8]` | `AGENTS.md` delivery contract | Test + scenario removed |
| `tests/sub-report.test.sh` | `[fix-send-confirm REQ-9]` | `AGENTS.md` evidence contract | Test + scenario removed |
| `tests/sub-retire.test.sh` | `[REQ-9]` | `AGENTS.md` cleanup wording | Test + scenario removed |
| `tests/worktree-setup.test.sh` | `[REQ-8]` | `AGENTS.md` dependency wording | Test + scenario removed |
| `tests/task-levels.test.sh` | `[REQ-1]` | shipped `config.json` default echo | Test + scenario removed |
| `tests/task-levels.test.sh` | `[REQ-2]`,`[REQ-3]`,`[REQ-4]` | shipped `config.json` values | **Behaviour kept**, re-pointed at a fixture config via `SUB_LEVELS_CONFIG` |
| `tests/free-limit-fallback.test.sh` | `[REQ-1]` | shipped `config.json` fallback echo | Test + scenario removed |
| `tests/free-limit-fallback.test.sh` | `[REQ-6]`…`[REQ-18]` pane tests | shipped `config.json` fallback values | **Behaviour kept**, `setup()` now writes a fixture config and points `SUB_LEVELS_CONFIG` at it |
| `tests/free-limit-fallback.test.sh` | `[REQ-12]`,`[REQ-16]` | `AGENTS.md` fallback wording | Test + scenario removed |

Retained repo-wide invariants that mention no document/config by name:
`tests/rename-mu-commander.test.sh [REQ-1]` and
`tests/rename-project.test.sh [REQ-1]` (rename invariant across all tracked
files), and `[REQ-3]` in both rename suites (implementation + test-file
literals).

## [REQ-n] traceability

Removed scenarios leave **gaps** in their `[REQ-n]` sequence; numbers are
historical identifiers, not a contiguous index (the suites already use
non-contiguous labels, e.g. `[REQ-14]`/`[REQ-17]`). Every remaining scenario
has exactly one remaining test and vice versa; no scenario is renumbered, so
the `[REQ-n]` chain stays unbroken for the scenarios that remain.

| Spec | Removed `[REQ-n]` |
|---|---|
| `specs/readme/README.feature` | `[REQ-1]`…`[REQ-9]` (folder removed) |
| `specs/install-script/install-script.feature` | `[REQ-11]` |
| `specs/rename-mu-commander/rename-mu-commander.feature` | `[REQ-2]`, `[REQ-4]`, `[REQ-5]` |
| the earlier rename's feature file | `[REQ-6]` |
| `specs/retire-cost-log/retire-cost-log.feature` | `[REQ-7]` |
| `specs/sub-report-notice/sub-report-notice.feature` | `[REQ-8]` |
| `specs/fix-send-confirm/fix-send-confirm.feature` | `[REQ-9]` |
| `specs/branch-cleanup-retire/branch-cleanup-retire.feature` | `[REQ-9]` |
| `specs/shellcheck-in-repo/shellcheck-in-repo.feature` | `[REQ-8]` |
| `specs/child-task-levels/child-task-levels.feature` | `[REQ-1]` |
| `specs/free-limit-fallback/free-limit-fallback.feature` | `[REQ-1]`, `[REQ-12]`, `[REQ-16]` |

## Fixtures used by the re-pointed tests

- `tests/task-levels.test.sh` writes `$SCRATCH/levels.json` with a
  `taskLevels` section (`default: standard`, `easy`/`standard`/`hard` →
  `fixture/*` models and thinking levels) and passes it through
  `SUB_LEVELS_CONFIG`. `[REQ-2]`/`[REQ-3]`/`[REQ-4]` assert the resolver's
  precedence against those values.
- `tests/free-limit-fallback.test.sh` writes `$SB/fixture-config.json` in
  `setup()` (`taskLevels.fallbackModel: opencode-go/mimo-v2.6-flash`,
  `taskLevels.fallbackThinking: high`) and points `SUB_LEVELS_CONFIG` at it.
  The free model in the fake status bar (`mimo-v2.6-flash-free`) still
  extends the fixture fallback id, so the `[REQ-14]` prefix-collision
  regression survives future `config.json` retunes.

## Verification

1. Scenario ↔ test correlation: each remaining `[REQ-n]` in a feature file
   appears in exactly one test name in its suite; each remaining test label
   appears in exactly one scenario.
2. Full suite: `for t in tests/*.test.sh; do bash "$t"; done` exits 0 for
   every suite.
3. No test reads `README.md`, `AGENTS.md`, a `*design.md`, a `*.feature`, or
   `config.json` as data (fixture configs under `$TMP`/`$SB` only).

## Strengths / Weaknesses

- **Strengths**: the suite is now decoupled from documentation and shipped
  config values, so a doc edit or a `config.json` retune can no longer turn
  it red; the behaviour coverage that mattered is preserved through fixtures;
  the `[REQ-n]` chain stays traceable.
- **Weaknesses**: removing the doc assertions also removes the (weak)
  documentation-drift signal those tests provided — a stale README/AGENTS
  claim is now invisible to CI. That signal was the wrong mechanism (it
  failed on *any* wording change), and any replacement guard would be a
  brittle test-about-tests; the coding conventions live in review, not here.
- **Left out deliberately**: a meta-test scanning `tests/` for document
  references (false-positive prone, and it would make the rule a test
  subject rather than a review convention); renumbering the remaining
  `[REQ-n]`s (needless churn and breaks historical references).

## Code audit (independent pass, post-implementation)

Audited from disk: the changed `*.feature` files and `tests/*.test.sh`,
without the conversational rationale; `*-design.md` excluded.

- **Overview**: no product code changed — the artifact is the test suite,
  and the audit's deletion test applies to it. Removing the doc/config
  assertions deleted a **dependency edge**, not a seam: each suite still
  crosses exactly the same interface it did before (the resolver with a
  `SUB_LEVELS_CONFIG` path, `sub-fallback.sh <task>`, `sub-retire.sh`,
  `sync-skills.sh`). The fixture conversions moved the config dependency
  from an ambient repository file to an explicit input owned by the test,
  which is the stronger coupling for a behavioural suite. No `scripts/*`
  seam was touched, so architecture is unchanged.
- **Files**: `tests/*.test.sh` (12 suites), `specs/*/*.feature` (10),
  `specs/readme/` (deleted), relative to `specs/no-doc-config-tests/`.
- **Problem / Solution / Benefits**: the friction was a coupling from the
  tests to mutable shipped text/config, not an interface problem; the
  solution removed it while keeping every `[REQ-n]` that describes
  behaviour. Locality improved — a doc edit or a `config.json` retune can
  no longer turn any suite red — and the fixture configs keep the
  resolver/pane tests self-contained.
- **Less valuable improvement** (noted, deliberately not done): a guard
test that scans `tests/` for reads of `README.md`/`AGENTS.md`/`config.json`
would mechanize the rule, but it is a test-about-tests whose static
heuristic (comments, fixture file names, `git grep` repo invariants)
misclassifies legitimate cases; the rename [REQ-1] repo-wide scan is the
clearest example of a legitimate mention. If the rule ever needs
enforcement, prefer a CI/review lint over a behaviour suite.
- **Recommendation strength**: Speculative; audit verdict — no architectural
  friction detected, ship it.
