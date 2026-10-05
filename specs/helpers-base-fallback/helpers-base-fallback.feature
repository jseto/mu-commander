Feature: Comparison helpers survive a missing DEV_BRANCH
  scripts/sub-changes.sh, scripts/sub-land.sh and scripts/sub-retire.sh compare
  a task worktree against a base branch. The configured `$DEV_BRANCH`
  ("development") is resolved through the shared `resolve_base_ref <repo>`:
  its `origin/<dev>` ref first, else the local branch, else the repository's
  default branch advertised by `origin/HEAD` (commonly `origin/master`). A
  repository that deleted "development" must keep these helpers usable instead
  of dying on an unknown revision; an existing `$DEV_BRANCH` must behave as
  before; and the unpublished-work refusal in sub-retire must be correct by
  construction — a base ref that cannot be resolved or whose range cannot be
  computed must abort loudly, never read as "0 unlanded commits", regardless
  of `pipefail`.

  Scenario: sub-changes falls back to the origin/HEAD default [REQ-1]
    Given a task worktree with a commit not on "master" while DEV_BRANCH
      "development" is missing everywhere and origin/HEAD names "master"
    When "sub-changes.sh <task>" inspects the worktree
    Then it exits successfully and lists the commit not on "master"
    And its commits and diff-stat labels name "master"

  Scenario: sub-land falls back to the origin/HEAD default [REQ-2]
    Given a task worktree with a commit not on "master" while DEV_BRANCH
      "development" is missing everywhere and origin/HEAD names "master"
    When "sub-land.sh <task>" prints what would be lost
    Then it exits successfully and reports 1 commit not on "master"
    And its publish instructions open a pull request against "master"

  Scenario: sub-retire resolves the base instead of dying [REQ-3]
    Given a task whose branch is pushed to origin and whose worktree is based
      on "master" while DEV_BRANCH "development" is missing everywhere
    When "sub-retire.sh <task>" retires the task without --force
    Then it exits successfully and the worktree is returned

  Scenario: The fallback is reported as a warning [REQ-4]
    Given a task worktree while DEV_BRANCH "development" is missing everywhere
      and origin/HEAD names "master"
    When a comparison helper resolves its base
    Then it warns on stderr that it fell back to the default branch "master"

  Scenario: An existing DEV_BRANCH keeps the helpers unchanged [REQ-5]
    Given a task worktree with origin/development present and DEV_BRANCH
      "development"
    When sub-changes, sub-land and sub-retire inspect the task
    Then their base labels name "development"
    And their unlanded count and pull-request base are "development"-based

  Scenario: The unpublished-work refusal never reads a broken base as zero [REQ-6]
    Given a base ref whose commit range cannot be computed
    And pipefail is disabled
    When the shared unlanded count is asked for that base
    Then it reports failure instead of echoing 0
    And sub-retire refuses the retirement without returning the worktree

  Scenario: sub-retire compares and cleans up against the resolved base [REQ-7]
    Given a task branch merged into the resolved base "master" while
      DEV_BRANCH "development" is missing everywhere
    When "sub-retire.sh <task>" retires the task
    Then the branch merge-base checks use "master"
    And its cleanup messages name "master" as the base

  Scenario: Touched scripts stay shellcheck-clean [REQ-8]
    Given shellcheck is available
    When scripts/_sub-common.sh, scripts/sub-changes.sh, scripts/sub-land.sh
      and scripts/sub-retire.sh are checked with shellcheck and bash -n
    Then all report no findings
