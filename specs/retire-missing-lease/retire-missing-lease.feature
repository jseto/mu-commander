Feature: Safely retire a child after its treehouse lease disappears
  A vanished lease leaves sub-retire without a trustworthy worktree path or
  branch, but the child's tmux session and task scratch data may still exist.
  Retirement must fail closed by default and offer an explicit forced cleanup
  that never pretends to return an unleased worktree.

  Scenario: Refuse missing-lease retirement without changing child state [REQ-1]
    Given treehouse status is valid and has no lease for the task
    And the child's tmux session and task scratch files still exist
    When "sub-retire.sh <task>" is run without "--force"
    Then the script exits with a failure status
    And explains that "--force" is required after confirming the work is safe
    And leaves the tmux session and scratch files untouched

  Scenario: Force-retire the child without returning an unleased worktree [REQ-2]
    Given treehouse status is valid and has no lease for the task
    And the child's tmux session exists
    When "sub-retire.sh <task> --force" is run
    Then the script exits successfully and stops the child's tmux session
    And it does not call "treehouse return"
    And it reports that worktree and branch cleanup were skipped

  Scenario: Preserve task files during forced missing-lease retirement when requested [REQ-3]
    Given treehouse status is valid and has no lease for the task
    And task scratch files exist
    When "sub-retire.sh <task> --force --keep-files" is run
    Then the script exits successfully
    And the task scratch files remain

  Scenario: Refuse forced retirement when treehouse status cannot be trusted [REQ-4]
    Given treehouse status fails or returns invalid JSON
    And the child's tmux session exists
    When "sub-retire.sh <task> --force" is run
    Then the script exits with a failure status
    And leaves the tmux session untouched
