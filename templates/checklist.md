# <ticket> ordered test checklist

Run ID: <value>
startedUtc: <capture before preflight; preserve across resumptions>
completedUtc: <capture after final verification and report/evidence preparation>
totalRunSeconds: <completedUtc minus startedUtc; includes waits and all run work>
Timing gaps / separately measured waits: <None, or explicit limitations>
Application / authorized environment / test scope: <nonsecret values>
Source revision / runtime confirmation: <value>
Plan: <required> required + <additional> additional = <total> distinct tests
Scope decision: <automatic: <=5 additions, or user's explicit selection>
Desired final state: <from the target application's AGENTS.md and workspace's .agents/skills/peer-review/hints.local.md>

## Additional tests proposed

1. <A-01: scenario, reason tied to changed behavior, intended layer>

Use None when there are no additions. Tests omitted by scope selection keep NOT TESTED and the reason.

## Ordered work

- [ ] P-01 — Read ticket and relevant diff/callers; reconcile expected behavior. Status: NOT STARTED.
- [ ] P-02 — Verify/start only required services, runtime and read-only smoke check. Status: NOT STARTED.
- [ ] P-03 — Snapshot recovery state, delivery isolation and final defaults. Status: NOT STARTED.
- [ ] P-04 — Publish consolidated pre-flight summary in chat with readiness, counts/additions and blockers; resolve the >5 scope question. Status: NOT STARTED.
- [ ] R-01 — <required scenario; expected result; layer; role/configuration; dependencies>. Status: NOT STARTED. Evidence: <relative link>. Actual / next step: <value>.
- [ ] A-01 — <additional scenario; expected result; layer; role/configuration; dependencies>. Status: NOT STARTED. Evidence: <relative link>. Actual / next step: <value>.
- [ ] F-01 — Retain valid fixtures; resolve dirty/blocking data; remove temporary credentials and queued outgoing test messages. Status: NOT STARTED.
- [ ] F-02 — Apply desired final account state; restore transient settings/security/workers and verify independently. Status: NOT STARTED.
- [ ] F-03 — Close coverage, prepare report/evidence and Jira draft, record total run time and present formatted final summary with Bugs Found and timing at the top. Status: NOT STARTED.

Replace placeholders and expand test groups during preflight. Order real scenarios by dependencies, role and configuration, with positive controls first. A checked task has a recorded terminal outcome: PASS, FAIL or deliberately NOT TESTED. BLOCKED is unchecked; identify the missing dependency and next action. Record IN PROGRESS before mutations; link recovery snapshots. Setup/finalization tasks do not contribute to test counts.

## Resume and retained state

Last completed / next runnable task: <IDs>
Active fixture / original and applied nonsecret values / recovery path: <values>
Worker states / started service process IDs / unfinished restoration: <values>
Retained reusable records and any contamination to repair: <values>
Current blockers and scope questions: <values>
Updated UTC: <value>

## Bug candidates discovered during execution

Append new entries at the end; do not reorder completed work. Use None until a candidate is found.

- [ ] B-01 — <title>. Classification: CANDIDATE / CONFIRMED / DISPROVED.
  Expected / actual: <values>. Reproduction: <minimal steps>.
  Affected revision / code / evidence: <links>. Investigation/retest status and next action: <value>.

No credentials, API keys, cookies or queued activation/reset tokens belong in this file.
