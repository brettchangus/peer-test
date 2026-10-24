# Detailed workflow guide

Invoke in Codex with **Use $peer-test to test APP-1234.** or in Claude Code with **/peer-test APP-1234**. Replace APP-1234 with the Jira ticket key. Include the application, test environment or account role when overriding the configured defaults.

The skill reads the ticket and relevant PR, plans required and justified regression cases, uses the browser for UI checks and runs declarative API assertions. It saves evidence and generates a compact report. Ticket-specific browser work still requires a host agent (Codex or Claude Code) with browser tools. Preflight, ordered checklist, test-scope decisions and final-state guidance are in [SKILL.md](../SKILL.md). Keep ticket-specific data and evidence in the Git-ignored .agents/skills/peer-review/.history/<ticket>/ directory; use the target application's existing AGENTS.md and/or CLAUDE.md for project guidance and .agents/skills/peer-review/hints.local.md for additional local testing guidance.

## MAUI iOS simulator support

Use the [routine MAUI workflow](ios-simulator.md) for any app and [infrastructure setup](ios-setup.md) only when needed. `scripts/maui_peer.py` provides one compact preflight, verified reusable source archives, workspace/app-bound sessions, batched UI actions, app-specific selector/flow aliases, credential references, system-alert detection, bounded screen diffs and local proof captures. It infers a single MAUI project and supports per-app overrides; it does not assume an application's bundle, API, accounts or screens. Optional shared Mac configuration is separate from each app's settings. Existing low-level Appium and browser/API runners remain supported.

Examples: [MAUI metadata](../examples/maui.example.json), [iOS profile](../examples/ios.example.json), [shared Mac profile](../examples/maui-machine.example.json). Routine reads do not automatically build, install, start services or certify source/runtime parity. Reuse builds only after proving source/config/toolchain and installed artifact match saved provenance. Full logs/evidence stay local; helper stdout is compact. Action success does not mean scenario PASS.

Offline checks: `python scripts/test_maui_peer.py` and `python scripts/test_ios_appium.py`. Live simulator validation requires application-specific accounts, backend settings and selectors. Android/Windows execution adapters are not implemented by this change.

## Local browser and accounts

Peer testing uses the host's browser tools: the background built-in browser (iab) in Codex; in Claude Code the desktop app's built-in browser pane, otherwise Claude in Chrome or a configured browser MCP. Local settings live at <workspace>/.agents/skills/peer-review/settings.local.json in the application workspace, independently of the installed skill location. Run scripts/Initialize-Settings.ps1 -WorkspacePath <workspace> from the skill directory. If settings are missing, the helper copies examples/settings.example.json there and returns NeedsConfiguration. Ask the user to configure the file before proceeding with tests, service startup, login or mutations. Existing settings are never overwritten. Fill required environment/account values and set configured to true; validate the selected settings before testing. Keep baseUrl scoped to authorized origins. Settings store passwords locally; never paste their contents into chat or evidence.

The agent reads the chosen account into memory for browser login. API testing converts the selected account into an in-memory PSCredential and passes it to the existing runner; the runner does not load this file automatically. Select the account role required by the ticket and the application's guidance; document application-specific role defaults in .agents/skills/peer-review/hints.local.md. Adapt the example account roles and scope settings to the selected application. Treat the test scope as reusable unless it is explicitly designated disposable; providing credentials alone does not authorize destructive tests or unrelated administration changes.

Each application workspace has its own settings.local.json; Jira ticket prefixes do not select settings. Explicit user-selected workspaces take precedence; ask if the workspace is ambiguous. The helper adds local ignore rules for settings.local.json, hints.local.md and .history/. Optional .agents/skills/peer-review/hints.local.md contains reusable local guidance beyond the workspace's AGENTS.md/CLAUDE.md; keep it credential-free and omit it when unnecessary. Run-specific data belongs in <workspace>/.agents/skills/peer-review/.history/<ticket>/. Resolve bundled scripts, templates and examples relative to the installed SKILL.md. Do not fall back to another workspace's accounts or old shared configuration.

## API plans

Use plans/example-search.json as a synthetic format example, then create the real ticket plan in .agents/skills/peer-review/.history/<ticket>/ with verified IDs, values and assertions. Credentials are prompted securely or supplied as an in-memory PSCredential. The runner never stores request bodies. Responses redact credential-like properties, but may contain business/contact information; keep evidence local.

Run scripts/Invoke-PeerTest.ps1 with PlanPath and OutputDirectory. ReplayDirectory validates saved response files without network access. A nonzero exit means a failed or blocked case. Passing replay validates the harness and historical evidence, not a current website.

## Temporary fixtures

Prefer existing records and browser settings when enough. Select a guarded fixture helper compatible with the application's data model. The current Invoke-LocalFixture.ps1 helper uses an explicit SQL table/column allowlist and expected local database destination from the fixture section of .agents/skills/peer-review/settings.local.json. Use examples/fixture.example.json as the shape of the optional fixture section and configure verified mappings for the application; supply -SettingsPath for every run and recovery. Supply -WebConfigPath to override the configured Web.config path. Other storage systems need a compatible helper. A fixture changes one record field from a known baseline:

```json
{"cells":[{"table":"Records","scopeId":1,"id":7,"column":"Status","expected":"Pending","value":"Active"}]}
```

Adapt this example to the selected helper's verified table and field mappings. The SQL helper requires explicit positive integer scope and record IDs. Every change needs an explicit expected baseline and replacement. Supply complete structured values where required; do not assume the helper infers mappings or converts field types.

```powershell
$fixtureHelper = Join-Path $skillDirectory 'scripts/Invoke-LocalFixture.ps1'
$runnerPath = Join-Path $skillDirectory 'scripts/Invoke-PeerTest.ps1'
& $fixtureHelper -SettingsPath $settingsPath -WebConfigPath $webConfigPath -ChangesPath $changesFile -BackupPath $newBackupFile -Test {
    & $runnerPath -PlanPath $planFile -OutputDirectory $evidenceDirectory -Credential $testCredential
}
# Guarded recovery after process termination:
& $fixtureHelper -SettingsPath $settingsPath -WebConfigPath $webConfigPath -RestoreBackupPath $backupFile
```

The current helper permits only the configured local database with integrated authentication and explicitly allowed tables and fields. Use -ValidateOnly -ChangesPath $changesFile with -SettingsPath to check configuration and mappings without opening a database connection. It writes a recovery backup before mutation, applies changes atomically, restores declared fields in finally, and verifies originals. Normal database triggers remain active, so LastUpdated timestamps advance. Concurrent changes cause a restoration conflict instead of overwriting someone else's work. Test exceptions and nonzero command exit codes are propagated after restoration; if testing and restoration both fail, both errors are retained. Process termination can prevent finally from running; retain the backup and use guarded recovery. Use a dedicated test scope and avoid concurrent editing during fixtures.

Keep historical replay plans with their ticket evidence in .agents/skills/peer-review/.history/<ticket>/. Build live plans per actual configuration state; the synthetic example is replay-only and proves no current application behavior.

## Measuring improvement

results.json records live request count, assertion count, mode and runner elapsed time. The overall browser/review time and actual agent token usage need separate measurement. Establish a baseline on the next ticket before estimating savings.

## Key GETs and expected errors

Existing plans remain credential-based POST with HTTP 200 and ResultCode=0 expected. Use an in-memory PSCredential for those. For public API tests, set plan auth to apiKey and pass -ApiKey as an in-memory SecureString. The runner uses the Authorization header directly; it never stores the key or follows redirects. TLS verification and loopback-only HTTPS remain enforced. Keys/credentials must not appear in plan fields or URLs.

A raw case can declare:

```json
{"id":"expected-error","method":"GET","endpoint":"/api/v1/records/7","responseMode":"raw","expectedStatus":400,"payload":{},"replayFile":"expected-error.json","assertions":[{"type":"Matches","path":"","pattern":"Expected error text"}]}
```

Revalidate the record ID and expected error contract. New evidence files in both response modes contain {"evidenceVersion":1,"statusCode":400,"body":"error text"}; replay preserves the recorded HTTP status. Existing raw files without evidenceVersion remain supported. Assertion paths refer to body, with empty path meaning the entire body. JSON objects/arrays and text are supported. Declare expectedStatus (default 200); ResultCode is checked only in resultCode mode. A resultCode case can also declare expectedResultCode for known business errors. Unexpected HTTP responses are FAIL; unavailable transport/evidence is BLOCKED. Expected errors are PASS only when status and declared body assertions match. Legacy replay files contain just the response body and assume historical HTTP 200; they cannot prove a rejection status.

SecureString limits accidental handling; it is not an encrypted evidence store. The runner redacts credential-like response properties and exact supplied secrets in returned text. Responses may still contain application data; keep them local. Prefer replay for harness validation, with one authorized read-only local smoke request for changed transport.

## Run tracking

Use one evidence directory and a coverage ledger for the whole ticket, not separate untracked batches. Update evidence/status immediately after each batch and keep nonsecret restoration/resume notes. Capture startedUtc before preflight and completedUtc after final verification and report/evidence preparation; preserve the original start across resumptions. Total wall-clock time includes setup, investigation, user waits, restoration and reporting. Put it at the top of the final chat summary, report and Jira draft; identify unavailable/partial timing explicitly. Track requests and restoration conflicts separately from runner time; actual token usage is optional if available. Do not claim measured savings without a comparable baseline. Do not mark a ticket incomplete while authorized, runnable required tests remain.
## Ordered runs and application setup

Read the workspace's AGENTS.md/CLAUDE.md and optional .agents/skills/peer-review/hints.local.md for verified service startup and desired final account state. Resolve settings and run data against the selected application workspace, including for installed skill copies. Follow the selected application's startup instructions. For applications hosted by IIS Express, scripts/Ensure-LocalService.ps1 starts only an absent service and leaves a listening/failing service for diagnosis. -ValidateOnly checks the configured site/path without network access or startup; -CheckOnly checks readiness without starting anything. Background workers can activate real jobs; follow the application's documented delivery isolation before starting them.

Create .agents/skills/peer-review/.history/<ticket>/checklist.md from templates/checklist.md during preflight. Review code/callers for missing scenarios, order by dependencies/roles/configuration and publish a consolidated pre-flight summary in chat using templates/preflight.md, showing readiness, environment, source/runtime, services, account readiness, isolation, blockers and required + additional counts. Itemize additions with reasons. Continue automatically with at most five additions; with more, ask for all tests, required only or a selected subset and record the answer before running tests. Count scenarios, not assertions/setup steps.

Update each checklist outcome and evidence immediately, record in-progress mutation/recovery state, and resume from the first runnable unfinished task. Append newly discovered bug candidates at the end. Use templates/report.md for the final ticket report and its Bugs Found section. Keep API runner reports in batch subdirectories so they cannot overwrite the full ticket report.

Retain valid reusable test data. Repair/remove dirty records that interfere with future runs; still remove temporary keys/outgoing test messages and restore security/workers/transient settings. Apply the selected app's desired final account state from its existing AGENTS.md/CLAUDE.md and .agents/skills/peer-review/hints.local.md, including subscription and limit requirements when applicable. A configured desired state may differ from the starting state. Record final-state evidence and any blocker.
