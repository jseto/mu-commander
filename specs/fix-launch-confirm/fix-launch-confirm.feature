Feature: Confirm a launch line in a shell pane without escalating to pi evidence (scripts/_sub-common.sh)

  `tmux_send_line` proved pi-composer prompts with transcript evidence, and
  `sub-spawn.sh` types its **launch line** — `pi -n <task> … '<kickoff>'` —
  into a brand-new shell pane, where the shell runs it and pi boots. Two
  things broke that path:

  * the probe is the *literal* typed line, so for a shell-escaped kickoff it
    carries the shell's backslashes (`\"DONE: \<one-line\ summary\>\"`), which
    can never appear literally in anything pi renders — the shell strips them,
    so pi's transcript shows `(or BLOCKED: <reason>)`;
  * when pi boots **before** the first confirmation capture, the pane resolves
    as a live pi TUI, so the send escalated to the strict transcript rule for
    a line that is a shell command, not a composer message. The strict path
    then judged the line "vanished", re-typed the whole launch command into
    the already-running pi (a steering message), and failed — rolling back a
    healthy child (three spawns for `riak-t` #252 failed this way on
    2026-10-18). When pi booted slower, the pane still looked like a shell,
    the legacy change check confirmed, and the spawn worked: the timing
    dependence that made it look intermittent.

  The never-strand-a-prompt guarantee (`specs/fix-parked-prompt`,
  `f9652b6 fix(send): never strand a prompt in a child's composer (#36)`)
  must survive: it governs prompts typed into a *pi* pane, and it keeps
  governing them.

  Scenario: Confirm a launch line that pi boots before the confirmation [REQ-1]
    Given a tmux pane that is a fresh shell, into which a launch line carrying
      a shell-escaped kickoff is typed
    And the Enter runs the line, so pi takes the pane over before it has
      rendered the kickoff — transcript and composer are both empty
    When tmux_send_line confirms the launch with the shell expectation
    Then the confirmation never escalates to pi transcript evidence, because a
      shell launch line is not a composer message and can never appear there
      And the pane content changing after the Enter confirms the send
      And the helper returns success on that first Enter

  Scenario: Never type a launch line into a pi that has booted [REQ-2]
    Given a tmux pane that is a fresh shell and a launch line typed into it
    When tmux_send_line sends the launch with the shell expectation
      and pi takes the pane over during the send
    Then the line is typed into the pane exactly once
      And no launch command is left behind in pi's composer as a steering message

  Scenario: Match submission evidence against the shell-unescaped form [REQ-3]
    Given a tmux pane showing pi's TUI whose transcript shows the message pi
      received: the kickoff of a shell-escaped launch line, with the shell's
      escaping backslashes already stripped by the shell
    When tmux_send_line verifies the send with the pi expectation
    Then the text with the shell's escaping removed counts as submission
      evidence, not only the literal typed form
      And the send is confirmed without typing the line a second time
      And the helper returns success

  Scenario: Never confirm a launch send from a parked pi composer [REQ-4]
    Given a tmux pane where a capture shows the launch text parked in a pi composer
    When tmux_send_line verifies the send with the shell expectation
    Then the pane change never confirms that send
      And Enter is sent again rather than stranding the text
      And the helper returns failure when the pane never releases the text

  Scenario: Spawn a child whose pi boots before the kickoff is confirmed [REQ-5]
    Given a child pane whose first Enter runs the launch line and boots pi
    When sub-spawn.sh spawns a child into it
    Then the spawn exits zero and reports the task handles
      And the launch line is typed into the pane exactly once

  Scenario: Keep the touched shell scripts shellcheck-clean [REQ-6]
    Given shellcheck is available
    When the scripts touched by this change are checked
    Then shellcheck reports no findings