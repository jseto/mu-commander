Feature: Retirement cost logging in the conversation log
  Every successful run of "sub-retire.sh <task>" must append an entry to the
  conversation log recording that retirement, including the total cost of the
  child's pi session. The cost is read from the retiring child's own session
  records, and the whole step is best-effort: a missing cost source or a
  failing log only warns and never changes the retirement's exit status.

  Scenario: Log a successful retirement with its session cost [REQ-1]
    Given a task whose pi session records contain a known cost
    When "sub-retire.sh <task>" retires the task successfully
    Then the conversation log gains an "operation" entry
    And the entry names the task and states that it was retired
    And the entry contains the total session cost as a dollar amount

  Scenario: Total only the retiring child's own session records [REQ-2]
    Given the task's pi session records contain costs summing to a known value
    And another task's session records contain a different cost
    When "sub-retire.sh <task>" retires the task successfully
    Then the logged cost is the sum of this task's records only

  Scenario: Capture the cost before the session records are removed [REQ-3]
    Given a task whose pi session records contain a known cost
    When "sub-retire.sh <task>" retires the task successfully
    Then the task's session records are removed with its scratch files
    And the logged entry still contains the known cost

  Scenario: Warn when the session cost source is missing [REQ-4]
    Given a task without pi session records
    When "sub-retire.sh <task>" retires the task successfully
    Then the script exits successfully
    And stderr reports that the session cost could not be read
    And the log entry records the cost as "unknown"

  Scenario: Never fail retirement when the conversation log cannot be written [REQ-5]
    Given the conversation log directory cannot be written
    When "sub-retire.sh <task>" retires the task successfully
    Then the script exits successfully
    And the failure is reported as a warning
    And the retirement itself still completes

  Scenario: Leave the conversation log untouched when retirement refuses [REQ-6]
    Given a task whose retirement is refused for uncommitted work
    When "sub-retire.sh <task>" is run
    Then the script exits with a failure status
    And the conversation log gains no entry


  Scenario: Pass shellcheck on sub-retire.sh [REQ-8]
    When "shellcheck scripts/sub-retire.sh" is run
    Then it reports no findings
