Feature: Never strand a prompt in a child's composer (scripts/_sub-common.sh)

  `tmux_send_line` proved a send with region evidence, but the regions
  themselves were derived wrongly, so the helper could — and did (reproduced
  2026-10-17 on `pi-riak-250-review`) — warn "the visible copy of the text is
  in the transcript, not the composer" and return 1 **before pressing Enter**,
  leaving the instruction parked in the composer's input box. An unconfirmed
  send must never strand the prompt: whenever the text is visible in the pane
  but its composer region cannot be proven, the state is *unknown*, not
  *sent* — the helper presses Enter and accepts the send only on positive
  submission evidence (the line left the composer and reached the transcript).
  An empty Enter against an already-submitted line is harmless; a parked
  prompt is not.

  Scenario: Submit a prompt whose composer is separated from the status border by a blank line [REQ-1]
    Given a tmux pane showing pi's TUI with the typed line in the composer
    And the composer block is separated from the status border by a blank line
      (pi had not drawn the composer's top border yet)
    When tmux_send_line verifies the send
    Then Enter is sent to the pane
      And the send is confirmed from positive submission evidence
      And the helper returns success

  Scenario: Submit a prompt sitting below the working row of a freshly rendered pane [REQ-1]
    Given a tmux pane showing pi's TUI whose composer holds the typed line
    And a blank line above the composer and pi's "Working" row above that
    When tmux_send_line verifies the send
    Then Enter is sent to the pane
      And the send is confirmed from positive submission evidence
      And the helper returns success

  Scenario: Treat visible-but-unproven text as unknown instead of sent [REQ-2]
    Given a tmux pane showing pi's TUI in which the typed line is visible
    And the pane's regions cannot prove the line sits in the composer
    When tmux_send_line decides what may confirm the send
    Then it does not abandon the send before pressing Enter
      And it confirms only once the line left the composer and reached the transcript
      And the helper returns success when that evidence appears

  Scenario: Do not submit an already-submitted line a second time [REQ-3]
    Given a tmux pane showing pi's TUI whose transcript already holds the line
      and whose composer is empty
    When tmux_send_line verifies the send
    Then the send is confirmed without the line being submitted twice

  Scenario: Keep the composer region bounded [REQ-4]
    Given a captured pane in pi's TUI layout whose transcript runs into the
      status border without a blank separator
    When the capture is split into regions
    Then the composer region covers only the lines directly above the status border
      And the older transcript lines above them are reported as the transcript

  Scenario: Re-type only a prompt that vanished from the whole pane [REQ-5]
    Given a tmux pane showing pi's TUI where the typed line stays visible but
      is not provably inside the composer
    When tmux_send_line verifies the send
    Then the line is not typed a second time on the strength of that capture

  Scenario: Name what was attempted when the send cannot be confirmed [REQ-6]
    Given a tmux pane that never confirms the typed line
    When tmux_send_line exhausts its attempts
    Then the helper fails loudly and its warning names how often the line was
      typed and how often Enter was sent
      And the warning states the prompt may still be parked in the composer

  Scenario: Keep confirming launches typed into non-pi panes [REQ-7]
    Given a tmux pane that is an interactive shell, not pi's TUI
      (the start-main.sh / sub-spawn.sh launch path)
    When tmux_send_line types the launch line and sends Enter
    Then the pane content changing after Enter still confirms the send
      And the helper returns success

  Scenario: Never confirm from an incompletely drawn pi pane [REQ-7]
    Given a tmux pane that shows pi's chrome but whose status border is not
      resolvable yet, and whose content changes on every Enter
    When tmux_send_line verifies the send
    Then the pane change never confirms the send
      And the helper returns failure

  Scenario: Keep a dashed-looking parked line inside the composer [REQ-4]
    Given a captured pane in pi's TUI layout whose composer holds a line that
      happens to be delimited by box-drawing dashes
    When the capture is split into regions
    Then that line is reported as the composer
      And it is not pushed into the transcript

  Scenario: Keep the touched shell scripts shellcheck-clean [REQ-8]
    Given shellcheck is available
    When the scripts touched by this change are checked
    Then shellcheck reports no findings

  Scenario: Press Enter before giving up when the typed line never rendered [REQ-9]
    Given a tmux pane that accepts the typed bytes but never renders them
    When tmux_send_line exhausts its attempts
    Then Enter is still sent once, in case the composer renders the line late
      And the helper fails loudly without claiming the send