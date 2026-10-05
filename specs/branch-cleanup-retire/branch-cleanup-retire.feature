Feature: Branch cleanup on subsession retirement
  Retiring a task with scripts/sub-retire.sh must close the loop on merged
  branches: after the retirement itself succeeds, the task's local and remote
  branches are deleted when — and only when — they are safe to delete.
  Every deletion is best-effort and can never fail the retirement.

  Scenario: Delete the local task branch after a successful retirement when it is merged [REQ-1]
    Given a task whose local branch "task/<task>" is fully merged into "development"
    When "sub-retire.sh <task>" retires the task successfully
    Then the local branch "task/<task>" no longer exists
    And the script reports the local branch deletion

  Scenario: Keep the local task branch when it is not merged into the dev base [REQ-2]
    Given a task whose local branch "task/<task>" has commits not merged into "development"
    When "sub-retire.sh <task>" retires the task successfully
    Then the local branch "task/<task>" still exists
    And the script warns that the unmerged local branch was kept

  Scenario: Delete the remote task branch when its PR is merged [REQ-3]
    Given the branch "task/<task>" exists on origin
    And GitHub reports a merged pull request for "task/<task>"
    When "sub-retire.sh <task>" retires the task successfully
    Then the remote branch "origin/task/<task>" no longer exists

  Scenario: Keep the remote task branch while its PR is open [REQ-4]
    Given the branch "task/<task>" exists on origin
    And GitHub reports an open pull request for "task/<task>"
    When "sub-retire.sh <task>" retires the task successfully
    Then the remote branch "origin/task/<task>" still exists
    And the script prints a note that the remote branch was kept

  Scenario: Delete the remote task branch merged into origin/development without a PR [REQ-5]
    Given the branch "task/<task>" exists on origin
    And no pull request exists for "task/<task>"
    And "origin/task/<task>" is fully merged into "origin/development"
    When "sub-retire.sh <task>" retires the task successfully
    Then the remote branch "origin/task/<task>" no longer exists

  Scenario: Never fail retirement because of a branch deletion error [REQ-6]
    Given a task whose branch cleanup hits an error
    And the retirement itself succeeds
    When "sub-retire.sh <task>" is run
    Then the script exits successfully
    And the failure is reported as a warning or note, not an error

  Scenario: Skip branch cleanup with --no-branch-cleanup [REQ-7]
    Given a task whose local and remote branches would be deleted
    When "sub-retire.sh <task> --no-branch-cleanup" retires the task successfully
    Then the local branch "task/<task>" still exists
    And the remote branch "origin/task/<task>" still exists

  Scenario: Leave branches untouched when retirement refuses [REQ-8]
    Given a task whose retirement is refused (uncommitted or unpublished work)
    When "sub-retire.sh <task>" is run
    Then the script exits with a failure status
    And neither the local nor the remote task branch was deleted


  Scenario: Pass shellcheck on sub-retire.sh [REQ-10]
    When "shellcheck scripts/sub-retire.sh" is run
    Then it reports no findings

  Scenario: Delete head branches automatically on GitHub merge [REQ-11]
    Given the GitHub repository setting "delete_branch_on_merge" is checked
    When a pull request is merged on GitHub
    Then GitHub deletes the PR head branch automatically
