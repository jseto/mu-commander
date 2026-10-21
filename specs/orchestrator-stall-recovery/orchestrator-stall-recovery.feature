# approved: 2026-10-20
Feature: Watch and recover the orchestrator's own pi session

  A free-provider failure can wedge the orchestrator itself. When pi-main's
  pane shows pi's own terminal provider error — the usage-limit rejection or
  the free-tier rejection — the session stops answering and no child notice
  is ever acted on again: the whole pattern goes idle while the children keep
  working. Nothing watched pi-main. The child watcher arms one `watch` window
  per child and its stall service is deliberately notify-only (it tells the
  orchestrator to run `sub-fallback.sh <task>` for a child), and
  `sub-fallback.sh` recovers a *child* — so for the orchestrator itself there
  was no window, no scan, and no one to perform the switch.

  This change arms exactly ONE extra window in the orchestrator's tmux
  session (the session named by `MAIN_SESSION`, canonically `pi-main`), at
  startup, using the same detached `watch`-window convention a child watcher
  uses, running one single-purpose orchestrator watcher script. The watcher
  watches its own session's pane with the shared free-provider signature
  vocabularies that already live in `_sub-common.sh`, applied STRICTLY: only
  pi's own error render counts — a line whose trimmed text starts with
  `Error: ` and whose wrapped continuation lines carry the shared signature —
  so a signature quoted in analysis prose, echoed by a tool, or embedded in a
  child's `STUCK: free-provider failure in the child pane (…)` notice can
  never trigger a recovery.

  On an incident the watcher reuses the existing `sub-fallback.sh` recovery
  rules rather than inventing a second detector family: it switches to the
  model named by `taskLevels.fallbackModel` and the level named by
  `taskLevels.fallbackThinking` through the shared verified tmux send, it
  confirms the model in the status bar as a delimited token, it never
  switches speculatively, and an unconfirmed switch is retried and never
  reported as done. After the switch is confirmed it types exactly one wake
  line, because the switch alone never retries the turn the provider error
  killed — without the wake the orchestrator would sit idle on a healthy
  model.

  A main session that already exists is never touched: it gains no window
  and is not restarted (the start-main contract). The watcher dies with the
  session it watches, config problems only warn and keep watching, and a
  window that cannot be armed never fails start-main.

  Its cadence and arming are tuned by the knob family `MAIN_WATCH_INTERVAL`,
  `MAIN_WATCH_RETRY_SECONDS`, `MAIN_WATCH_REWAKE_SECONDS`,
  `MAIN_WATCH_SCAN_LINES`, `MAIN_WATCH_TICKS` (0 = unbounded, a test bound
  only) and `START_MAIN_NO_WATCH` — knobs only, no values that name a model
  or thinking level.

  Non-goals: pinning the orchestrator's own model or thinking level at
  startup — `start-main.sh` keeps launching plain pi, and this feature only
  recovers an already-failed session; changing the child stall service (it
  stays notify-only) or `sub-fallback.sh`'s behaviour for children; and a
  structured follow-up detector read from the session JSONL's last
  `stopReason: "error"` — a known limitation of the pane-based detector here,
  to refine later.

  Scenario: Starting a new main session arms one orchestrator watcher window [REQ-1]
    Given no tmux session named "pi-main" exists on the server
    When the script is run with "--detach"
    Then it exits successfully
    And the "pi-main" session gains exactly one additional window, named
      "watch", running the orchestrator watcher script for that session
    And the session's first window still runs the launched pi executable
    And no other window is created
    And the output reports the watcher state

  Scenario: An existing main session gains no watcher and is not restarted [REQ-2]
    Given a running "pi-main" session that has no watcher window
    When the script is run with "--detach"
    Then it exits successfully
    And the session's window list is unchanged — no watcher window is added
    And the session's pane process was not restarted
    And the output names the session and its working directory

  Scenario: A free-provider failure rendered by pi in the main pane is detected [REQ-3]
    Given a running "pi-main" session whose pane shows pi's own error render:
      a line whose trimmed text starts with "Error: " and carries, on that
      line or its wrapped continuation lines, the shared free-provider
      signature
    When the watcher scans
    Then it detects a free-provider failure in the orchestrator's own pane
    And it starts the recovery instead of leaving the orchestrator idle
    And a pane whose visible text carries no such render is not detected

  Scenario: A signature quoted in prose or tool output is not a failure [REQ-4]
    Given a running "pi-main" pane whose visible text mentions the
      free-provider signature inside analysis prose or tool output, on a line
      whose trimmed text does not start with "Error: "
    When the watcher scans
    Then it detects no failure
    And no keys are sent to the orchestrator's pane

  Scenario: A child STUCK notice quoting the signature is not a failure [REQ-5]
    Given a running "pi-main" pane showing a delivered child notice
      "STUCK: free-provider failure in the child pane (…)"
    When the watcher scans
    Then it detects no failure in the orchestrator's own pane
    And no keys are sent to the orchestrator's pane
    And it does not mistake its own notification traffic for an incident

  Scenario: Both free-provider failure kinds are detected [REQ-6]
    Given a running "pi-main" pane showing pi's error render for the
      usage-limit rejection
    When the watcher scans
    Then it detects a free-provider failure
    Given a running "pi-main" pane showing pi's error render for the
      free-tier rejection
    When the watcher scans
    Then it detects a free-provider failure
    And both were detected through the shared free-provider signature the
      existing probes already use

  Scenario: An error render wrapped over several pane lines is detected [REQ-7]
    Given a running "pi-main" pane where pi's "Error: " line is wrapped and
      the free-provider signature sits on its continuation line
    When the watcher scans
    Then it detects a free-provider failure

  Scenario: A detected failure switches the orchestrator to the configured fallback [REQ-8]
    Given a running "pi-main" pane showing pi's free-provider error render
    And the config names a fallback model in "taskLevels.fallbackModel"
    When the watcher scans
    Then "/model" with that fallback model is sent to "pi-main" through the
      verified send, exactly as the existing fallback recovery does for a child
    And it waits until the status bar shows that model id as a delimited token
    And it reports the switch as performed

  Scenario: A pane without a pi error render sees no keys [REQ-9]
    Given a running "pi-main" pane showing ordinary transcript output
    When the watcher scans
    Then it detects no failure
    And no keys are sent to any tmux session
    And no model or thinking command is typed anywhere

  Scenario: A main pane that is not running pi is never typed into [REQ-10]
    Given a "pi-main" session whose pane is running a shell instead of pi
    When the watcher scans
    Then it sends no keys to the pane
    And it keeps watching instead of exiting

  Scenario: An orchestrator already on the fallback model is not switched [REQ-11]
    Given a running "pi-main" pane showing pi's free-provider error render
    And whose status bar shows exactly the configured fallback model id,
      delimited by the line edges or by characters outside the model-id
      alphabet
    When the watcher scans
    Then no "/model" command is sent to "pi-main"
    And the same visible failure causes no switch on later scans either

  Scenario: A status-bar id that extends the fallback id is not "already on" [REQ-12]
    Given a running "pi-main" pane showing pi's free-provider error render
    And whose status bar shows a model id that merely extends the configured
      fallback id as a prefix or a suffix
    When the watcher scans
    Then the extended id does not count as already-on: "/model" with the
      configured fallback model is sent and confirmed

  Scenario: The configured fallback thinking level is applied [REQ-13]
    Given taskLevels.fallbackThinking names a level
    And a model switch confirmed in the status bar left it at a different level
    When the recovery continues
    Then "/thinking" with that configured level is sent to "pi-main" through
      the verified send
    And it waits until the status bar shows that level
    And a status bar already showing that level after the switch receives no
      "/thinking" command

  Scenario: A fallback thinking level the model rejects degrades to a warning [REQ-14]
    Given taskLevels.fallbackThinking names a level the fallback model rejects
    When the recovery runs and pi answers with its unknown-thinking-level error
    Then the model switch is still reported as performed and the recovery is
      not reported as failed
    And it never reports the thinking level as set
    And it warns that fallbackThinking does not match fallbackModel — a
      config.json problem to fix
    And it stops at the rejection with the composer left clear

  Scenario: One switch per incident while the same failure stays visible [REQ-15]
    Given a running "pi-main" pane showing pi's free-provider error render
    And the watcher has completed the recovery for it
    When the watcher scans repeatedly with the render still visible, before
      "MAIN_WATCH_REWAKE_SECONDS" elapses
    Then no further "/model" or "/thinking" command is sent to "pi-main"
    And no further wake line is typed into "pi-main" before that interval
      elapses

  Scenario: An unconfirmed switch is retried and never claimed [REQ-16]
    Given a running "pi-main" pane showing pi's free-provider error render
    And a switch whose status bar confirmation never arrives
    When the watcher scans again after "MAIN_WATCH_RETRY_SECONDS"
    Then it clears the orchestrator's composer before retrying
    And it retries the switch on the later scan
    And it never reports the unconfirmed switch as performed

  Scenario: A confirmed switch wakes the idle orchestrator exactly once [REQ-17]
    Given the recovery switch has been confirmed in the status bar
    When the watcher finishes that incident
    Then exactly one wake line is typed into "pi-main" through the verified send
    And the wake tells the orchestrator that its interrupted turn should be
      resumed
    And nothing else is typed into "pi-main" after that wake
    And no wake is typed when the switch was not confirmed

  Scenario: The watcher only ever types into the main session [REQ-18]
    Given a running "pi-main" pane showing pi's free-provider error render
    And a live child session "pi-<task>"
    When the watcher completes the recovery
    Then every key it sends goes to the "pi-main" session
    And no keys are sent to any child session's pane
    And it sends no notice to "pi-main" through the child report helper,
      because it never reports to itself

  Scenario: A cleared failure lets a later failure be recovered again [REQ-19]
    Given the watcher recovered a free-provider failure in "pi-main"
    And the error render is no longer visible in the pane
    When pi's free-provider error render appears in the pane again
    Then the watcher treats it as a new incident
    And it switches to the fallback model and wakes the orchestrator again

  Scenario: Config problems warn, send nothing, and keep watching [REQ-20]
    Given a running "pi-main" pane showing pi's free-provider error render
    And a config that is missing, unreadable, or malformed, or that names no
      "taskLevels.fallbackModel"
    When the watcher scans
    Then it warns, naming the config and the missing fallback
    And it sends no "/model" command to "pi-main"
    And it keeps watching instead of exiting or failing

  Scenario: Disarming the watcher leaves start-main succeeding [REQ-21]
    Given no tmux session named "pi-main" exists on the server
    And "START_MAIN_NO_WATCH" is set to "1"
    When the script is run with "--detach"
    Then it exits successfully and the session runs pi
    And the session gains no "watch" window
    And the output reports the watcher disabled

  Scenario: A watcher window that cannot be armed does not fail start-main [REQ-22]
    Given a tmux that refuses to create the additional window
    When the script is run with "--detach"
    Then it exits successfully and the session runs pi
    And it warns that the orchestrator watcher could not be armed
    And the output reports that only automatic watching is missing

  Scenario: The watcher stops when the main session goes away [REQ-23]
    Given a running "pi-main" session with an armed watcher
    When the session is killed
    Then the watcher reports that the watched session is not running
    And it exits 0 without scanning again

  Scenario: A test scan bound stops the watcher after that many scans [REQ-24]
    Given a watcher bounded by "MAIN_WATCH_TICKS" to one scan
    When the watcher runs
    Then it performs one scan and exits 0
    And "MAIN_WATCH_TICKS" of 0 leaves it unbounded

  Scenario: The child stall service stays notify-only and unchanged [REQ-25]
    Given a child whose pane shows a free-provider failure
    When the child's watcher scans
    Then it sends the orchestrator the same notify-only "STUCK:" notice as
      before
    And it switches no model and types into no child pane

  Scenario: Sub-fallback keeps recovering children only on a visible failure [REQ-26]
    Given a running child whose pane shows the free-provider error
    When the fallback script runs for that child
    Then it switches the child to the configured fallback model and confirms it
    Given a running child whose pane shows no such error
    When the fallback script runs for that child
    Then it sends no keys and reports that no switch was performed

  Scenario: Touched scripts stay shellcheck-clean [REQ-27]
    Given shellcheck is available
    When the orchestrator watcher script, scripts/start-main.sh, and
      scripts/_sub-common.sh are checked with shellcheck and bash -n
    Then all report no findings

  Scenario: A visible failure while already on the fallback still gets a wake [REQ-31]
    Given a running "pi-main" pane showing pi's free-provider error render
    And whose status bar already shows the configured fallback model id
    When the watcher scans
    Then it sends no "/model" or "/thinking" command to "pi-main"
    And it types exactly one wake line, exactly as the wake-only recovery of
      an interrupted turn
    And it never reports a model switch as performed

  Scenario: An unchanged failure is woken again after the rewake interval [REQ-32]
    Given a running "pi-main" pane showing pi's free-provider error render
    And the watcher has already woken the orchestrator for it, after a
      confirmed switch or because the session was already on the fallback
    When the watcher scans repeatedly before "MAIN_WATCH_REWAKE_SECONDS"
      elapses
    Then it types no further wake line
    When "MAIN_WATCH_REWAKE_SECONDS" has elapsed with the same failure still
      visible
    Then it types one further wake line so the orchestrator retries its turn
    And it never re-sends "/model" for the same incident

  Scenario: The watcher follows pi's window instead of the session's selection [REQ-33]
    Given a "pi-main" session whose window list holds the pi window and the
      watch window
    And the operator has selected the watch window as the session's current
      window
    When the watcher scans
    Then it reads and types into the pi window only
    And it never addresses the session target that follows the selection, nor
      the watch window
    And the visible failure is detected and recovered there

  Scenario: An unverified window index is never the watcher's pin [REQ-34]
    Given a "pi-main" session on a base-index-1 server, whose index 0 does not
      exist
    And tmux would resolve a missing index to the session's selected window
    When the watcher is armed without a window index
    Then it resolves the pi window from the session's window list instead of
      pinning an unverified index
    When it is armed with a window index that its verification probe does not
      confirm
    Then the unverified index is dropped and the pi window is resolved again
    And the visible failure is detected and recovered in the pi window
    And neither the selected window nor a missing index is ever typed into

  Scenario: A different incident is recovered, never merely woken [REQ-35]
    Given a "pi-main" pane showing pi's free-provider error render
    And the watcher has recovered that incident with a confirmed switch and a
      wake
    When the visible pane shows a different free-provider error render in the
      next scan, with no error-free scan in between, and the session is back on
      a non-fallback model
    Then the watcher treats it as a new incident
    And it switches the session to the configured fallback model again
    And it wakes the orchestrator again
    And the recovered state of the earlier incident never turns the new one
      into a wake-only

  Scenario: A pi reached through a launcher or an interpreter is still pi [REQ-36]
    Given a "pi-main" pane whose current command is not literally "pi" — a
      launcher symlink reports "pi", an installed pi reports the interpreter
      that runs it
    When the watcher checks whether the pinned pane is pi
    Then a command that is not a shell or another interactive non-TUI program
      counts as pi
    And the failure is detected and recovered there
    And a shell or other interactive non-TUI program is still never typed into
