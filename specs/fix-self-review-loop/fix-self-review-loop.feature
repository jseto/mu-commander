Feature: Never route a child's own review-comment replies back to it (scripts/sub-pr-watch.sh)

  The watcher cannot tell the reviewer from the child by identity: every child
  acts under the same GitHub account as the `gh` token (`jseto`). When a child
  replies to an inline review comment, GitHub records the reply as a synthetic
  `COMMENTED` review of its own — on riak-t PR #263 the child's reply to
  comment 4307762769 became review 5564195733 with comment 4308102832
  (`in_reply_to_id` set, commit `e87beb6`, submitted 2026-10-18T18:04:27Z),
  carrying a fresh `login|state|submittedAt` signature. The watcher notifies
  the orchestrator, the orchestrator routes the child's own words back to the
  child, the child replies again, and the loop costs one child turn per round
  — forever.

  A reply is not a submitted review: its text lives in a comment that replies
  to an existing thread, the review body is empty, and nothing in it asks for
  action. The watcher therefore classifies a COMMENTED review before
  notifying it:

  * a non-empty review body is a submitted review (actionable);
  * so is a review carrying at least one top-level inline comment
    (`replyTo` absent — the human's half of PR #263);
  * a COMMENTED review whose comments all reply to existing threads is
    recorded as handled and never notified.

  The classification costs one read-only GraphQL query per unseen COMMENTED
  review with an empty body (`node(id: …) { … on PullRequestReview { comments
  { nodes { replyTo { id } } } } }`); `APPROVED` / `CHANGES_REQUESTED`
  reviews need no query, and nothing here mutates GitHub.

  Trade-off: a reviewer who answers *inside* an existing review thread is not
  routed to the child. That keeps a human's and the child's replies to the
  same thread indistinguishable — the data offers no other attribution — and
  the self-sustaining loop is the worse failure; a reviewer who wants action
  submits a review or leaves a PR conversation comment, both of which still
  notify.

  Scenario: A reply-only COMMENTED review is not notified [REQ-1]
    Given a live child whose PR carries the submitted COMMENTED review of the
      PR #263 shape: an empty review body and one top-level inline comment
    And the child's reply to that comment appears as a second COMMENTED review
      whose only comment replies to the first thread
    When the watcher scans and notifies, then scans again
    Then the submitted review is notified exactly once
      And the reply review is never notified
      And the reply's signature is recorded so later scans do not read it again

  Scenario: A COMMENTED review with a top-level inline comment is notified [REQ-2]
    Given a live child whose PR carries a COMMENTED review with an empty body
    And that review's inline comment does not reply to another comment
    When the watcher scans
    Then the review is notified

  Scenario: A COMMENTED review with a review body is notified without reading comments [REQ-3]
    Given a live child whose PR carries a COMMENTED review with a non-empty body
    When the watcher scans
    Then the review is notified
      And no review-comment read is made for it

  Scenario: APPROVED and CHANGES_REQUESTED reviews are notified without reading comments [REQ-4]
    Given a live child whose PR carries an APPROVED review and a
      CHANGES_REQUESTED review
    When the watcher scans
    Then both reviews are notified
      And no review-comment read is made for either

  Scenario: An unreadable review-comment read never notifies and is retried [REQ-5]
    Given a live child whose PR carries a COMMENTED review with an empty body
    And the review-comment read fails
    When the watcher scans
    Then it warns that the review comments could not be read
      And no notice is sent for that review
      And it is not recorded as notified
    When a later scan's review-comment read succeeds and the review is actionable
    Then that scan notifies the review

  Scenario: The attribution read only reads [REQ-6]
    Given a live child with a COMMENTED review to attribute
    When the watcher scans
    Then every gh invocation is a read-only query — `gh pr list` or the
      `node(id: …)` review-comments query
    And no mutating gh invocation is made
    And no keys are sent to the child's pane

  Scenario: The touched scripts stay shellcheck-clean [REQ-7]
    Given shellcheck is available
    When scripts/sub-pr-watch.sh and the suite covering this change are
      checked with shellcheck and bash -n
    Then no findings are reported

  Scenario: An unreadable review does not block other reviews [REQ-8]
    Given a live child whose PR carries a COMMENTED review whose
      review-comment read fails
    And the same PR carries a later review that needs no attribution read
    When the watcher scans
    Then the later review is still notified
      And the unreadable review is retried on a later scan
      And no notice is sent from the unreadable review's data
