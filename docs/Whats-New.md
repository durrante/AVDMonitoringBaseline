# What´s new

For information on what's new please refer to the [Releases](https://github.com/durrante/AVDMonitoringBaseline/releases) page and the [change log](../patterns/avd/CHANGES.md) page.

To update your current deployment with the content from the latest release, please refer to the [Update to new release](Update-to-new-Release.md) page.

## 2026-07-06 — v2.4.0 (this fork)

- **Host Pool Capacity alerts (50/85/95 Percent) fixed — they never fired.** The KQL parsed the load percentage with `toint()`, but the runbook reports a decimal (e.g. `68.5`); `toint()` on a decimal string returns `null`, so every threshold comparison silently failed. Switched to `toreal()`.
- **Host Pool Capacity alerts' resource link fixed.** `HPResourceId` was reading the wrong field index in the pipe-delimited runbook output, leaving alerts with no linked resource. Corrected the index.
- **More alerts now show the value that triggered them.** Available Memory alerts now include `AvailableMB`, Local Disk Free Space alerts now include `CounterValue` (percent free), and Low Space on Azure File Share alerts now include `PercentAvailable` — all previously computed but not surfaced in the fired alert.
- **Typo fix**: `AVD-ServiceHealth-Serivice Issue` corrected to `AVD-ServiceHealth-Service Issue`.
- Full details in the [change log](../patterns/avd/CHANGES.md).

## 2026-07-06 — v2.3.0 (this fork)

- **Available Memory alerts** converted from metric alerts to log query (KQL) alerts to stop false positives while session hosts power on (upstream [issue #656](https://github.com/Azure/azure-monitor-baseline-alerts/issues/656)).
- **Health Check Failure alert** now recognises health checks 11 (`TURNRelayAccessHealthCheck`) and 19 (`AADJoinedHealthCheck`).
- **FSLogix "Profile Disk Attached to another VM"** alert surfaces `UserName` and the profile disk `ProfilePath` in the alert dimensions.
- **High CPU 85 Percent** alert re-tuned: evaluated every 30 minutes over a 1-hour window (was every 5 minutes over 15 minutes) to reduce noise from short CPU spikes.
- **New optional `CustomerName` parameter** for MSPs: stamps `Customer: <name>` into every alert description so multi-tenant alert notifications are attributable to a customer (host pool names are often identical across tenants).
- Full details in the [change log](../patterns/avd/CHANGES.md).

## 2026-02-12 — v2.2.2 (adopted from upstream PR [#839](https://github.com/Azure/azure-monitor-baseline-alerts/pull/839))

- FSLogix queries: join corrected from `leftouter` to `inner` so results are filtered to the correct host pool (fixes duplicate alerts).
- Fixes the `LogAlertsStorage` template validation failure that blocked all portal deployments (upstream [issue #812](https://github.com/Azure/azure-monitor-baseline-alerts/issues/812)).

## 2024-12-18
Bug fixes [(See Known Issues Section)](Known-Issues.md)
Added option to select alternate subscription for Log Analytics and Storage as well as an initial prerequisites note on the first screen.

## 2024-12-10
### After 3/21/2024 Host Pool Capacity Alert Rule would not fire
An issue was discovered where the Automation Account Identity was not being assigned the Virtual Desktop Reader role on the Resource Group hosting all the AVD Resources. Thus, the output of the script was null which yielded no alerts, regardless of what the host pool capacity currently was. There was a condition on the role assignment that was adjusted so that it will be added at deployment.

Fix without Redeploying:
Simply assigning the identity tied to the Automation Account the Virtual Desktop Reader role on the Resource Group that houses the Host Pools.

## 2024-11-20
### Deployment Names over 64 characters
An issue was discovered in which the deployment for some alerts would fail if the deployment name was over 64 characters. This was due to the Storage Account and/or ANF Volume names being too long and appended to the deployment name. Those names are now truncated if over 20 characters.

## 2024-01-25
### New features
Initial relocation from the Azure AVD Accelerator Brownfield with AVD specific Alerts on a per Host Pool basis.
- Session Host monitoring both on performance, AVD agent health, storage, and fslogix profiles

### Bug fixes
#### ISSUE #221
(Fixed on 6/28/2024)

Storage calculation script in the runbook which was yielding a much higher remaining value than truly existed. Values were in the 99.xx% range vs actual for remaining meaning the alert may never trigger when remaining storage is truly low.

Runbook: AvdStorageLogData
Script: Get-StorAcctInfo.ps1 line 46

Was --- $RemainingPercent = 100 - ($shareUsageInGB / $shareQuota)
New --- $RemainingPercent = 100 - ($shareUsageInGB / $shareQuota * 100)
