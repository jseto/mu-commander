Feature: Wake a child when Lavish feedback is queued
  Children open Lavish Editor review artifacts (`lavish-axi <file>`) and go
  idle between review rounds. When the user clicks "Send to agent" while no
  poll listener is active, the feedback is queued on the Lavish server
  (`pending_prompts` in its state file) and nothing wakes the child, so the
  round stalls until someone manually instructs the child to poll.
  `sub-spawn.sh` therefore arms one watcher per child
  (`scripts/sub-lavish-watch.sh`) in a `lavish-watch` window of the child's
  tmux session. The watcher never runs `lavish-axi poll` and never consumes
  feedback: it scans the Lavish state file for sessions whose artifact lives
  under the child's leased worktree and whose queued-prompt count is
  positive, then wakes the child through the shared verified tmux send
  naming the artifact(s). The child drains the queue itself with its normal
  `lavish-axi poll` flow, so an undelivered wake cannot lose feedback — the
  prompts stay queued until the child consumes them. Wakes are deduplicated
  per queued batch, failed sends are retried, and the watcher exits when the
  child's tmux session goes away (which is also how retirement stops it).

  Scenario: Queued feedback for the child's artifact wakes the child [REQ-1]
    Given a child with a leased worktree and a running tmux session
    And a Lavish state file whose open session points at an artifact under
      that worktree with 2 queued prompts
    When the watcher scans the state
    Then it sends the child a verified wake naming the artifact and the
      queued-prompt count
    And the wake instructs the child to drain the queue with
      "lavish-axi poll"

  Scenario: The watcher never polls or consumes feedback [REQ-2]
    Given a Lavish state file with queued prompts for the child's artifact
    When the watcher wakes the child
    Then it runs no "lavish-axi" command
    And the queued-prompt count in the state file is unchanged

  Scenario: Sessions outside the child's worktree are ignored [REQ-3]
    Given a Lavish session with queued prompts whose artifact lives outside
      the child's worktree
    When the watcher scans the state
    Then no wake is sent to the child

  Scenario: Ended sessions are ignored [REQ-4]
    Given a Lavish session under the child's worktree with queued prompts
      and status "ended"
    When the watcher scans the state
    Then no wake is sent to the child

  Scenario: Stale sessions predating the watcher are ignored [REQ-5]
    Given a Lavish session under the child's worktree with queued prompts
      whose last update predates the watcher's start by more than the
      start margin
    When the watcher scans the state
    Then no wake is sent to the child

  Scenario: No queued feedback means no wake [REQ-6]
    Given a Lavish session under the child's worktree with no queued prompts
    When the watcher scans the state
    Then no wake is sent to the child

  Scenario: An unchanged queued batch is woken once [REQ-7]
    Given queued prompts for the child's artifact
    When the watcher scans the state repeatedly before the child drains them
    And one scan meets a transiently unreadable state file
    Then it wakes the child once and does not repeat the wake

  Scenario: Additional feedback wakes the child again [REQ-8]
    Given the watcher has already woken the child for a queued batch
    And another prompt is queued for the same artifact
    When the watcher scans the state again
    Then it wakes the child again with the updated queued-prompt count

  Scenario: A pane not running pi is never woken [REQ-9]
    Given queued prompts for the child's artifact
    And the child's pane is not running pi
    When the watcher scans the state
    Then no keys are sent to the pane
    And it reports that the pane is not running pi

  Scenario: An unconfirmed wake is retried, never claimed delivered [REQ-10]
    Given queued prompts for the child's artifact
    And a pane that accepts typed text but never confirms the send
    When the watcher scans the state
    Then it reports the wake as unconfirmed
    And it retries the wake on a later scan
    And it never records the batch as delivered

  Scenario: The watcher stops with the child session [REQ-11]
    Given the child's tmux session has gone away
    When the watcher scans the state
    Then it exits 0 without sending keys

  Scenario: Every spawn arms the child's watcher [REQ-12]
    Given sub-spawn spawns a child
    Then the child's tmux session gains a "lavish-watch" window running
      "scripts/sub-lavish-watch.sh" for that task
    And SUB_SPAWN_NO_WATCH=1 skips the watcher window

  Scenario: A watcher that cannot start does not fail the spawn [REQ-13]
    Given a tmux that refuses to create the watcher window
    When sub-spawn spawns a child
    Then the spawn still succeeds and reports the child
    And the spawn warns that the watcher window could not be created

  Scenario: Touched scripts stay shellcheck-clean [REQ-14]
    Given shellcheck is available
    When scripts/sub-lavish-watch.sh and scripts/sub-spawn.sh are checked
      with shellcheck and bash -n
    Then both report no findings
