Feature: The spawn kickoff defers to the task brief (scripts/sub-spawn.sh)

  `sub-spawn.sh` builds one hardcoded kickoff message and hands it to every
  child as pi's initial message argument. It used to command every child to
  "complete the full flow … commit … push … create a pull request", which is
  right for a feature/fix child and wrong for a read-only investigation. A
  live read-only RCA child (`fallback-auto-gap`) was kicked off with that
  text while its brief said "Read-only: change nothing, push nothing, open no
  PR"; it followed the brief, but only because it noticed the contradiction —
  a child that followed the kickoff would have committed, pushed and opened
  an unwanted PR.

  The kickoff no longer asserts one deliverable for every child. It names the
  brief as the **source of truth for what the task must deliver**, points at
  this repository's `AGENTS.md` for the process (it does not enumerate the
  flow — briefs never spell out the process flow either), keeps the
  change-task deliverable (commit, push, PR against the resolved base) as the
  default a change brief selects, and states the read-only deliverable
  (change nothing, push nothing, open no PR) that a read-only brief selects.
  The kickoff stays pi's initial message argument, exactly as before.

  Scenario: The kickoff names the brief as the authority on deliverables [REQ-1]
    Given a task brief that exists at the child's brief path
    When sub-spawn.sh spawns the child
    Then the kickoff names that brief path as the source of truth for what the
      task must deliver

  Scenario: A change brief is told to commit, push and open a PR [REQ-2]
    Given a repository whose base branch resolves to "master"
    When sub-spawn.sh spawns a change-task child on branch "task/demo"
    Then the kickoff tells the child to commit on "task/demo"
    And the kickoff tells the child to push its branch to origin
    And the kickoff tells the child to open a pull request against "master"
      using gh pr create

  Scenario: A read-only brief is never contradicted [REQ-3]
    Given a task brief that declares the investigation read-only
    When sub-spawn.sh spawns the child
    Then the kickoff tells the child that a read-only brief changes nothing,
      pushes nothing and opens no PR
    And the report and DONE-notice contract requires no PR link or PR number

  Scenario: The process comes from the repository's AGENTS.md, not the kickoff [REQ-4]
    When sub-spawn.sh spawns a child
    Then the kickoff directs the child to the process this repository's
      AGENTS.md defines
    And the kickoff does not enumerate the flow steps (no "atomic specs",
      "implementation" or "code audit")

  Scenario: The kickoff stays pi's initial message argument [REQ-5]
    When sub-spawn.sh spawns a child
    Then the child's launch line carries the kickoff as pi's initial message
      argument
    And the kickoff is not typed into a pi composer after pi boots

  Scenario: Touched scripts stay shellcheck- and bash -n-clean [REQ-6]
    Given shellcheck is available
    When scripts/sub-spawn.sh and this change's test suite are checked
    Then bash -n and shellcheck report no findings
