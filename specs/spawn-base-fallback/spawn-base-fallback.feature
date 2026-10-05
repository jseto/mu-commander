Feature: Spawn base-branch fallback to the default branch
  The spawn path cuts each child's task branch from a base branch: the
  configured `$DEV_BRANCH` resolved as `origin/<dev>` when that remote branch
  exists, else the local `<dev>` branch. When neither exists — e.g. the
  repository deleted "development" — the spawn must fall back to the
  repository's default branch as advertised by `origin/HEAD` (commonly
  `master`) instead of failing. An explicitly configured `$DEV_BRANCH` that
  does exist keeps priority, a fetch failure never triggers the fallback
  (only a genuinely missing branch does), the chosen base is reported so the
  operator can see what a task was based on, and the child's pull request
  targets that same base.

  Scenario: Missing DEV_BRANCH falls back to the origin/HEAD default [REQ-1]
    Given a repository whose origin has "master" with origin/HEAD pointing
      at it and no "development" branch anywhere
    And DEV_BRANCH is "development"
    When resolve_base_ref resolves the base for that repository
    Then it echoes "origin/master"

  Scenario: An existing origin DEV_BRANCH keeps priority [REQ-2]
    Given a repository whose origin has "develop" with origin/HEAD pointing
      at "master"
    And DEV_BRANCH is "develop"
    When resolve_base_ref resolves the base for that repository
    Then it echoes "origin/develop"

  Scenario: An existing local-only DEV_BRANCH keeps priority [REQ-3]
    Given a repository with a local "develop" branch but no origin/develop
    And DEV_BRANCH is "develop"
    When resolve_base_ref resolves the base for that repository
    Then it echoes "develop"

  Scenario: No usable base branch fails loudly [REQ-4]
    Given a repository with no "development" branch and no origin/HEAD
    And DEV_BRANCH is "development"
    When resolve_base_ref resolves the base for that repository
    Then it exits non-zero with an error naming the missing base branch
    And the repository default branch is not silently guessed

  Scenario: The spawn reports and warns about the chosen base [REQ-5]
    Given a repository whose origin has "master" and no "development" branch
    When sub-spawn spawns a task with DEV_BRANCH "development"
    Then its handles report "origin/master" as the base
    And it warns on stderr that it fell back to the default branch

  Scenario: The child's pull request targets the chosen base [REQ-6]
    Given a repository whose origin has "master" and no "development" branch
    When sub-spawn spawns a task with DEV_BRANCH "development"
    Then the child's kickoff instructs a pull request against "master"

  Scenario: A fetch failure never triggers the fallback [REQ-7]
    Given a repository whose origin advertises "develop" but is unreachable
    And DEV_BRANCH is "develop"
    When sub-spawn spawns a task with DEV_BRANCH "develop"
    Then the base is "origin/develop"
    And it does not warn about falling back

  Scenario: Touched scripts stay shellcheck-clean [REQ-8]
    Given shellcheck is available
    When scripts/_sub-common.sh and scripts/sub-spawn.sh are checked with
      shellcheck and bash -n
    Then both report no findings
