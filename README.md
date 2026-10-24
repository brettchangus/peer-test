# peer-test

**Evidence-driven peer testing for Codex.**

`peer-test` turns Jira Peer Testing instructions and the relevant code changes into an ordered test plan, local evidence, and a concise report. It combines browser checks, declarative API assertions, and optional MAUI iOS simulator automation while keeping application settings and credentials in the application workspace.

The repository includes the skill, reusable PowerShell and Python helpers, synthetic configuration examples, and report templates. Ticket-specific investigation and browser interaction run through Codex; the helpers can also be used directly for API replay and local validation.

## Features

- **Ticket-driven coverage.** Turn Jira Peer Testing instructions and code changes into required scenarios and targeted regression checks.
- **Web and native UI testing.** Exercise browser flows or MAUI iOS simulator screens, with API checks for contracts and persistence.
- **Declarative API assertions.** Check response fields, counts, nulls, patterns, and expected errors; replay saved responses without live requests.
- **Resumable execution.** Keep an ordered checklist with outcomes, evidence, blockers, and recovery notes across interruptions.
- **Application-specific setup.** Select workspace-local environments, account roles, selectors, and optional Mac profiles.
- **Guarded test fixtures.** Apply allowlisted local SQL changes with baseline checks, recovery backups, and verified restoration.
- **Clear reporting.** Produce local coverage summaries, confirmed findings, limitations, and whole-run timing while keeping credentials and evidence out of Git.

## Contents

- [Features](#features)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [API testing](#api-testing)
- [MAUI iOS simulator](#maui-ios-simulator)
- [Output](#output)
- [Security and privacy](#security-and-privacy)
- [Development](#development)
- [License](#license)

## How it works

1. Read the Jira ticket, Peer Testing instructions, relevant changes, and application guidance.
2. Validate the selected environment, account role, service readiness, and source/runtime alignment.
3. Create an ordered checklist covering required scenarios and justified regression cases.
4. Run checks through the appropriate browser, API, or simulator layer and record each outcome with evidence.
5. Verify the required final application state and prepare a report with findings, coverage limits, and total elapsed time.

The checklist survives interruptions so testing can resume from the first unfinished case. Results distinguish **PASS**, **FAIL**, **BLOCKED**, and **NOT TESTED**. A successful UI action or a passing replay is evidence for that operation, not proof that the entire ticket passes.

Jira comments, attachments, commits, pushes, and other external records require explicit authorization. Reports remain local until shared deliberately.

## Requirements

| Component | Needed for |
|---|---|
| Codex with skill support and browser tools | Ticket investigation, planning, browser checks, and reporting |
| Atlassian MCP connection with access to the selected project | Jira ticket access; an authorized browser session can serve as a fallback |
| PowerShell 7.4 or later (`pwsh`) | The documented PowerShell commands and helper checks |
| Python 3.9 or later | The standard-library-only Appium and MAUI helpers and tests |
| Git | MAUI source fingerprints and source archive verification |
| Local application and test accounts | Live testing in an authorized environment |

The SQL fixture helper additionally needs a local SQL Server or LocalDB database using integrated authentication and an application `Web.config`. The service helper targets IIS Express on Windows. Neither is required for replay-only API checks.

Native iOS testing additionally requires a Mac with compatible Xcode, an iOS simulator runtime, .NET MAUI tooling, Appium, and the XCUITest driver. See [infrastructure setup](references/ios-setup.md) before configuring that workflow.

## Installation

Clone or download this repository, then copy the skill and its supporting files into your local skill directory. From the repository root in PowerShell:

```powershell
$destination = Join-Path $env:USERPROFILE '.agents/skills/peer-test'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
Copy-Item -Path SKILL.md, README.md, LICENSE, scripts, examples, plans, references, templates `
    -Destination $destination -Recurse -Force
```

This copies the skill files without Git metadata. Repeating it overwrites matching installed files; review any local customizations first. Application settings and ticket evidence belong in the application workspace, independently of the installed skill location.

## Usage

In Codex, select the application workspace and invoke:

```text
Use $peer-test to test APP-1234.
```

Replace the example key with the actual Jira ticket. Include the environment or account role when overriding the application's defaults.

### Example requests

| Use case | Example prompt |
|---|---|
| Let the ticket determine coverage | `Use $peer-test to test APP-1234.` |
| Web UI | `Use $peer-test to test APP-1234 in the web application using the configured standardUser account.` |
| Native iOS | `Use $peer-test to test APP-1234 in the MAUI app on the configured iOS simulator.` |
| API only | `Use $peer-test to test the API behavior for APP-1234 against the configured local environment. Report UI scenarios as not tested.` |
| Replay saved API evidence | `Use $peer-test to replay the saved API plan and responses for APP-1234 without making live requests. Report this as replay validation.` |
| Resume an interrupted run | `Use $peer-test to resume APP-1234 from its saved checklist and continue the unfinished cases.` |

Replace the ticket, role, and environment with values from the selected application workspace. For replay, identify the saved plan and response directory when they are not clear from the ticket history.

Codex chooses test layers from your request, the ticket, changed code, and application guidance. An iOS profile supplies native execution settings; its presence does not select iOS automatically. The `browser` setting chooses the browser for web checks. State the platform explicitly when the ticket could apply to more than one, and clarify conflicting requirements before execution.

### First-run setup

Before the first run, initialize settings from the repository or installed skill directory:

```powershell
./scripts/Initialize-Settings.ps1 -WorkspacePath 'C:\path\to\application'
```

The initializer creates a credential-free example if settings are absent and returns `NeedsConfiguration`. Complete that local file, then set `configured` to `true`. The workflow validates the chosen environment and account before testing; the initializer does not certify application readiness.

## Configuration

Each application owns its configuration under:

```text
<application-workspace>/
  .agents/skills/peer-review/
    settings.local.json       environment, local accounts, and optional adapters
    hints.local.md            optional nonsecret application testing guidance
    .history/<ticket>/        checklist, plans, evidence, and report
```

The `peer-review` directory name is the existing workspace storage convention; the installed skill is named `peer-test`.

Start with [settings.example.json](examples/settings.example.json). Keep its structure, supply only the environment and roles you need, and use the application's `AGENTS.md` for startup instructions and the desired final state. Settings include local passwords in plaintext; protect the file with appropriate filesystem access and keep it out of source control.

Optional fragments are provided for [SQL fixtures](examples/fixture.example.json), [iOS sessions](examples/ios.example.json), [MAUI metadata](examples/maui.example.json), and a [shared Mac profile](examples/maui-machine.example.json). Merge relevant fragments into the application settings; they do not replace the main configuration.

## API testing

The API runner accepts declarative JSON plans. [example-search.json](plans/example-search.json) is a synthetic, replay-only format example; real ticket plans belong in the application's ignored history directory.

```powershell
# Supply paths to a verified plan, existing replay files, and a new output directory.
./scripts/Invoke-PeerTest.ps1 -PlanPath $planPath `
    -ReplayDirectory $replayDirectory -OutputDirectory $outputDirectory

# Live credential-based testing; the password is supplied in memory.
$credential = Get-Credential
./scripts/Invoke-PeerTest.ps1 -PlanPath $planPath `
    -OutputDirectory $outputDirectory -Credential $credential
```

Live requests require loopback HTTPS and valid TLS. Credential-based plans support POST. API-key plans support GET or POST and accept an in-memory `SecureString` through `-ApiKey`. Redirects are disabled.

Cases support counts, field comparisons, explicit null checks, presence checks, and text patterns. The default response mode checks HTTP 200 and `ResultCode=0`; raw mode supports JSON or text with an explicit expected HTTP status. Case IDs must be unique safe filenames, and `results` is reserved regardless of capitalization.

Each response is saved with its HTTP status and body. Replay checks saved evidence without contacting the application; it does not prove current application behavior. A nonzero exit code means at least one case failed or was blocked.

For response formats, fixture recovery, service startup, and detailed examples, see the [workflow guide](references/workflow-guide.md).

## MAUI iOS simulator

The optional native adapter supports workspace-bound sessions, reusable verified source archives, app-specific selectors and flows, batched actions, system-alert detection, and compact UI observations.

```powershell
python scripts/maui_peer.py preflight --workspace 'C:\path\to\application' --offline
```

Start with the [routine simulator workflow](references/ios-simulator.md). Use [infrastructure setup](references/ios-setup.md) when the Mac, simulator, or Appium environment is missing or unhealthy.

Preflight and source snapshots do not prove that an installed app matches the reviewed source. Verify build and installed-artifact provenance before relying on live results. Android, native Windows, and physical-device execution adapters are outside the current implementation.

## Output

The ticket history directory contains the consolidated checklist, coverage, findings, and report. API batches use separate subdirectories:

```text
.history/APP-1234/
  checklist.md                ordered scenarios and resumable progress
  report.md                   ticket report and verified findings
  <api-batch>/
    results.json              case outcomes, requests, assertions, and runner time
    report.md                 API batch report
    <case-id>.json            redacted response evidence
```

Templates also provide a preflight summary and a compact final chat summary. Whole-run time includes setup, testing, investigation, waits, recovery, and reporting; API runner time is recorded separately. Findings and coverage limits remain explicit when a run cannot finish.

## Security and privacy

- Keep account settings, local hints, ticket data, response evidence, simulator captures, source archives, logs, and recovery backups out of public repositories. The included ignore rules cover the documented local storage paths and common generated artifacts.
- Load credentials into memory for testing. Do not put them in command arguments, API plans, screenshots, report text, or Jira attachments.
- API responses redact credential-like properties and exact supplied secret strings. Native observations redact configured credentials, and the higher-level adapter suppresses screenshots when it detects a password field or value. These protections do not remove arbitrary personal or business data; review evidence before sharing it.
- The low-level Appium client writes requested hierarchy and screenshot captures directly. Treat those files as sensitive. Keep Appium bound to loopback and use verified SSH forwarding when connecting to a Mac.
- SQL fixtures use configured table and column allowlists, expected values, local database checks, and guarded restoration. Use a dedicated test scope, retain recovery backups locally, and investigate restoration conflicts before retrying.
- Browser tests, API calls, and fixture helpers can change application data. Test only authorized environments and verify the final state required by the application guidance.

The repository ships synthetic examples and empty account fields. It does not include application credentials or ticket evidence.

## Development

```text
SKILL.md       Codex workflow and routing instructions
scripts/       runners, configuration helpers, and local checks
examples/      synthetic configuration fragments
plans/         synthetic API plan format
references/    detailed workflow and simulator setup
templates/    checklist, preflight, and report formats
```

Run the local helper checks from the repository root:

```powershell
$checks = Join-Path ([IO.Path]::GetTempPath()) ('peer-test-' + [guid]::NewGuid().ToString('N'))
pwsh -NoProfile -File scripts/Test-Runner.ps1 -OutputDirectory (Join-Path $checks 'runner')
pwsh -NoProfile -File scripts/Test-Settings.ps1 -OutputDirectory (Join-Path $checks 'settings')
pwsh -NoProfile -File scripts/Test-Fixture.ps1 -OutputDirectory (Join-Path $checks 'fixture')
pwsh -NoProfile -File scripts/Test-FixtureOutcome.ps1 -OutputDirectory (Join-Path $checks 'fixture-outcome')
python -B scripts/test_ios_appium.py
python -B scripts/test_maui_peer.py
```

These checks use synthetic data, temporary workspaces, and local test doubles. The Appium protocol tests start a temporary loopback HTTP server; they do not contact an application or simulator. Fixture validation does not open a database connection. Passing these checks does not replace live validation for a configured application.

## License

Released under the [MIT License](LICENSE).
