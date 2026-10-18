Feature: Notify the orchestrator of pull-request events on a live child

  A child opens a pull request for its task branch and then goes idle, so
  GitHub-side events on that PR wait for someone to check by hand. Three
  events need the orchestrator while the child is still alive: the PR was
  merged (the orchestrator retires the child), the PR was closed without
  merging, and a human review was submitted — especially a "request
  changes" review, which must reach the child. Since the
  `unified-child-watcher` change (2026-10-19,
  [`specs/unified-child-watcher/`](file://specs/unified-child-watcher/))
  `sub-spawn.sh` arms ONE watcher per child
  ([`scripts/sub-watch.sh`](file://scripts/sub-watch.sh)) in a single
  `watch` window, and this PR service is one of its three services;
  [`scripts/sub-pr-watch.sh`](file://scripts/sub-pr-watch.sh) remains the
  single-service entry point for development and for this suite. The
  service polls the branch checked
  out in the child's leased worktree, read-only, with `gh` (no webhook and
  no external service) and pushes each event as a verified notice into the
  main orchestrator session through `sub-report.sh` — the same verified
  send every child notice uses. It never mutates GitHub (no merge, close,
  comment, review, or push) and never types into the child's pane.

  A delivered notice is one line naming the task, the PR number and URL,
  the event, and the action the orchestrator should take. The notices use
  these templates (`[<task>]` is the prefix `sub-report.sh` adds):

    PR #<n> (<url>) was MERGED - retire the child now. [pr-watch <epoch>]
    PR #<n> (<url>) was CLOSED without merging - route it to the child with sub-send.sh <task>. [pr-watch <epoch>]
    PR #<n> (<url>) got a <STATE> review from <login> - route it to the child with sub-send.sh <task>. [pr-watch <epoch>]

  `<STATE>` is the submitted review state: APPROVED, CHANGES_REQUESTED, or
  COMMENTED. Every notice ends with a per-attempt marker,
  `[pr-watch <epoch>]`, so the verified send can never be satisfied by an
  earlier copy of the same notice; a retry uses a fresh epoch.

  Notices are deduplicated per event: one notice per submitted review and
  exactly one for a terminal PR state. An unconfirmed notice is never
  recorded as delivered and is retried on a later scan. The watcher stops
  with the child (its tmux session or its worktree lease disappears) and
  after the confirmed notice for a terminal state. Timing is
  environment-driven for tests: the scan interval is `PR_WATCH_INTERVAL`,
  the failed-notice retry delay is `PR_WATCH_RETRY_SECONDS`, and
  `PR_WATCH_TICKS` bounds the scans (0 = run until stopped).

  Scenario: A merged PR sends a retire notice to the orchestrator [REQ-1]
    Given a live child with an open PR for its task branch
    When the watcher scans and the PR state is MERGED
    Then it sends the main orchestrator session a verified notice for the task
    And the notice names the PR number and URL and says the PR "was MERGED"
    And the notice instructs the orchestrator to retire the child

  Scenario: A PR closed without merging sends a notice to the orchestrator [REQ-2]
    Given a live child with an open PR for its task branch
    When the watcher scans and the PR state is CLOSED
    Then it sends the main orchestrator session a verified notice for the task
    And the notice names the PR number and URL and says the PR "was CLOSED
      without merging"
    And the notice instructs the orchestrator to route it to the child with
      "sub-send.sh"

  Scenario: A submitted review notifies the reviewer and its state [REQ-3]
    Given a live child with an open PR for its task branch
    When a review by "alice" is submitted with state APPROVED,
      CHANGES_REQUESTED, or COMMENTED
    Then it sends the main orchestrator session a verified notice for the task
    And the notice names the PR number, the URL, the reviewer "alice", and
      the submitted state
    And the notice instructs the orchestrator to route it to the child with
      "sub-send.sh"

  Scenario: A PR for another branch is never watched [REQ-4]
    Given the child's task branch is checked out in its leased worktree
    And a PR exists for a different branch
    When the watcher scans
    Then no notice is sent to the orchestrator

  Scenario: A PR that does not exist yet is picked up when it appears [REQ-5]
    Given a live child whose branch has no PR
    When the watcher scans
    Then no notice is sent and the watcher keeps watching
    When a PR for the child's branch appears with a submitted review
    Then a later scan notifies that review as usual

  Scenario: An unchanged review set is notified only once [REQ-6]
    Given a live child with an open PR carrying one submitted review
    And the watcher has notified that review
    When the watcher scans repeatedly
    Then no further notice is sent for the unchanged review set

  Scenario: A review submitted later is notified again [REQ-7]
    Given the watcher has notified a review by "alice"
    And the PR is still open
    When another review by "bob" with state "APPROVED" is submitted
    Then the watcher notifies the new review naming "bob" and "APPROVED"

  Scenario: A terminal PR state notifies once and then stops the watcher [REQ-8]
    Given a live child whose PR has reached a terminal state (MERGED or CLOSED)
    And the watcher has not yet notified every review on that PR
    When the watcher scans repeatedly
    Then only the terminal notice is sent for that PR
    And that notice is delivered exactly once
    And the watcher exits 0 after the confirmed delivery
    And no further notice is sent

  Scenario: An unconfirmed notice is retried and never claimed delivered [REQ-9]
    Given a live child with an open PR and a review to notify
    And the notice cannot be confirmed by the verified send
    When the watcher scans repeatedly
    Then it retries the notice on later scans with a fresh
      "[pr-watch <epoch>]" marker
    And it never records the review as notified
    And only a confirmed delivery records it as notified

  Scenario: A terminal notice is retried until the send is confirmed [REQ-10]
    Given a live child whose PR is MERGED
    And the merged notice cannot be confirmed by the verified send
    When the watcher scans repeatedly
    Then it retries the merged notice on later scans
    And it does not exit while the notice is unconfirmed

  Scenario: A missing or failing gh warns and retries [REQ-11]
    Given a live child whose PR state cannot be read because gh is missing
      or the read fails
    When the watcher scans
    Then it warns that the PR state could not be read
    And no notice is sent
    And it keeps watching and notifies once a later read succeeds

  Scenario: The watcher only observes and only types the notice [REQ-12]
    Given a live child with an open PR and a review to notify
    When the watcher scans and notifies
    Then every gh invocation is a read-only query for the child's branch PR
    And no keys are sent to the child's pane
    And the only keys sent go to the main orchestrator session as the notice

  Scenario: The watcher stops with the child's tmux session [REQ-13]
    Given the child's tmux session has gone away
    When the watcher scans
    Then it exits 0 without sending a notice

  Scenario: The watcher stops when the child's lease disappears [REQ-14]
    Given the child's worktree lease has been returned
    And the child's tmux session is still running
    When the watcher scans
    Then it exits 0 without sending a notice

  Scenario: Every spawn arms the child's watcher with the PR service [REQ-15]
    Given sub-spawn spawns a child
    Then the child's tmux session gains one "watch" window running
      "scripts/sub-watch.sh" with the PR service enabled
    And the spawn handles report the watch state
    And SUB_SPAWN_NO_PR_WATCH=1 arms the watcher without the PR service
    And SUB_SPAWN_NO_WATCH=1 skips the watcher window

  Scenario: A watcher window that cannot start does not fail the spawn [REQ-16]
    Given a tmux that refuses to create the watch window
    When sub-spawn spawns a child
    Then the spawn still succeeds and reports the child
    And the spawn warns that the watch window could not be created

  Scenario: Touched scripts stay shellcheck-clean [REQ-17]
    Given shellcheck is available
    When scripts/sub-pr-watch.sh and scripts/sub-spawn.sh are checked with
      shellcheck and bash -n
    Then both report no findings
