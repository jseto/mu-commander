# approved: 2026-11-07 (gate answer; the user reported the false-success spawn while this child was spawned)
Feature: Verify the child pi actually booted before reporting a spawn (sub-spawn)

  The launch confirmation proves only that the shell ran the launch line: its
  evidence is the pane changing after the Enter
  (`specs/fix-launch-confirm`). A pi that dies immediately after the shell
  runs the line — the model it was asked for does not exist, for instance —
  satisfies that evidence the same way a healthy boot does, so
  `sub-spawn.sh` printed "Subsession spawned" and the handles for a child
  that was already gone. The orchestrator then had no child to drive and no
  failure to react to: only a later `sub-status.sh` poll showed the dead pane.

  A spawn must therefore verify, after the boot wait, that the child pane is
  actually running pi, and report a failure — with the pane's own output as
  the reason — instead of handles when it is not. The lease, the session, and
  the agent directory are released exactly as for any other failed spawn.

  Scenario: A child that exited during startup fails the spawn [REQ-43]
    Given the shell runs the launch line and pi exits during startup
    When sub-spawn verifies the child after the boot wait
    Then it exits non-zero with an ERROR naming the child as not running
    And it prints no task handles
    And the leased worktree is returned and the tmux session removed

  Scenario: A running child is reported normally [REQ-44]
    Given pi keeps the child pane after the launch line runs
    When sub-spawn verifies the child after the boot wait
    Then it exits zero and prints the task handles as before

  Scenario: A child that needs longer than the boot wait still succeeds [REQ-45]
    Given the child pane is still a shell at the first verification check
    And it becomes pi within the verification window
    When sub-spawn verifies the child
    Then the spawn succeeds and prints the handles

  Scenario: An unreadable pane state never fails a healthy spawn [REQ-46]
    Given tmux cannot report the child pane's current command
    When sub-spawn verifies the child
    Then the spawn is not declared failed
    And the handles are printed as before

  Scenario: The failure shows why pi exited [REQ-47]
    Given the child pane shows pi's own startup error line
    When sub-spawn reports the failed spawn
    Then the failure output includes the pane's last lines, error line included

  Scenario: Touched scripts and tests stay bash -n- and shellcheck-clean [REQ-49]
    Given shellcheck is available
    When scripts/_sub-common.sh, scripts/sub-spawn.sh and this change's
      test suites are checked
    Then bash -n and shellcheck report no findings
