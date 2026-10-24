# <ticket> peer-test report

**Result:** <PASS / FAIL / INCOMPLETE> | **Total run time:** <duration, or unavailable with timing gap>

<One sentence explaining the outcome.>

| Coverage | Planned | **✅ PASS** | **❌ FAIL** | BLOCKED | NOT TESTED |
|---|---:|---:|---:|---:|---:|
| Required | <count> | <count> | <count> | <count> | <count> |
| Additional | <count> | <count> | <count> | <count> | <count> |
| Total | <count> | <count> | <count> | <count> | <count> |

**Findings:** <unique confirmed bug count; identify pre-existing findings>
**Final state:** <restoration/account readiness or incomplete items>
**Limitations:** <material gaps, or None>

Environment / test scope / account role: <nonsecret values>
Source revision / runtime confirmation: <verified or explicitly unverified>
Native target (when applicable): <simulator model/runtime/UDID; Xcode/Appium/driver versions; installed app/build; physical-device coverage limits>
Scope decision: <automatic or selected scope and omissions>
Timing: startedUtc <value>; completedUtc <value>; totalRunSeconds <value>. Include setup through report preparation and user waits. Identify partial timing explicitly. Runner time: <separate value if measured>.
Checklist: [ordered checklist](checklist.md)

## Required tests

| ID | Scenario | Result | Evidence / limitation |
|---|---|---|---|
| R-01 | <scenario> | <**✅ PASS** / **❌ FAIL** / BLOCKED / NOT TESTED> | <relative link> |

## Additional tests

<None, or table with the same columns and reason for each addition.>

## Bugs Found

<None found, or confirmed bugs with stable checklist bug ID, severity, expected/actual behavior, minimal reproduction, affected code/revision and evidence.>

## Unresolved observations and blockers

<None, or candidate findings, requirements conflicts, environment blockers and exact next actions. Do not call a candidate a confirmed bug.>

## Final state and retained data

<Verified configured account state, feature access and limits, transient settings/security/workers, removed temporary credentials/outgoing test messages, retained valid fixtures, and any incomplete restoration. Link evidence.>

## Coverage and measurements

<Layers tested and their limits; delivery versus queue acceptance; required omissions. Whole-run elapsed time and actual requests; runner metrics separately. Token usage only if available. No invented savings.>

<Local draft only. Do not post to Jira without user authorization.>
