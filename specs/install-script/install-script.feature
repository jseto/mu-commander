Feature: dependency installer for mu-commander

  README.md's Installation section documents the tools mu-commander needs
  (bash, git, tmux, treehouse, pi, jq, realpath, gh, common coreutils, and
  shellcheck), but a fresh machine only learns what is missing by running a
  helper and reading its "missing command" error. A single installer,
  `install.sh` at the repository root, detects which required tools resolve
  on PATH and installs only the ones that are missing: system packages
  through the platform's package manager (apt/dnf/pacman/Homebrew), the
  non-packaged tools through their verified upstream install paths
  (treehouse from its GitHub release, pi through npm), and shellcheck by
  delegating to the pinned install already in scripts/worktree-setup.sh so
  the repository keeps a single source of truth for that pin. The installer
  is idempotent and non-destructive: it never overwrites an existing tool,
  prints per-tool manual hints instead of silently skipping anything it
  cannot install, ends with a three-bucket summary (installed / already
  present / needs manual action), and exits 0 only when every dependency
  resolves on PATH at the end of the run.

  Scenario: No-op run when every dependency is present [REQ-1]
    Given a system where every required tool resolves on PATH
    When the installer runs
    Then it reports that all dependencies are already present
    And it invokes no package manager, downloader, or installer
    And it exits with status 0

  Scenario: Install only the missing system tools through the detected package manager [REQ-2]
    Given a system where some required system tools are missing from PATH
    And one of apt-get, dnf, pacman, or Homebrew is available
    When the installer runs
    Then it invokes that package manager exactly once
    And the invocation carries exactly the packages for the missing tools,
      named with that platform's package names
    And it prefixes the invocation with sudo only when the effective user is
      not root and sudo is available
    And every installed tool is re-checked with "command -v" afterwards
    And each re-checked tool is reported as installed

  Scenario: Per-tool manual hints when no package manager applies [REQ-3]
    Given a system where some required system tools are missing from PATH
    And no supported package manager is available for them
    When the installer runs
    Then it prints a manual-install hint naming each missing tool
    And it continues with the remaining dependency categories instead of
      aborting
    And the uninstalled tools are reported under "needs manual action"

  Scenario: Install treehouse from its official GitHub release [REQ-4]
    Given treehouse is not on PATH
    And a downloader (curl or wget) is available
    When the installer runs
    Then it resolves the latest release of kunchenguid/treehouse
    And it downloads the tarball for the current operating system and
      architecture and verifies it against the release's checksums.txt using
      sha256sum or shasum
    And it installs the treehouse binary into ~/.local/bin
    And it re-checks treehouse with "command -v" and reports it as installed

  Scenario: Never overwrite an existing tool at its install path [REQ-5]
    Given treehouse is not on PATH
    And ~/.local/bin/treehouse already exists
    When the installer runs
    Then the existing file is left byte-for-byte unchanged
    And no release download is performed
    And it prints a hint to add ~/.local/bin to PATH
    And treehouse is reported under "needs manual action"

  Scenario: Install pi through the verified npm global command [REQ-6]
    Given pi is not on PATH
    And npm is available
    When the installer runs
    Then it runs "npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
    And it re-checks pi with "command -v" and reports it as installed

  Scenario: Instruct how to install pi when Node/npm is missing [REQ-7]
    Given pi is not on PATH
    And npm is not available
    When the installer runs
    Then it prints instructions naming the Node.js requirement (22.19 or
      newer), the verified npm install command, and the official pi installer
      as the alternative
    And it continues with the remaining dependency categories
    And pi is reported under "needs manual action"

  Scenario: Provision shellcheck through the shared pinned install [REQ-8]
    Given shellcheck is not on PATH
    When the installer runs
    Then it delegates to scripts/worktree-setup.sh, the repository's single
      pinned source of truth for shellcheck
    And the installer itself declares no shellcheck version or checksum
    And it re-checks shellcheck with "command -v" and reports the outcome,
      pointing at the shared install when it is still missing

  Scenario: Summarize outcomes and change nothing on a re-run [REQ-9]
    Given a system whose missing dependencies the installer can install
    When the installer runs
    Then it ends with a summary bucketing every dependency as installed,
      already present, or needs manual action
    And a second run reports every dependency as already present
    And the second run invokes no installer

  Scenario: Exit zero only when every dependency is present [REQ-10]
    Given any system state
    When the installer runs
    Then it exits with status 0 when every required dependency resolves on
      PATH at the end of the run
    And it exits with a non-zero status when any dependency is still missing,
      whether an install failed or manual action is required

