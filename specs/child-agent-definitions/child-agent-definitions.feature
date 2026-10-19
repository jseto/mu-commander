Feature: Custom agent definitions in the child agent directory (prepare_child_agent_dir)

  A spawned child runs with an isolated `PI_CODING_AGENT_DIR` built by
  `prepare_child_agent_dir()`. That directory preserves auth, model settings,
  skills, prompts and themes from `$HOME/.pi/agent` — but not `agents/`, so a
  child saw only pi's built-in agent types (`general-purpose`, `Explore`,
  `Plan`) and could not use the custom definitions the orchestrator flow
  depends on (`nff-specify`, `nff-implement`, `nff-test`, `nff-audit`).
  Linking the user-level `agents/` directory fixes that without weakening the
  isolation the prepared directory exists for: extensions and packages stay
  out, and project-level `.pi/agents/*.md` definitions in the child's
  worktree keep being discovered from the worktree, so they are neither
  shadowed nor disabled.

  Scenario: The source agent definitions are visible from the child agent directory [REQ-1]
    Given a user agent directory containing an agent definition
    When prepare_child_agent_dir prepares the child's agent directory
    Then the prepared directory exposes that definition at agents/<name>.md
    And the exposed definition is the source file, not a copy

  Scenario: Extensions and packages stay out [REQ-2]
    Given a user agent directory with an extensions directory and a
      non-empty package list in its settings
    When prepare_child_agent_dir prepares the child's agent directory
    Then extensions is a real, empty directory in the prepared directory
    And the prepared settings.json keeps "packages" as an empty array

  Scenario: A missing user agents directory is not an error [REQ-3]
    Given no agents directory in the user agent directory
    When prepare_child_agent_dir prepares the child's agent directory
    Then it exits successfully without printing an error
    And the prepared directory has no agents entry (no dangling link)

  Scenario: Only the user-level agents are linked, never a worktree's [REQ-4]
    Given a user agent directory
    And a child worktree with its own .pi/agents definitions
    When prepare_child_agent_dir prepares the child's agent directory
    Then agents links exactly the user agent directory
    And the worktree's .pi/agents definitions are left untouched, so
      project-level agents keep being discovered from the worktree

  Scenario: Touched files stay shellcheck- and bash -n-clean [REQ-5]
    Given shellcheck is available
    When scripts/_sub-common.sh and this change's test suite are checked
    Then bash -n and shellcheck report no findings
