# MAUI iOS: routine ticket runs

Use this short path once infrastructure works. [ios-setup.md](ios-setup.md) is for initial setup or a diagnosed infrastructure failure, not every run. The same runner supports any MAUI app; project, bundle, backend, account, event scope, selectors and flows belong to that app's workspace profile. It currently drives iOS/XCUITest, not Android/Windows. Never claim another platform was tested.

## Profile once per application

Normal settings remain under `<workspace>/.agents/skills/peer-review/settings.local.json`, schemaVersion 1. Add optional `maui` metadata from `examples/maui.example.json` and the `ios` fragment from `examples/ios.example.json`. Existing `ios` profiles remain supported. Project/bundle/framework are inferred from a single MAUI csproj; set maui.projectPath for ambiguous solutions and explicit values for dynamic MSBuild properties. This reads XML; it does not fully evaluate MSBuild conditions/imports. Confirm inferred identity against the actual built/installed app. Set runtimeIdentifier for the Mac architecture.

An optional `ios.machineProfilePath` points at a shared local JSON (see `examples/maui-machine.example.json`). Only Mac/SSH/Appium/toolchain fields can be inherited. Workspace values override it. Account, app bundle, backend, event and selectors never inherit from another application. Keep the shared file outside source control and keep each app's account credentials only in its own settings. Do not copy credentials or scopes between applications.

Use ios.selectors as a map of app-specific names to observed `{using,value}` locators. Use ios.flows for deterministic, previously verified action lists such as login/logout. These are UI helpers, not universal test cases. Keep ticket-specific event names and assertions in the ticket plan. Prefer stable AutomationId; labels/predicates are a fallback. On app revision changes, verify needed selectors through focused observations/waits; rediscover only affected screens. Do not add AutomationIds to every screen preemptively.

## Compact preflight

```powershell
python <skill>/scripts/maui_peer.py preflight --workspace <workspace>
```

Returns project/framework/bundle, selected-role credential presence (no values), backend/scope, source fingerprint/head, Appium readiness and checks still needed. `--offline` makes no network calls. A preflight summary is not full readiness: the agent must still read Jira/PR, validate account/event/backend, simulator identity, final-state/isolation requirements and installed source parity. Missing credentials can be appropriate to guest-only cases; authenticated cases require the selected account. Setup/health is not a scenario PASS.

Use one Jira issue read through Atlassian MCP (evidence/custom-fields view), one focused PR metadata read, and the changed file plus callers. Save full responses locally and return a short summary. If Atlassian tools fail, inspect the single latest startup error, renew an invalid OAuth login (Codex: `codex mcp login atlassian`; Claude Code: ask the user to reauthenticate through `/mcp`), and verify a Jira read. Do not rerun doctor, enumerate every tool, generate protocol schemas or investigate unrelated logs on a healthy run. If the current chat's tools remain stale, report that exact limitation; do not install a second plugin. Use supported refresh/reconnect when available, then explain any browser fallback.

Check existing Appium/tunnel/API health once and repair only the missing component using profile/hints. A system alert can cover the screen while the app hierarchy still looks normal; the runner checks it separately. No automatic permission acceptance or blanket alert dismissal.

## Source snapshot and build reuse

```powershell
python <skill>/scripts/maui_peer.py snapshot --workspace <workspace> --output <workspace>/.agents/skills/peer-review/.history/<ticket>/source
```

Creates a hash-addressed archive/manifest or verifies and reuses the same archive. It includes tracked working files plus nonignored untracked files, excluding bin/obj and local agent/review metadata; it never commits. Symlinks and paths outside the workspace require an explicit build strategy. Snapshot contents are verified, so a stale filename cannot silently pass. Archive paths and source file contents stay local; stdout is compact. Never put credentials in source/overlays/profiles. If the app depends on ignored/external build inputs, explicitly include/record them in the build strategy; this snapshot is not sufficient by itself.

Cache app-specific build provenance locally: source fingerprint, config/endpoint overlay, actual SDK/workload/Xcode versions, dependency/restore inputs, built artifact hash and installed artifact hash. Reuse an installed build only after verifying all relevant inputs AND the current installed artifact; otherwise build/install a new isolated snapshot using the target project's instructions. Source snapshot reuse alone never authorizes skipping a required rebuild. Save full build logs to the ticket folder and return only summary/error tail. Preserve source newline state and unrelated developer edits; apply authorized endpoint overlays only for the intended config, record them, and retain TLS validation. Do not assume project name equals app bundle/process/output name.

## Sessions and batches

```powershell
python <skill>/scripts/maui_peer.py start --workspace <workspace> --ticket APP-123
python <skill>/scripts/maui_peer.py inspect --workspace <workspace> --ticket APP-123 --contains Dashboard
```

The session file lives in the ticket directory and is bound to workspace, server, bundle, simulator, environment and role. An unclosed session is never silently overwritten. Inspect/stop it before starting another. If the server lost the session, verify its absence and mark the local record closed before replacement. On interruptions read the ticket checklist first. Starting a session preserves app data; it does not build, boot, install or certify parity.

Send one JSON batch on stdin. For example, with selectors actually configured for this app:

```json
{"actions":[
  {"action":"type","selector":"login.email","credential":"email","clear":true},
  {"action":"tap","selector":"login.emailSubmit"},
  {"action":"wait","selector":"login.password"},
  {"action":"type","selector":"login.password","credential":"password","clear":true},
  {"action":"tap","selector":"login.passwordSubmit"},
  {"action":"expect","selector":"signedIn.root"}
],"capture":"signed-in"}
```

```powershell
Get-Content <ticket>/login-batch.json -Raw | python <skill>/scripts/maui_peer.py batch --workspace <workspace> --ticket APP-123
```

Credential references load only the selected workspace/account values into memory. Password references require a real SecureTextField. Never store literal credentials in command files, argv, reports or screenshots. Named flows use `{"flow":"login","capture":"signed-in"}` instead of actions. No source-code generation is needed per ticket.

Supported actions: tap/type/wait/scroll; `expect` waits for a visible element and optionally compares exact text. Use `locator` directly or a profile `selector`. Type supports clear and credential email/password. `alert-dismiss` requires expectedText to match the current system alert; choosing to dismiss/accept a permission remains a deliberate task decision. Accepting permissions is not automatic. For unusual commands, use the low-level ios_appium.py client.

One batch returns changed visible elements (bounded), separately detected system alert, completed action count, request count, duration and evidence links. The next inspect returns a diff, or `--contains` shows focused current elements. Full XML is written only with `--capture`; screenshots at distinct proof states only. Secure fields and selected credential strings are redacted from XML/output; screenshots are suppressed if a password field/value is detected. Review screenshots before sharing: arbitrary business data is not auto-redacted. Capture names are unique and existing evidence is never overwritten.

A successful action batch is not a passing scenario: verify expected state/persistence and immediately update the main checklist. ActionFailed/BlockedByAlert/EvidenceFailed are execution outcomes, not automatically confirmed bugs. Stop on a mismatch, inspect once, investigate, and retest affected steps only. native-batches.jsonl is supporting evidence, not a competing checklist or report. It counts Appium requests for this helper only; API/backend requests and whole-run time are separate.

```powershell
python <skill>/scripts/maui_peer.py stop --workspace <workspace> --ticket APP-123
```

Restore the app/account state required by the app guidance, then close only the owned session. Preserve healthy shared services/devices. Finish the normal report/Jira draft with platform/source provenance, required/additional counts, confirmed bugs/limitations and requested distinct screenshots. No Jira posting without authorization.
