# What´s new

For information on what's new please refer to the [Releases](https://github.com/durrante/AVDMonitoringBaseline/releases) page and the [change log](../patterns/avd/CHANGES.md) page.

To update your current deployment with the content from the latest release, please refer to the [Update to new release](Update-to-new-Release.md) page.

## 2026-10-19 — v2.6.0 (this fork)

- **Six new host pool alerts**, each built to fire only when something is genuinely wrong, and to stay quiet during routine work:
  - **Scaling Plan Disabled over 4 / 24 Hours** (Sev3 / Sev2): autoscale switched off on a host pool and left off. Checks the actual setting, so it covers pooled and personal host pools, and host pools using session host configuration.
  - **Scaling Plan Removed** (Sev3): a one-time notification when a host pool loses its scaling plan for over 4 hours.
  - **VM-Agent Upgrade Failed or Stuck** (Sev3): AVD agent upgrades that fail or hang, which the Health Check Failure alert misses.
  - **VM-Drained and Idle over 24 Hours** (Sev3): a session host left in drain mode, running and empty for a day.
  - **Autoscale Failures** (Sev3): autoscale is on but failing to start or stop hosts. Needs the "Autoscale logs for pooled host pools" diagnostic category.
  - **Diagnostic Data Not Received** (Sev2): a host pool with active users that has stopped sending diagnostic data, which would otherwise silently blind most of the other alerts.
- **Scaling plans in other resource groups just work.** The deployment form finds the scaling plans assigned to your selected host pools, shows them, warns about host pools with no plan, and grants the runbook read access wherever each plan lives.
- **Docs fix:** the host pool and storage runbooks run every 15 minutes (the FAQ said 5, via a Logic App that is not deployed).
- **Redeploy to upgrade**, so the updated runbook is picked up. Full details, including what each alert deliberately ignores, in the [change log](../patterns/avd/CHANGES.md).

## 2026-07-17 — v2.5.0 (this fork)

- **Deploy once for multi-subscription, multi-region estates.** Host pools, session host VM resource groups and storage accounts can now live in different subscriptions and regions from the alerts deployment (and from each other). The portal pickers list resources across every subscription you can read, the host pool runbook collects data across subscriptions, and every metric alert automatically targets the monitored resource's own region. One deployment per Log Analytics workspace now covers the whole estate, where previously a deployment was needed per subscription and everything had to share the deployment region. Note: all selected host pools must send AVD Insights data to the single Log Analytics workspace chosen at deployment.
- **Use an existing Action Group** ([#4](https://github.com/durrante/AVDMonitoringBaseline/issues/4)). A new checkbox lets you point every alert rule at an Action Group you already have, so SMS, push notifications and ITSM connectors are available to all alerts, and notification changes made on the Action Group apply everywhere at once. The picker lists Action Groups with location Global (a platform requirement of the Service Health alert rules). Unticked, the solution creates an email based Action Group exactly as before.
- **Tighter RBAC for the storage runbook.** The Automation Account identity now receives Reader on the storage account resource group(s) instead of Storage Account Contributor. Share usage is read via the ARM management plane, so no write capable or data plane role is needed. On upgrades, remove the old Storage Account Contributor assignment manually.
- **Private endpoint and firewalled storage accounts are fully supported** by the Azure Files share space alerts, and the alert descriptions now say so (the previous note claiming the runbook required "Enabled from all networks" was outdated).
- **Portal UI refinements**: clearer mode guidance for "VMs in separate Resource Group(s)" (the AVD Resource Group field now only appears when it is actually used), storage account and host pool lists include the subscription for disambiguation, and the custom script location guidance now states the exact script filenames.
- Full details in the [change log](../patterns/avd/CHANGES.md).

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
