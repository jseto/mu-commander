# Audit: fix-parked-prompt

Independent audit per the `code-auditor` skill (a separate `reviewer` agent,
reading the feature files and `scripts/_sub-common.sh` from disk, design doc
excluded, tests excluded from the architecture judgement). One **Strong** and
three **Worth exploring** findings; two accepted as documented residuals, the
rest applied.

## Findings and disposition

| # | Strength | Finding | Disposition |
|---|---|---|---|
| 1 | **Strong** | The "text never rendered" bail-out returns 1 **without pressing Enter**, although `send-keys` already handed the bytes to the pane's input queue: a composer that renders the line a frame later is stranded. | **Fixed** — `_pi_visible` polls visibility (`_PI_VISIBILITY_TRIES × _PI_TYPE_SETTLE`) instead of two fixed 0.4 s probes, and the final bail-out sends one last-resort Enter before failing (never a success claim). Spec REQ-9. |
| 2 | Worth exploring | `_pi_layout=0` (a pi pane whose status border did not resolve) fell back to the legacy "pane changed" check — the 2026-10-02 false success. | **Fixed** — `_pi_unresolved_pi_pane` treats a capture that shows pi's box-drawing chrome with no resolvable border as a pi pane (evidence only); strict mode also latches as soon as any capture resolves the layout. Spec REQ-7 (second scenario). |
| 3 | Worth exploring | `_pi_chrome_row` classified *any* line starting and ending with `─` as chrome, so a dashed-looking parked line would be pushed into the transcript and a still-parked prompt confirmed as sent. | **Fixed** — chrome is now pi's own chrome: an all-dash border (`_pi_dash_row`, shared with the border search) or a bordered spinner row (pi's Loader frames). Spec REQ-4 (second scenario). |
| 4 | Worth exploring | The pre-typing warning claimed a confirmation could not be told apart from the copy on screen, then the helper confirmed on exactly that ambiguity. | **Partly fixed** — the warning is now accurate ("may be satisfied by that copy"). The proposed alternative (confirm before the first Enter when the line is already in the transcript) was **rejected**: it re-introduces the very rule that stranded the prompt — a misclassified parked line would be reported as sent without any Enter. |
| 5 | Speculative | `_PI_COMP_GAP_LINES` read as "blank lines tolerated" but scans rows above the border. | **Fixed** — renamed `_PI_COMP_SCAN_LINES`, docstring states "at most `_PI_COMP_SCAN_LINES-1` blank rows". |
| 6 | Speculative | "Box-drawing row" implemented twice with different semantics. | **Fixed** — one `_pi_dash_row` predicate, `_pi_chrome_row` layered on it. |
| 7 | Speculative | The `_pi_*` region globals were only ever set by a parse; a stray predicate call under `set -u` aborts the caller. | **Fixed** — initialised at source time. |
| 8 | Speculative | Magic numbers beside parameterised ones. | **Fixed** — `_PI_TYPE_ATTEMPTS`, `_PI_VISIBILITY_TRIES`, `_PI_TYPE_SETTLE`, `_PI_VANISH_RECHECK`. |
| 9 | Speculative | The evidence rule silently assumes pi echoes the user turn verbatim. | **Fixed** — named on `_pi_submission_evidence`. |
| 10 | Speculative | `${L[@]}` under `set -u` needs bash ≥ 4.4. | Not applicable — bash on every supported platform here is newer. |
| 11 | Coverage gaps | No fixture for a dashed parked line; no test for a pane that only later resolves its layout. | **Fixed** — both now covered (`t_send_req4_dashed_parked_line_stays_in_the_composer`, `t_send_req7_incompletely_drawn_pi_pane_never_confirmed`), each RED against the pre-audit helper. |

## Accepted residuals

- **Evidence relies on the renderer's echo** (finding 9): a renderer that
  folds or truncates the submitted turn would turn a submitted line into
  "vanished" and re-type it. Documented, not defended against — there is no
  second observable signal.
- **`_pi_visible` is still time-bounded**: a pane that renders the line more
  than `_PI_VISIBILITY_TRIES × _PI_TYPE_SETTLE` after `send-keys` gets the
  last-resort Enter anyway, which is the safe direction.

## Verification

Every new test was run against the pre-audit helper (`SUB_COMMON_UNDER_TEST`
pointed at the committed version) and fails there for the right reason;
against the fixed helper all pass.

```
tests/sub-common.test.sh   25 tests, all passed
tests/sub-report.test.sh   all passed   (fake pane + structured captures)
tests/sub-retire.test.sh   all passed
tests/free-limit-fallback.test.sh, tests/task-levels.test.sh,
tests/spawn-base-fallback.test.sh, tests/helpers-base-fallback.test.sh,
tests/lavish-wake.test.sh, tests/worktree-setup.test.sh,
tests/install.test.sh, tests/skills-sync.test.sh,
tests/rename-*.test.sh, tests/retire-cost-log.test.sh,
tests/conversation-log.test.sh (49 assertions)   all passed
tests/test-start-main.sh  41 passed, 0 failed
tests/test-mu.sh          all passed
shellcheck scripts/_sub-common.sh scripts/sub-send.sh scripts/sub-report.sh
          tests/sub-common.test.sh            clean
```