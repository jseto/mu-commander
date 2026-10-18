Feature: Tests never pin a model id or a thinking level
  config.json is the owner's hand-edited single source of truth for the
  level -> model and level -> thinking mappings. Retuning it by hand must
  never turn a test red, so no test may assert a concrete model id or
  thinking level, nor build an expectation out of the shipped mapping. The
  spawn/launch harnesses assert the SHAPE of a child launch line — its
  options, the positional kickoff, and that the kickoff is accepted rather
  than stranded — and they drive level resolution from their own fixtures.

  Background:
    Given a repository whose config.json resolves a level to some model
    And a scratch level mapping whose model id and thinking level are
      written nowhere else in the repository

  Scenario: Identify the positional kickoff whatever options the launch line carries [REQ-1]
    Given a pi stub that parses its own argv
    When it is handed a launch line whose --model and --thinking values are not the message
    Then the stub reports the positional message as the kickoff

  Scenario: Accept the kickoff under the repository's shipped mapping [REQ-2]
    When sub-spawn.sh spawns a child with the repository's own levels config
    Then the child reports the positional kickoff accepted, not stranded

  Scenario: Accept the kickoff under an arbitrary level mapping [REQ-3]
    When sub-spawn.sh spawns a child whose level maps to a made-up model id
    Then the resolved launch options carry that model id
    And the child still reports the positional kickoff accepted

  Scenario: Keep the launch-line suites green under a mutated mapping [REQ-4]
    Given the level mapping is replaced by the scratch mapping
    When every suite that builds or parses a child launch line runs
    Then no suite fails
    And the scratch mapping is what resolves the child's launch options
    And the scratch mapping's model id is written nowhere else in the repository

  Scenario: Keep the changed scripts shellcheck- and bash -n-clean [REQ-5]
    When shellcheck and bash -n run over the changed scripts and tests
    Then both report no finding