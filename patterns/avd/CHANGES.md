# AVD Monitoring Baseline — Changes from the Original Microsoft Baseline

This fork of [Azure/azure-monitor-baseline-alerts](https://github.com/Azure/azure-monitor-baseline-alerts) (`patterns/avd`) is maintained independently because upstream development of the AVD pattern has gone stale. This document lists every functional change from the upstream baseline (upstream `main` as of commit `ba0266b3`, template v2.2.1) so users migrating from the original solution can see exactly what differs.

**Current version: v2.3.0** (2026-07-06)

---

## v2.3.0 (2026-07-06) — this fork

### 1. Available Memory alerts redesigned as log query alerts (fixes upstream [issue #656](https://github.com/Azure/azure-monitor-baseline-alerts/issues/656))

**Alerts affected:** `AVD-HostPool-VM-Available Memory Less Than 2GB` (Sev2), `AVD-HostPool-VM-Available Memory Less Than 1GB` (Sev1)

**Problem:** The original metric alerts on `Available Memory Bytes` fired false positives when a session host powered on (common with AVD autoscale). The platform emits a `0` sample as the VM starts, which the metric alert evaluated as "memory critically low".

**Change:** Both alerts were removed from the per-VM metric alerts and re-implemented as per-host-pool scheduled query (KQL) rules against the `Perf` table (`Memory / Available MBytes`, already collected by the AVD Insights data collection rule):

- The query averages available memory over the 15-minute window and only evaluates hosts whose **earliest sample in the window is at least 10 minutes old** — a host that just powered on has no such history and is skipped, eliminating the startup false positives.
- Results are joined (inner) to `WVDAgentHealthStatus` so only session hosts belonging to the alert's host pool are evaluated.
- Thresholds are unchanged in intent: ≤ 2048 MB (Sev2) and ≤ 1024 MB (Sev1).
- Dimensions: `ComputerName`, `VMresourceGroup`, `HostPool`.

**Data prerequisite:** the query reads the `\Memory\Available Mbytes` performance counter from the `Perf` table. This counter is part of the standard AVD Insights data collection rule (`microsoft-avdi-<region>`) counter set, so **no additional configuration is needed if you deployed the default AVD Insights DCR**. If you use a custom DCR, ensure it collects `\Memory\Available Mbytes` (any sampling interval of 60s or less is fine). The join also requires host pool diagnostic settings to be enabled (populates `WVDAgentHealthStatus`), which the baseline already requires for its other alerts.

**Migration note:** if you previously deployed the baseline, the old *metric* alert rules named `*-HP-VM-AvailMemLess-1GB/2GB-*` in your VM resource groups are no longer managed by this template and should be deleted manually. The replacement scheduled query rules are created alongside the other host-pool log alerts.

### 2. Health Check Failure alert — health-check map extended

**Alert affected:** `AVD-HostPool-VM-Health Check Failure` (`*-HP-VM-HlthChkFailure-*`)

The `MapToDesc` function in the KQL query only mapped health-check indices 0–10; newer AVD agent health checks were reported as `InvalidIndex` and therefore **excluded** from alerting. Added:

- `idx == 11` → `TURNRelayAccessHealthCheck`
- `idx == 19` → `AADJoinedHealthCheck`

### 3. FSLogix "Profile Disk Attached to another VM" alert — profile path and user surfaced

**Alert affected:** `AVD-HostPool-VM-FSLogix Profile Disk Attached to another VM` (`*-HP-VM-FSLgxProf-DskInUse-*`)

The Event ID 51 query now extracts the profile disk path from the event's `ParameterXml`:

```kusto
| extend ProfilePath = extract(@"<Param>([\\\\][^<]+\.VHDX?)<\/Param>", 1, ParameterXml)
```

`ProfilePath` and `UserName` are included in the query output and added as alert dimensions, so a fired alert immediately identifies **which user's profile disk** (and which VHD/VHDX path) is locked, without opening the session host's event log.

Dimensions are now: `ComputerName`, `RenderedDescription`, `UserName`, `ProfilePath`, `VMresourceGroup`, `HostPool`.

### 4. High CPU 85 Percent alert re-tuned

**Alert affected:** `AVD-HostPool-VM-High CPU 85 Percent` (`*-HP-VM-HighCPU-85-Prcnt-*`, Sev2)

Evaluation cadence changed from **every 5 minutes over a 15-minute window** to **every 30 minutes over a 1-hour window**. A session host averaging over 85% CPU for a full hour is a genuine capacity signal; brief spikes (logon storms, app launches) previously produced noisy Sev2 alerts. The Sev1 `High CPU 95 Percent` alert is unchanged (every 5 minutes over 15 minutes) so critical CPU exhaustion still alerts quickly.

### 5. Version bump

`AlertDescriptionHeader` and docs updated from v2.2.2 to v2.3.0.

---

## v2.2.2 — adopted from upstream [PR #839](https://github.com/Azure/azure-monitor-baseline-alerts/pull/839) (unmerged upstream)

Upstream PR by [@fbloemhof](https://github.com/fbloemhof), merged into this fork:

1. **FSLogix queries: `leftouter` join changed to `inner` join** against `WVDAgentHealthStatus` filtered on the host pool. The left-outer join returned events from session hosts in *other* host pools (with empty `HostPool`), producing duplicate/incorrect alerts when multiple host pools shared a workspace.
2. **`UserName` added** to the FSLogix alert outputs and dimensions.
3. **Misplaced-space fix** in the `HP-VM-HlthChkFailure` query.
4. Version bump 2.2.1 → 2.2.2.

### Fixes upstream [issue #812](https://github.com/Azure/azure-monitor-baseline-alerts/issues/812) — "Cannot deploy template, 'LogAlertsStorage' is not valid"

Upstream `avdArm.json` contained four malformed expressions in the `LogAlertsStorage` variable:

```text
parameters('AlertNamePrefix', uniqueString(subscription().displayName))   // invalid — parameters() takes exactly one argument
```

These caused every portal deployment to fail validation with `InvalidTemplate: The template language function 'parameters' must have only one parameter`. The `avdArm.json` in this fork is regenerated directly from `templates/deploy.bicep` (Bicep CLI 0.44.1) and contains the correct form:

```text
format('{0}-StorLowSpaceAzFile-15PrcntRem-{1}', parameters('AlertNamePrefix'), uniqueString(subscription().displayName))
```

**Verified:** zero occurrences of the malformed pattern remain in the generated template, and the template parses as valid JSON with an unchanged parameter surface (19 parameters, fully compatible with `avdCustomUi.json`).

---

## Deploying

The solution deploys the same way as the original, via the custom deployment blade. The Deploy-to-Azure link is below (adjust `durrante/AVDMonitoringBaseline/main` if the repo is published under a different name):

```text
https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdArm.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdCustomUi.json
```

Note: `avdArm.json` is generated from `templates/deploy.bicep`. Do not edit it by hand — edit the Bicep and rebuild:

```text
bicep build templates/deploy.bicep --outfile avdArm.json
```
