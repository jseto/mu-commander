Feature: Per-task difficulty levels for child model and thinking (sub-spawn)
  The orchestrator evaluates each task and picks one of three difficulty
  levels; the level decides the child's model and thinking level. The levels
  are configuration, not code: they live in a config file at the root of the
  mu-commander checkout, inside the namespaced "taskLevels" top-level
  section. That config is a generic root-level file: future general settings
  live in sibling top-level keys,
  and level resolution must ignore them — an unknown sibling key never breaks
  a spawn. Resolution is defensive:
  an explicit --model/--thinking flag beats the level mapping, the env
  equivalents beat it next, a missing or malformed config degrades to "no
  flags" (the child then inherits defaultThinkingLevel / modelThinkingLevels
  from the global pi settings), and a bad invocation dies before any work
  (no worktree is leased). The model/thinking options must reach pi as
  options on the launch line, ahead of the kickoff message argument.

  Scenario: Named levels select their configured mapping [REQ-2]
    Given a fixture config whose "taskLevels.levels" maps "easy" and
      "hard" to a model and a thinking level
    When resolve_child_launch_flags is called with level "easy"
    Then it echoes the "easy" mapping's model and thinking
    When resolve_child_launch_flags is called with level "hard"
    Then it echoes the "hard" mapping's model and thinking

  Scenario: Explicit flags beat the level mapping [REQ-3]
    Given a fixture config whose default level maps to a model and a
      thinking level
    When resolve_child_launch_flags is called with thinking "low"
    Then it echoes the default level's model with "--thinking low"
    When resolve_child_launch_flags is called with model "custom/m"
    Then it echoes "--model custom/m" with the default level's thinking

  Scenario: Env overrides apply when flags are absent, flags win over env [REQ-4]
    Given a fixture config with an "easy" level mapping
    And SUB_LEVEL=easy is set in the environment
    When resolve_child_launch_flags is called with no arguments
    Then it echoes the "easy" mapping
    Given SUB_MODEL=env/m is also set
    When resolve_child_launch_flags is called with no arguments
    Then it echoes "--model env/m" with the easy level's thinking
    When resolve_child_launch_flags is called with model "flag/m"
    Then it echoes "--model flag/m" with the easy level's thinking

  Scenario: Missing config degrades to no flags [REQ-5]
    Given SUB_LEVELS_CONFIG points at a path that does not exist
    When resolve_child_launch_flags is called with no arguments
    Then it exits 0, echoes nothing, and warns "config.json not found" on stderr

  Scenario: Unknown level degrades to no flags [REQ-6]
    Given a valid config whose "taskLevels.levels" has no entry "bogus"
    When resolve_child_launch_flags is called with level "bogus"
    Then it exits 0, echoes nothing, and warns on stderr

  Scenario: Malformed config degrades to no flags [REQ-7]
    Given SUB_LEVELS_CONFIG points at a file that is not valid JSON
    When resolve_child_launch_flags is called with no arguments
    Then it exits 0, echoes nothing, and warns "config.json invalid" on stderr

  Scenario: Child settings inherit the thinking and trust baseline [REQ-8]
    Given a global agent settings file with defaultThinkingLevel "high",
      modelThinkingLevels, and defaultProjectTrust "always"
    When prepare_child_agent_dir prepares the child's agent directory
    Then the produced settings.json contains those three keys
      merged with the model defaults and "packages": []

  Scenario: Launch line carries model/thinking options ahead of the kickoff [REQ-9]
    Given resolved launch flags "--model a/b --thinking xhigh"
    When pi_launch_command builds the child's pi command line
    Then the line starts with "pi -n demo --no-extensions --model a/b --thinking xhigh --approve"
    And the kickoff text appears as the final, single quoted word
    When pi_launch_command is called with empty flags
    Then the line starts with "pi -n demo --no-extensions --approve"

  Scenario: Bad spawn invocations die before any work [REQ-10]
    Given sub-spawn.sh is invoked without positional arguments
    Then it exits non-zero with the usage line
    When invoked with an unknown option or a --level without a value
    Then it exits non-zero before leasing a worktree

  Scenario: Touched scripts stay shellcheck-clean [REQ-11]
    Given shellcheck is available
    When scripts/_sub-common.sh and scripts/sub-spawn.sh are checked with
      shellcheck and bash -n
    Then both report no findings

  Scenario: Unknown sibling top-level keys in config.json are ignored [REQ-12]
    Given a config whose top level holds the "taskLevels" section alongside
      unrelated unknown keys (e.g. "notifications", "featureFlags")
    When resolve_child_launch_flags is called with no arguments
    Then it resolves the default level from "taskLevels" as usual
    And exits 0 without warnings — a future general setting added to
      config.json never breaks a spawn
