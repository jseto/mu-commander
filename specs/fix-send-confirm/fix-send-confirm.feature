Feature: Evidence-based prompt submission in tmux_send_line (scripts/_sub-common.sh)
  tmux_send_line must never report a successful send for a prompt that is
  still parked in a pi child's composer. Its old success check — "the pane
  content changed after an Enter" — only proves the pane reacted, not that
  the line was submitted: a busy redraw, spinner frame, or status-bar tick
  satisfies it while the Enter was actually dropped (real incident,
  2026-10-02, session pi-riak-recent-ui: sub-send printed "instruction sent"
  for a line still sitting in the composer). For panes showing pi's TUI the
  helper must demand positive submission evidence — the line left the
  composer and appears in the transcript — while panes that are not pi
  (the shell panes start-main.sh and sub-spawn.sh type their launch into)
  keep the existing change-based confirmation.

  Scenario: Confirm a pi-composer prompt only from positive evidence [REQ-1]
    Given a tmux pane showing pi's TUI with the typed line visible in the composer
    When tmux_send_line sends Enter to the pane
    Then the send is confirmed only once the line no longer sits in the composer
      And the line appears in the pane's transcript region
    And the helper returns success

  Scenario: Never confirm a parked prompt while the pane redraws [REQ-2]
    Given a tmux pane showing pi's TUI with the typed line parked in the composer
    And every Enter is swallowed while the pane content still changes (spinner or status-bar redraw)
    When tmux_send_line sends Enter up to its attempt bound
    Then Enter is sent more than once
    And the helper never reports the line as submitted
    And the helper returns failure

  Scenario: Re-type a prompt that vanished without reaching the transcript [REQ-3]
    Given a tmux pane showing pi's TUI with the typed line visible in the composer
    And an Enter clears the line from the pane without ever showing it in the transcript (TUI reset or compaction wipe)
    When tmux_send_line verifies the send
    Then the line is typed into the pane a second time
    And a submission of the re-typed line is confirmed as in [REQ-1]

  Scenario: Fail loudly when the typed text never appears [REQ-4]
    Given a tmux pane whose send-keys input is lost before it renders
    When tmux_send_line types the line
    Then the line is typed more than once
    And no Enter-based success is ever reported
    And the helper returns failure

  Scenario: Fail loudly when submission stays unconfirmed through bounded retries [REQ-5]
    Given a tmux pane showing pi's TUI that swallows every Enter
    When tmux_send_line exhausts its attempts
    Then the helper returns failure
    And a caller such as sub-send.sh prints an ERROR instead of its success line
    And a caller such as sub-report.sh prints an ERROR pointing at the durable report file

  Scenario: Keep confirming launches typed into non-pi panes [REQ-6]
    Given a tmux pane that is an interactive shell, not pi's TUI (start-main.sh / sub-spawn.sh launch)
    When tmux_send_line types the launch line and sends Enter
    Then the typed line is visible in the pane
    And the pane content changing after Enter still confirms the send
    And the helper returns success

  Scenario: Recognize pi's composer and transcript regions from a pane capture [REQ-7]
    Given a captured pane in pi's TUI layout (status border above the path and stats lines)
    When the capture is split into regions
    Then the lines directly above the status border are reported as the composer
      And everything above the composer block is reported as the transcript
    And an empty composer, a working spinner row, a parked line, and a submitted line are each classified as in the observed layouts
    And a pane without pi's layout (a shell) is reported as unrecognized

  Scenario: Keep the existing success-path wording for callers [REQ-8]
    Given a pane that accepts and submits the typed line
    When sub-send.sh sends an instruction
    Then it exits zero printing "instruction sent to <session>"
    And sub-report.sh exits zero printing "notice delivered to <target>"


  Scenario: Keep the touched shell scripts shellcheck-clean [REQ-10]
    Given shellcheck is available
    When the scripts touched by this change are checked
    Then shellcheck reports no findings
