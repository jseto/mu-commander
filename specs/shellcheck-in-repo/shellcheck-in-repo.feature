Feature: shellcheck as a declared, repo-provisioned dependency
  shellcheck is needed by this repository's tests but was installed ad-hoc to
  ~/bin by a child session, which is invisible to other machines and
  worktrees. scripts/worktree-setup.sh (the treehouse post_create hook) must
  provision a pinned shellcheck so that every environment created from the
  repo gets it automatically, idempotently, and without ever clobbering a
  shellcheck the user installed themselves.

  Scenario: Provision the pinned shellcheck when none is installed [REQ-1]
    Given a fresh environment with no shellcheck at the managed path
    When "worktree-setup.sh" runs
    Then a shellcheck of the pinned version is installed at the managed path
    And "command -v shellcheck" resolves to that managed path
    And the setup reports the provisioning

  Scenario: Skip provisioning when a shellcheck of the pinned version is already at the managed path [REQ-2]
    Given the managed path already holds a shellcheck of the pinned version
    When "worktree-setup.sh" runs
    Then no download is performed
    And the setup reports that it is skipping

  Scenario: Warn instead of overwriting a shellcheck of a different version at the managed path [REQ-3]
    Given the managed path holds a shellcheck of a version other than the pin that setup did not provision
    When "worktree-setup.sh" runs
    Then the existing shellcheck is left byte-for-byte unchanged
    And no download is performed
    And the setup reports a warning about the differing version
    And the setup still exits successfully

  Scenario: Refresh a setup-provisioned shellcheck when the pinned version changes [REQ-4]
    Given the managed path is a setup-provisioned link to a shellcheck of an older version
    When "worktree-setup.sh" runs
    Then a shellcheck of the pinned version is installed
    And the managed path resolves to the pinned version

  Scenario: Report a failed shellcheck provisioning without aborting the remaining setup steps [REQ-5]
    Given the shellcheck download fails
    When "worktree-setup.sh" runs
    Then the failure is reported as a "[worktree-setup] FAILED" line
    And the setup still runs its remaining steps
    And the setup exits with a non-zero status, which the treehouse hook tolerates

  Scenario: Resolve the repo-provided shellcheck on a normal worktree PATH [REQ-6]
    Given a stray shellcheck sits later on the PATH than the managed path
    When "worktree-setup.sh" runs
    Then "command -v shellcheck" resolves to the managed path
    And the resolved shellcheck reports the pinned version

  Scenario: Leave a shellcheck outside the managed path untouched [REQ-7]
    Given a stray shellcheck exists in a directory outside the managed path
    When "worktree-setup.sh" runs
    Then the stray shellcheck is left byte-for-byte unchanged
    And the managed path still receives the pinned shellcheck

