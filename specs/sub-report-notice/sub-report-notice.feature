Feature: Reliable child-to-main push notices (sub-report.sh)
  scripts/sub-report.sh injects a "[task] message" notice into the main
  orchestrator session's input. Delivery must be verified through the shared
  send helper: the script either confirms the notice was submitted or fails
  loudly — a child must never report a DONE/BLOCKED notice as pushed while it
  is still sitting in the composer, and an impossible delivery must point the
  caller back at the durable report file instead of a bare warning with exit 0.

  Scenario: Deliver a verified notice to a running main session [REQ-1]
    Given a running tmux session "main-orch" whose pane accepts input
    And the environment points MAIN_SESSION at "main-orch"
    When a child runs "sub-report.sh demo-task" with the message
      'DONE: "quoted" brackets [x] unicode ✓ -> reports/demo.md'
    Then the pane receives the text
      '[demo-task] DONE: "quoted" brackets [x] unicode ✓ -> reports/demo.md'
    And the script exits successfully reporting the delivery

  Scenario: Fail loudly when the main session is not running [REQ-2]
    Given no tmux session matches MAIN_SESSION
    When a child runs "sub-report.sh demo-task" with any message
    Then the script prints an ERROR naming the missing session
    And the ERROR carries a hint pointing at "tmp/pi-sub/reports/demo-task.md"
    And the script exits non-zero

  Scenario: Fail loudly when tmux is unavailable [REQ-3]
    Given no tmux executable is on PATH
    When a child runs "sub-report.sh demo-task" with any message
    Then the script prints an ERROR about the missing tmux command
    And the ERROR carries a hint pointing at "tmp/pi-sub/reports/demo-task.md"
    And the script exits non-zero

  Scenario: Re-type the notice when the text never appears in the pane [REQ-4]
    Given a running main session whose pane never shows the sent text
    When a child runs "sub-report.sh demo-task" with any message
    Then the notice text is sent to the pane more than once

  Scenario: Retry the submission while the pane swallows Enter [REQ-5]
    Given a running main session that echoes the typed text but never acts on Enter
    When a child runs "sub-report.sh demo-task" with any message
    Then Enter is sent to the pane more than once before giving up

  Scenario: Fail loudly when the notice still cannot be confirmed [REQ-6]
    Given a running main session that echoes the typed text but never acts on Enter
    When a child runs "sub-report.sh demo-task" with any message
    Then the script prints an ERROR saying the notice was not delivered
    And the ERROR carries a hint pointing at "tmp/pi-sub/reports/demo-task.md"
    And the script does not print a delivery-success line
    And the script exits non-zero

  Scenario: Keep delivering sub-send instructions through the shared helper [REQ-7]
    Given a running tmux session "pi-demo-task" whose pane accepts input
    When a child runs "sub-send.sh demo-task" with a follow-up instruction
    Then the pane receives the instruction text
    And the script exits successfully reporting the instruction


  Scenario: Keep the touched shell scripts shellcheck-clean [REQ-9]
    Given shellcheck is available
    When the scripts touched by this change are checked
    Then shellcheck reports no findings
