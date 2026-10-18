Feature: One watcher per child for every watching service

  A live child needs three watching services: the Lavish wake-up (queued
  review feedback wakes the child), the PR action watch (merged / closed /
  review events reach the orchestrator), and the stall detector (a
  free-provider failure visible in the child's pane becomes an event
  instead of sitting invisible for hours). Each service used to run in its
  own tmux window; `sub-spawn.sh` now arms exactly one watcher window per
  child, running `scripts/sub-watch.sh`, and that one process runs the three
  services in one loop. The watcher is per child: it is armed at spawn and
  dies with the child's tmux session (retirement kills the session), never a
  global daemon. Every service keeps its guarantees: the Lavish wake goes
  through the verified send and never runs `lavish-axi poll`; the PR service
  only reads GitHub and never types into the child's pane; the stall service
  is notify-only — the never-speculative `sub-fallback.sh` still performs
  the model switch, and only when the orchestrator runs it.

  Scenario: Every spawn arms one watcher window running the unified watcher [REQ-1]
    Given sub-spawn spawns a child
    Then the child's tmux session gains exactly one watcher window named
      "watch" running "scripts/sub-watch.sh" for the task, root, and branch
    And no "lavish-watch" or "pr-watch" window is created
    And the spawn handles report the watch state

  Scenario: The three services run in one watcher process [REQ-2]
    Given a child with queued Lavish feedback for its artifact
    And an unseen review on the child's open PR
    And a free-provider failure visible in the child's pane
    When the watcher scans
    Then it wakes the child for the Lavish feedback through the verified send
    And it sends the orchestrator the review notice for the PR
    And it sends the orchestrator the stall notice for the pane failure
    And all three actions came from the one watcher process

  Scenario: The service selection restricts the watcher [REQ-3]
    Given a child with queued Lavish feedback, an unseen review, and a
      free-provider failure visible in its pane
    When the watcher runs with SUB_WATCH_SERVICES=pr
    Then it sends the review notice
    And it does not wake the child for the Lavish feedback
    And it does not send a stall notice

  Scenario: An unknown service name warns and is ignored [REQ-4]
    Given a watcher configured with SUB_WATCH_SERVICES=lavish,bogus
    And a child with queued Lavish feedback for its artifact
    When the watcher scans
    Then it warns that "bogus" is not a known watch service
    And it still wakes the child for the Lavish feedback

  Scenario: An empty service selection exits without watching [REQ-5]
    Given a watcher configured with an empty SUB_WATCH_SERVICES
    When the watcher starts
    Then it reports that no watch service is selected
    And it exits 0 without scanning

  Scenario: A service that reaches its tick bound stops without stopping the others [REQ-6]
    Given a child with an open PR carrying a submitted review
    And the Lavish service is bounded to one scan
    When the watcher scans repeatedly
    Then the Lavish service performs one scan and stops
    And the PR service keeps scanning and notifies the review

  Scenario: The watcher stops when the child session goes away [REQ-7]
    Given the child's tmux session has gone away
    When the watcher starts
    Then it reports that the child session is not running
    And it exits 0 without scanning any service

  Scenario: The watcher stops when the child's lease disappears [REQ-8]
    Given the child's worktree lease has been returned
    And the child's tmux session is still running
    When the watcher starts
    Then it reports that no worktree lease is held for the task
    And it exits 0 without scanning any service

  Scenario: An unreadable lease warns and the watcher keeps watching [REQ-9]
    Given a child with an open PR carrying a submitted review
    And a treehouse status that cannot be read
    When the watcher scans
    Then it warns once that the treehouse status could not be read
    And it keeps watching and notifies the review once the read recovers

  Scenario: The Lavish wake keeps its verified-send guarantees [REQ-10]
    Given a child with queued Lavish feedback for its artifact
    When the watcher scans
    Then it wakes the child through the verified send, naming the artifact
      and the queued-prompt count
    And the wake instructs the child to drain the queue with
      "lavish-axi poll"
    And it runs no "lavish-axi" command and leaves the queued prompts
      untouched

  Scenario: The PR service keeps its read-only guarantee [REQ-11]
    Given a child with an open PR carrying a submitted review
    When the watcher scans and notifies
    Then every gh invocation is a read-only query for the child's branch PR
    And the only keys sent go to the orchestrator session as the notice
    And no keys are sent to the child's pane

  Scenario: A confirmed terminal notice stops only the PR service [REQ-12]
    Given a child whose PR is MERGED and whose Lavish service is still active
    When the watcher scans and the merged notice is delivered
    Then the PR service stops
    And the Lavish service keeps watching until the child session goes away

  Scenario: A free-provider failure in the pane sends a STUCK notice [REQ-13]
    Given a child whose pane shows a free-provider failure
    When the watcher scans
    Then it sends the orchestrator a notice naming the task, the failure,
      "sub-fallback.sh", and the continue nudge
    And the notice ends with a per-attempt "[stall-watch <epoch>]" marker

  Scenario: The stall service is notify-only [REQ-14]
    Given a child whose pane shows a free-provider failure
    When the watcher scans and notifies
    Then no keys are sent to the child's pane
    And no model switch command is sent anywhere
    And no gh invocation is made for the stall notice

  Scenario: A confirmed stall notice is not repeated while the failure stays visible [REQ-15]
    Given a child whose pane shows a free-provider failure
    And the watcher has delivered the stall notice
    When the watcher scans repeatedly with the failure still visible
    Then no further stall notice is sent before the rewake interval

  Scenario: An unconfirmed stall notice is retried and never claimed [REQ-16]
    Given a child whose pane shows a free-provider failure
    And the stall notice cannot be confirmed by the verified send
    When the watcher scans repeatedly
    Then it retries the notice on later scans with a fresh
      "[stall-watch <epoch>]" marker
    And it never claims the unconfirmed notice was delivered
    And only a confirmed delivery stops the retries

  Scenario: A cleared failure lets a later failure notify again [REQ-17]
    Given a child whose pane showed a free-provider failure and was notified
    And the failure is no longer visible in the pane
    When the pane shows the failure again
    Then the watcher sends the stall notice again

  Scenario: The spawn knobs disable the watcher or only the PR service [REQ-18]
    Given sub-spawn spawns a child with SUB_SPAWN_NO_WATCH=1
    Then no watcher window is created
    And the handles report the watcher disabled
    Given sub-spawn spawns a child with SUB_SPAWN_NO_PR_WATCH=1
    Then one watcher window is created without the PR service
    And the handles report the watcher without the PR service

  Scenario: A watcher window that cannot start does not fail the spawn [REQ-19]
    Given a tmux that refuses to create the watch window
    When sub-spawn spawns a child
    Then the spawn still succeeds and reports the child
    And the spawn warns that the watch window could not be created

  Scenario: Touched scripts stay shellcheck-clean [REQ-20]
    Given shellcheck is available
    When scripts/sub-watch.sh, scripts/_sub-watch.sh,
      scripts/sub-lavish-watch.sh, scripts/sub-pr-watch.sh, and
      scripts/sub-spawn.sh are checked with shellcheck and bash -n
    Then all report no findings

  Scenario: A reply-only COMMENTED review is never routed back [REQ-21]
    Given a child whose PR carries a submitted COMMENTED review and the
      child's own reply recorded as a reply-only COMMENTED review
    When the watcher scans
    Then only the submitted review is notified
    And the reply-only review is recorded handled and never notified

  Scenario: An unreadable review defers only that review [REQ-22]
    Given a child whose PR carries a COMMENTED review whose review-comment
      read fails
    And the same PR carries a later review that needs no attribution read
    When the watcher scans
    Then the later review is still notified
    And the unreadable review is retried on a later scan
    And no notice is sent from the unreadable review's data
