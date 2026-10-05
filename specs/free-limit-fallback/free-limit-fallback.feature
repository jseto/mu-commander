Feature: Fallback model for the free provider's usage limit (sub-fallback)
  The free provider behind the `easy` child level
  (opencode-zen-free/mimo-v2.6-flash-free) can exhaust its quota and answer
  every request with FreeUsageLimitError (HTTP 429). A second free-provider
  failure wedges a child the same way: pi's compaction/summarization calls
  answered with HTTP 403 FreeTierError ("OpenCode's free tier can only be
  used from within OpenCode") block auto-compaction and leave the child
  stuck. Pi treats that provider
  error as terminal — it does not retry — so the child sits idle and the
  task stalls. A fallback model entry in config.json (taskLevels.fallbackModel,
  plus an optional taskLevels.fallbackThinking) names a model the orchestrator
  can switch an affected child to at runtime, through the same verified
  tmux send used for every other child instruction (type, retry Enter,
  confirm submission). The switch is only ever sent when the child's pane
  already shows the free-limit failure — never speculatively — and it is
  confirmed against the pi status bar (the last non-empty pane line) before
  the helper reports success. Missing or unreadable config, or a missing
  fallbackModel, means "no fallback": existing helpers must keep working
  unchanged and sub-fallback must not invent a model.

  Scenario: Env overrides win over the configured fallback [REQ-2]
    Given SUB_FALLBACK_MODEL=custom/fb and SUB_FALLBACK_THINKING=low are set
    When resolve_fallback_model and resolve_fallback_thinking are called
    Then each echoes its environment value, whatever the config holds

  Scenario: Missing fallback entry or unreadable config degrades to none [REQ-3]
    Given a config whose taskLevels section has no fallbackModel
    When resolve_fallback_model is called
    Then it echoes nothing and exits 0 without warnings
    When SUB_LEVELS_CONFIG points at a missing file
    Then resolve_fallback_model echoes nothing and exits 0
    When SUB_LEVELS_CONFIG points at a file that is not valid JSON
    Then resolve_fallback_model echoes nothing and exits 0

  Scenario: A free-limit error in the pane is detected [REQ-4]
    Given a child pane showing
      'Error: 429: {"type":"FreeUsageLimitError","message":"Rate limit exceeded."}'
    When pane_has_free_limit_error is called for the task
    Then it reports the error
    And a pane whose text carries no error signature reports none

  Scenario: No error means no switch [REQ-5]
    Given a running child whose pane shows ordinary output
    When sub-fallback.sh runs for the task
    Then no keys are sent to the child's pane
    And it prints that no model switch was performed and exits 0

  Scenario: A detected error switches the child to the fallback [REQ-6]
    Given a running child whose pane shows the free-limit error
    And the config's fallbackModel names a model the switch can target
    When sub-fallback.sh runs for the task
    Then "/model opencode-go/mimo-v2.6-flash" is sent through the
      verified send and confirmed
    And it waits until the child's status bar shows the model id as a
      delimited token, not as a substring of a longer id
    And it exits 0 reporting the switch

  Scenario: The configured thinking level is in effect after recovery [REQ-7]
    Given the model switch already leaves the status bar at the configured
      level
    Then sub-fallback.sh sends no "/thinking" command and reports the level
      is already in effect
    When the model switch leaves the status bar at a different level
    Then sub-fallback.sh sends "/thinking <configured level>" and waits
      until the status bar shows it
    And in both cases the recovered child ends on the configured level

  Scenario: A switch that never reaches the status bar fails loudly [REQ-8]
    Given a running child whose pane shows the free-limit error
    And a pane that accepts the send but never updates its status bar
    When sub-fallback.sh runs for the task
    Then it exits non-zero with an ERROR naming the session and the model
    And it clears the child's composer so no command is left parked
    And it does not claim that the switch happened

  Scenario: An error without a configured fallback performs no switch [REQ-9]
    Given a config whose taskLevels section has no fallbackModel
    And a running child whose pane shows the free-limit error
    When sub-fallback.sh runs for the task
    Then no keys are sent to the child's pane
    And it fails with a clear message naming config.json

  Scenario: Already on the fallback model is a no-op [REQ-10]
    Given a running child whose pane shows the free-limit error
    And whose status bar shows exactly the fallback model id, delimited by
      the line edges or characters outside the model-id alphabet
    When sub-fallback.sh runs for the task
    Then no keys are sent to the child's pane
    And it prints that the child is already on the fallback and exits 0

  Scenario: A status bar id that merely extends the fallback id is not "already on" [REQ-14]
    Given a running child whose pane shows the free-limit error
    And whose status bar shows "mimo-v2.6-flash-free" while the configured
      fallbackModel is "opencode-go/mimo-v2.6-flash"
    When sub-fallback.sh runs for the task
    Then the prefix id does not count as already-on: "/model
      opencode-go/mimo-v2.6-flash" is sent and confirmed
    And it exits 0 reporting the switch

  Scenario: A configured thinking level the model rejects degrades to the model recovery [REQ-15]
    Given a running child whose pane shows the free-limit error
    And the model switch succeeds and the status bar shows a level other
      than the configured fallbackThinking
    And the pane answers 'Error: Unknown thinking level "<level>"' to the
      /thinking command
    When sub-fallback.sh runs for the task
    Then the model switch is reported and the helper exits 0
    And it never reports the thinking level as set
    And it warns that the configured fallbackThinking does not match
      fallbackModel — a config problem for config.json
    And it stops at the rejection instead of nudging the composer in a
      warn loop, leaving the composer clear

  Scenario: A FreeTierError/403 pane failure is detected [REQ-17]
    Given a child pane showing pi's compaction failures
      'Auto-compaction failed: Turn prefix summarization failed: 403:'
      followed by
      '{"type":"FreeTierError","message":"OpenCode's free tier can only be
      used from within OpenCode"}'
    When pane_has_free_limit_error is called for the task
    Then it reports the failure
    When sub-fallback.sh runs for the task with a configured fallbackModel
    Then "/model <fallbackModel>" is sent through the verified send and
      confirmed instead of no-op'ing

  Scenario: Failure messages describe both detected failure kinds [REQ-18]
    Given a running child whose pane shows ordinary output
    When sub-fallback.sh runs for the task
    Then no keys are sent to the child's pane
    And its no-switch message names both FreeUsageLimitError and
      FreeTierError and exits 0
    Given a config whose taskLevels section has no fallbackModel
    And a running child whose pane shows the FreeTierError failure
    When sub-fallback.sh runs for the task
    Then it fails with a message naming config.json and describing the pane
      as a free-provider failure, not only as a usage limit

  Scenario: A missing child session dies before anything else [REQ-11]
    Given the child's tmux session is not running
    When sub-fallback.sh runs for the task
    Then it exits non-zero with "not running" on stderr

  Scenario: Touched scripts stay shellcheck-clean [REQ-13]
    Given shellcheck is available
    When scripts/_sub-common.sh and scripts/sub-fallback.sh are checked with
      shellcheck and bash -n
    Then both report no findings
