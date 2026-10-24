# MAUI iOS infrastructure setup (load only when needed)

Use the ordinary ticket preflight, scope, checklist, timing, recovery and report workflow. This adapter supplies native UI actions, not a replacement test plan or an automatic PASS. Setup alone does not prove a ticket. Simulator coverage does not establish real-device camera, notification delivery or background behavior.

## Mac setup

The Mac needs Xcode with an installed iOS simulator runtime, a .NET 10 SDK and compatible MAUI/iOS workload, Node/npm, Appium and its XCUITest driver. Inspect before installing or upgrading:

```sh
sw_vers
uname -m
xcode-select -p
xcodebuild -version
xcrun simctl list devices available
dotnet --info
dotnet workload list
node --version
npm --version
appium --version
appium driver list --installed
```

Match Xcode to the installed .NET iOS workload and simulator runtime; do not blindly upgrade an existing development setup. For a missing Appium installation, choose compatible versions from the official requirements below, then install using explicit versions:

```sh
npm install -g appium@<verified-version>
appium driver install xcuitest@<verified-version>
appium driver doctor xcuitest
```

Install missing Xcode runtimes through Xcode Settings. If the MAUI workload is absent, use the selected .NET 10 SDK's `dotnet workload install maui` according to the Mac's SDK installation permissions. Record the resolved versions. A real device/signing setup is not required for this simulator workflow.

Start the server in a Mac terminal, with request-body logging suppressed (typed passwords otherwise appear in Appium debug logs):

```sh
appium --address 127.0.0.1 --port 4723 --log-level error
```

Do not enable debug logging while entering credentials. Server logs are not automatically safe to attach to reports.

From Windows, use an SSH tunnel in a separate terminal (replace host/user):

```powershell
ssh -i "$env:USERPROFILE\.ssh\id_ed25519_peer_test_mac" -N -o ExitOnForwardFailure=yes -L 4723:127.0.0.1:4723 <mac-user>@<mac-host>
```

Verify the Mac's host key before accepting a new key. Do not disable host-key checking. If the local port is occupied, choose another local port and set `ios.serverUrl` accordingly. The client only accepts loopback origins and refuses redirects. The existing API runner's HTTPS and loopback restrictions are unchanged.

## Application build and install

Read the Mac checkout's AGENTS.md. Build/test authorization must follow the current user request and repository guidance. Confirm source parity with the reviewed changes, including uncommitted files; matching commits alone is insufficient. Do not overwrite Mac working changes or copy credentials. Run from the Mac's selected application checkout:

```sh
# Apple Silicon; Intel Macs use iossimulator-x64 instead.
dotnet build MyApp/MyApp.csproj -f net10.0-ios -c Debug -r iossimulator-arm64
```

Choose an available simulator UDID from `xcrun simctl list devices available`. Boot it only if shut down. Replace placeholders with actual values:

```sh
xcrun simctl boot <UDID>
xcrun simctl bootstatus <UDID> -b
xcrun simctl install <UDID> MyApp/bin/Debug/net10.0-ios/iossimulator-arm64/MyApp.app
xcrun simctl get_app_container <UDID> com.example.myapp app
```

Verify the actual output path before installation. Use a simulator-built `.app`, not a device IPA. Record revision, working-tree differences, build time, app version/build and install result. Retain build logs separately from credentials. Never erase a simulator or uninstall/reset an app as routine setup.

The backend origin must be reachable from the simulator. A Windows loopback URL does not point at Windows from the Mac. Use a deliberately configured reachable test endpoint with valid TLS, or an explicitly configured tunnel with correct hostname/certificate handling. Do not rewrite the selected API client endpoints automatically or disable certificate validation.

## Local configuration and preflight

Run `scripts/Initialize-Settings.ps1 -WorkspacePath <application-workspace>` and complete the normal workspace settings. Merge `examples/ios.example.json` as an `ios` property in that settings file; preserve existing values. It is a profile fragment, not a replacement for accounts/environment settings. Fill simulator UDID, Mac checkout/app path, and backend origin; set `configured` true only after required values are supplied. Keep secrets out of this fragment. The client receives a command on stdin; the skill reads the selected settings in memory and constructs commands.

Before login or UI mutation, verify the UDID is an available simulator, app installed/build parity, Appium readiness, reachable authorized backend, selected account/test scope, and current login/event state. `start` launches the app and preserves its data. It does not install, build, boot, reset, or attest to source parity. The client does not enforce workspace/account scope; the skill's preflight must do that before invoking it.

## Native commands

Python 3 (stdlib only) runs this client on Windows or Mac. Use `python` on Windows or `python3` on Mac. Send one JSON command on stdin and read one JSON result. Example in PowerShell:

```powershell
'{"action":"status"}' | python scripts/ios_appium.py
# Use the configured UDID, after preflight:
@{action='start';udid=$settings.ios.udid;bundleId=$settings.ios.bundleId} |
  ConvertTo-Json -Compress | python scripts/ios_appium.py --server $settings.ios.serverUrl
```

Save the returned `value.sessionId` in nonsecret resume notes. Subsequent commands require `sessionId`:

| Action | Additional properties | Result |
|---|---|---|
| source | output (new XML path) | Native hierarchy saved locally |
| screenshot | output (new PNG path) | Screenshot saved locally |
| find | locator | Element identifier |
| wait | locator, optional timeoutSeconds (0–60) | Visible element found |
| tap | locator | Tap performed; verify resulting UI separately |
| type | locator, text, optional clear | Text entered; never put secrets in argv/history |
| text | locator | Element text; may contain personal information |
| scroll | direction (up/down/left/right) | Scroll performed |
| stop | none | Delete automation session; does not clear app data |

Locators have `using` and `value`. Prefer `{"using":"accessibility id","value":"<observed AutomationId>"}`. Inspect hierarchy first; no invented selectors. Supported alternatives are `-ios predicate string`, `-ios class chain`, and `xpath`. Add stable MAUI AutomationId values only to relevant controls when needed, following application coding guidance; rebuild before testing them. Capture initial hierarchy to discover existing labels before deciding that app changes are necessary.

For login, load credentials from workspace settings into process memory and pipe a constructed `type` command. Never write credential commands to files or paste literal passwords into shell commands. Avoid screenshots/source capture while credentials are visible; XML and screenshots are not automatically redacted. Save evidence only under the ticket history directory, review/redact before sharing, and create output directories before capture. Existing evidence paths are never overwritten.

Record expected/actual outcomes in the normal checklist immediately. A successful tap is not a passing scenario. Verify the resulting UI state and relevant persistence independently. On interruption, inspect the existing session/state before resuming. Delete the owned session when finished; do not shut down another user's simulator or Appium server.

For diagnostics, collect a bounded simulator log interval for the app process using `xcrun simctl spawn <UDID> log show --last 2m --predicate 'process == "<app-process>"'`, reviewing for sensitive content before saving. Transport/session failures are BLOCKED pending diagnosis; a reproducible unmet product expectation is a potential FAIL, not automatically a confirmed bug.

Report platform, simulator model/runtime/UDID, Xcode/Appium/driver versions, source/build provenance, backend origin, and coverage limitations. Keep Windows/Android/physical-iPhone checks NOT TESTED unless actually exercised. UI helper output never overwrites the ticket report.

## References

- [Microsoft MAUI Appium guidance](https://learn.microsoft.com/en-us/dotnet/maui/deployment/ui-testing?view=net-maui-10.0)
- [Appium Node/server requirements](https://appium.io/docs/en/latest/quickstart/requirements/)
- [XCUITest compatibility and doctor](https://appium.github.io/appium-xcuitest-driver/latest/getting-started/system-requirements/)
- [MAUI iOS workload releases / Xcode requirements](https://github.com/dotnet/macios/releases)
