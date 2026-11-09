# approved: 2026-11-07 (gate Q1: config — key "childrenAllowedExtensions"; Q2: use the main checkout's uncommitted config)
Feature: Load the child's allowed extensions on the launch line (sub-spawn, _sub-common.sh)

  A spawned child runs with `--no-extensions` and an isolated agent directory
  whose `settings.json` keeps `"packages": []`
  (`specs/child-agent-definitions`). Model providers can be supplied by an
  installed pi package — an extension that calls `pi.registerProvider()` —
  rather than by pi's built-in catalog or `models.json`, so that isolation
  hides every model such a package provides: a child asked to run on one of
  them cannot resolve it and pi exits at startup with
  `Error: Model "…" not found`, which means every spawn at a level mapped to
  a package-provided model fails.

  The child must therefore load exactly the extensions named in
  configuration — its **allowed extensions** — explicitly, on its launch line
  (`-e`) — so those models resolve while the isolation guarantee stays
  untouched: the
  child's `settings.json` still keeps `"packages": []` and the launch line
  still carries `--no-extensions`, so no other configured, discovered, or
  built-in extension sneaks in.

  Naming the allowed extensions is configuration, not code, and follows the
  same defensive contract as the difficulty levels: a missing, malformed, or
  unrecognised config never breaks a spawn, it warns and degrades to the
  previous launch line.

  Scenario: A configured allowed extension is loaded on the child launch line [REQ-37]
    Given a levels config whose childrenAllowedExtensions array lists an
      extension source
    When pi_launch_command builds the child's command line
    Then the line carries an "-e" option for that source
    And the model/thinking options and the kickoff come after it

  Scenario: No configured allowed extensions leave the launch line unchanged [REQ-38]
    Given a levels config without a childrenAllowedExtensions array
    When pi_launch_command builds the child's command line
    Then the line carries no allowed-extension "-e" option
    And the line is the same one it produced before allowed extensions existed

  Scenario: An installed npm extension loads from its install, not the registry [REQ-39]
    Given a childrenAllowedExtensions entry "npm:<name>"
    And that package is installed in the user's pi npm directory
    When pi_launch_command builds the child's command line
    Then the entry is replaced by the installed package's directory
    And a child startup resolves that package's extensions without a registry
      install

  Scenario: A malformed or unreadable config degrades to no allowed extensions [REQ-40]
    Given the levels config is missing, not valid JSON, or has no usable
      childrenAllowedExtensions array
    When pi_launch_command builds the child's command line
    Then no allowed-extension "-e" option is added
    And the config problem warns on stderr without failing the spawn

  Scenario: An env override replaces the configured allowed extensions [REQ-41]
    Given a levels config listing one allowed extension
    And SUB_CHILD_ALLOWED_EXTENSIONS names another
    When pi_launch_command builds the child's command line
    Then only the env entry is loaded with "-e"

  Scenario: The child agent directory keeps its extension isolation [REQ-42]
    Given a levels config whose childrenAllowedExtensions lists extensions
    When prepare_child_agent_dir prepares the child's agent directory
    Then the prepared settings.json still keeps "packages" as an empty array
    And the child launch line still carries --no-extensions

  Scenario: Touched scripts and tests stay bash -n- and shellcheck-clean [REQ-48]
    Given shellcheck is available
    When scripts/_sub-common.sh, scripts/sub-spawn.sh and this change's
      test suites are checked
    Then bash -n and shellcheck report no findings
