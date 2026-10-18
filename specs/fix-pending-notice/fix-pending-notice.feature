Feature: Confirm a notice pi queues behind a running turn (scripts/_sub-common.sh)

  `tmux_send_line` proves a send from pi's own rendering: the line must leave
  the composer and appear in the transcript. When the orchestrator is
  **mid-turn**, pi does not put a submitted line into the transcript: it
  queues it as a steering message and renders it in its pending-message
  display as ONE line truncated to the pane width (`TruncatedText(text, 1, 0)`):

      Steering: <message, cut off at the pane width>…

  The probe the helper looks for is the line's *tail* (the last
  `_PI_PROBE_TAIL` non-whitespace characters — for a PR notice, the closing
  `[pr-watch <epoch>]` marker), and the truncation cuts exactly that tail off.
  The submitted line therefore looks "vanished": the helper re-types it and
  fails. `sub-pr-watch.sh` reads the failure as "unconfirmed", retries on the
  next scan with a fresh epoch, and every retry appends another copy of the
  same notice to the orchestrator's input queue — unbounded duplicates
  (observed 2026-10-18 on tasks `riak-261-spot-description` /
  `riak-262-route-list-names`, PRs #263/#264).

  A line shown in pi's pending-message display has left the composer and WILL
  be injected as a turn, so it is delivery — the *pending* state of a send.
  Recognizing it keeps every existing guarantee: a copy still parked in the
  composer is never evidence, only a queued copy THIS send added confirms it
  (a truncated head alone is not an identity), a pending line is never read as
  transcript content, an unconfirmed notice is still retried, and a queued
  notice is recorded as delivered exactly once, so no retry duplicates it.

  Scenario: A message queued behind a running turn is confirmed delivered [REQ-1]
    Given a tmux pane showing pi's TUI with the typed line in the composer
    When tmux_send_line sends Enter while the pane is mid-turn, so pi queues
      the line as a steering message whose pending line shows only its head
    Then the send is confirmed from that pending line
      And the helper returns success
      And the line is not typed into the pane a second time

  Scenario: A copy still parked in the composer is never confirmed from the pending display [REQ-2]
    Given a pending line that shows the typed message's head
    And the typed line still sits in the composer
    When tmux_send_line verifies the send
    Then the pending display does not confirm the send
      And Enter is retried
      And the helper returns failure without claiming the send

  Scenario: Another message's pending line is not evidence [REQ-3]
    Given the pending display holds a queued message that is not the typed line
    And the typed line vanishes from the pane without being queued or reaching
      the transcript
    When tmux_send_line verifies the send
    Then the pending display does not confirm the send
      And the queued message's line is never read as transcript content
      And the helper returns failure without claiming the send

  Scenario: sub-report.sh reports a queued notice as delivered [REQ-4]
    Given the main session is mid-turn and queues a submitted notice as a
      steering message
    When sub-report.sh delivers a notice
    Then it exits zero printing "notice delivered to <target>"
      And the notice appears exactly once in the main session's pending display

  Scenario: A review notice queued behind a busy orchestrator is delivered once [REQ-5]
    Given a live child whose PR has a submitted review
    And the orchestrator is mid-turn, so each submitted notice is queued as a
      steering message instead of reaching the transcript
    When the watcher scans and notifies, then scans again
    Then exactly one review notice is queued
      And the review is recorded as notified
      And the notice is never retyped on the later scans

  Scenario: A merged-PR notice queued behind a busy orchestrator is delivered exactly once and stops the watcher [REQ-6]
    Given a live child whose PR is MERGED
    And the orchestrator is mid-turn, so the submitted notice is queued as a
      steering message instead of reaching the transcript
    When the watcher scans repeatedly
    Then exactly one merged notice is queued
      And the watcher exits 0 after that confirmed delivery
      And no second copy reaches the orchestrator

  Scenario: The touched scripts stay shellcheck-clean [REQ-7]
    Given shellcheck is available
    When the scripts touched by this change are checked with shellcheck and
      bash -n
    Then no findings are reported
      And the test suites that cover this change are checked the same way

  Scenario: An older same-head queued copy does not confirm a vanished send [REQ-8]
    Given the pending display already holds a queued message whose visible head
      is identical to the typed line's head (the same task and PR, a different
      event)
    And the typed line vanishes from the pane without this send queueing it
    When tmux_send_line verifies the send
    Then only the queued copy that this send added may confirm the send
      And the pre-existing queued copy does not
      And the helper returns failure without claiming the send
