Feature: Telegram reply persistence with draft previews
  Streaming draft previews (sendRichMessageDraft / sendMessageDraft) are
  ephemeral: Telegram keeps a draft only while it is being updated and drops
  it within ~30 s. An answer therefore exists in the chat only after the
  bridge persists it with sendRichMessage / sendMessage. The 2026-10-03
  investigation (see telegram-reply-persistence-design.md and
  tmp/pi-sub/reports/research-telegram-vanish.md) showed that when the
  persistence step is skipped or wedged, the user watches the streamed draft
  appear and then disappear with no replacement, while the bridge records no
  diagnostic at all.

  These scenarios state the behavior the upstream pi-telegram fix must
  provide. The defects were observed in @llblab/pi-telegram 0.51.6 and are
  NOT fixed in this repository — this folder is the requirements side of the
  upstream report, not a local code change.

  Scenario: Persist the final answer of a Telegram turn when draft previews are enabled [REQ-1]
    Given draft previews are enabled for the bridge
    And a Telegram-originated turn streams its answer as a draft preview
    When the turn completes with final text
    Then a permanent Telegram message containing that answer exists in the chat

  Scenario: A cleared draft is always replaced by the persisted answer [REQ-2]
    Given a Telegram turn streamed a draft preview
    And the turn completed with final text
    When the bridge clears, discards, or replaces the draft state
    Then a permanent message containing the final text has been sent
    And no code path deletes an already-persisted answer while clearing the draft

  Scenario: Record a delivery diagnostic whenever the final answer is not persisted [REQ-3]
    Given a Telegram turn completed with final text
    When the final send is skipped or abandoned for any reason
    Then the bridge records a runtime event naming the skip reason and the turn
    And the bridge log contains that event

  Scenario: A stalled delivery does not block later replies indefinitely [REQ-4]
    Given one assistant publication task never settles
    When a later Telegram reply is delivered
    Then the later reply reaches Telegram within a bounded time
    And the bridge records a diagnostic that the first delivery timed out

  Scenario: A text-only reply records no voice-synthesis failure [REQ-5]
    Given a planned final reply contains no voice artifact
    When the reply is delivered
    Then no voice-synthesis failure event is recorded for the turn

  Scenario: Persisted replies survive late draft activity [REQ-6]
    Given a final answer was persisted as a permanent message
    When a late draft frame, clear, or expiry occurs for the same draft id
    Then the persisted message still exists in the chat
    And its text is not replaced by the draft

  Scenario: A truncated multi-chunk send is reported and never silently deleted [REQ-7]
    Given a final answer requires more than one outbound chunk
    When a later chunk fails after earlier chunks were sent
    Then the bridge records which chunks were persisted and that the answer is incomplete
    And the already-persisted chunks remain in the chat
