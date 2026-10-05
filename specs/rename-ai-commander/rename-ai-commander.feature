Feature: Rename the project identifier to mu-commander
  The project was first renamed from `ai-orchestrator` to `ai-commander`
  (PR #10, this spec's original task); tracked files, GitHub repository and
  machine state must now all read `mu-commander`. The old identifiers
  (`ai-orchestrator`, `ai-commander`) may appear only in the rename's own
  specification and test documents, which must name them to define what is
  being renamed. Generic prose uses of the English words
  "orchestrator"/"orchestration" describe a role, not the project, and stay
  untouched.
  [REQ-2] (the former `pi.sh` default session) was dropped: development
  removed `pi.sh` in favour of the `mu` launcher, so there is no session
  default left to rename and its coverage (`tests/test-pi-sh.sh`) was removed
  with it.

  Scenario: No tracked file contains an earlier project identifier [REQ-1]
    Given the repository checkout on branch task/rename-mu-commander
    When the tracked files are searched for "ai-orchestrator" or "ai-commander"
    Then no tracked file matches
    And the rename's own specification and test documents
      (specs/rename-ai-commander/, specs/rename-mu-commander/,
      tests/rename-project.test.sh, tests/rename-mu-commander.test.sh) are
      exempt, since they must name the old identifiers to define the rename
    And the derived identifiers reference "mu-commander" instead
      (AGENTS.md hook path and SCRIPTS path, scripts/worktree-setup.sh
      managed shellcheck path, and the specs documents under specs/)

  Scenario: The managed shellcheck directory uses the new project name [REQ-3]
    Given a fresh environment with no shellcheck at the managed path
    When "worktree-setup.sh" runs
    Then the shellcheck of the pinned version is installed under
      "$XDG_DATA_HOME/mu-commander/shellcheck"
    And the worktree-setup tests resolve the managed path under
      "$HOME/.local/share/mu-commander/shellcheck"

  Scenario: On this machine the provisioned shellcheck lives at the new path [REQ-4]
    Until the folder rename and the machine-level follow-ups, this scenario
    is skipped rather than failed.

    Given the checkout folder has been renamed to mu-commander
    When the managed data directory is inspected
    Then "~/.local/share/mu-commander/shellcheck" exists
    And "~/.local/share/ai-orchestrator" and "~/.local/share/ai-commander"
      do not exist
    And "~/.local/bin/shellcheck" resolves through the new managed path
      and reports the pinned version
    And running "worktree-setup.sh" performs no re-download

  Scenario: The treehouse post_create hook points at the renamed checkout [REQ-5]
    Until the folder rename and the machine-level follow-ups, this scenario
    is skipped rather than failed.

    Given the mu-commander checkout exists on this machine
    When "~/.config/treehouse/config.toml" is read
    Then its post_create hook references
      "/home/jseto/programming-projects/mu-commander/scripts/worktree-setup.sh"
    And it does not reference "ai-orchestrator" or "ai-commander"


  Scenario: The origin remote carries the current repository name [REQ-7]
    Given the GitHub repository jseto/ai-orchestrator was renamed to
      jseto/ai-commander by PR #10
    And a follow-up task has since renamed it to jseto/mu-commander
    When the git remote "origin" of this checkout is inspected
    Then it points at "https://github.com/jseto/mu-commander.git"
    And it does not reference "ai-orchestrator" or "ai-commander"
