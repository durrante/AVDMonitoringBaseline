# AVD Monitoring Baseline — Changes from the Original Microsoft Baseline

This fork of [Azure/azure-monitor-baseline-alerts](https://github.com/Azure/azure-monitor-baseline-alerts) (`patterns/avd`) is maintained independently because upstream development of the AVD pattern has gone stale. This document lists every functional change from the upstream baseline (upstream `main` as of commit `ba0266b3`, template v2.2.1) so users migrating from the original solution can see exactly what differs.

**Current version: v2.6.1** (2026-10-23)

---

## v2.6.1 (2026-10-23) — this fork

### 1. Repeated alerts for the same problem fixed

**Alerts affected:** Available Memory Less Than 2GB / 1GB, Local Disk Free Space 10 / 5 Percent, Low Space on Azure File Share 15 / 5 Percent Remaining, Host Pool Capacity 50 / 85 / 95 Percent, and Autoscale Failures.

**Problem:** these alerts used a value that changes at every check as an alert dimension: `AvailableMB`, `CounterValue` and `PercentAvailable` (added in v2.4.0 to show the value in the alert), the Capacity alerts' session counts and load percentage (from the original baseline), and Autoscale Failures' `LastErrorCode`. Azure treats every distinct combination of dimension values as a separate alert. So each check **opened a new alert**, and closed the previous one about 15 minutes later, because that exact value never appeared again. On a production deployment, 5 session hosts with sustained memory pressure produced **126 memory alerts in one morning**. The same data with this fix produces **14**: one per spell of low memory.

**Change:** the value is now **measured** rather than used as a dimension. Each alert checks the value column (the lowest available memory, disk or share space, or the highest host pool load) against its threshold, and Azure shows it as the alert's **metric value** in the notification. Dimensions are now stable: host, host pool and resource group, or storage account and share. One problem now raises one alert, which stays open while the problem lasts and resolves when it clears.

**Power-on protection unchanged:** the Available Memory queries still skip any session host without 10 minutes of readings (the v2.3.0 fix for false positives while hosts power on). Only how Azure evaluates the returned rows changed, not which rows are returned. Checked against production data: the affected hosts had 22 to 27 GB free right after power-on and only ran low hours later.

**Removed dimensions:** the Capacity alerts no longer list session counts in the alert details (they are still in the alert's search results link), and Autoscale Failures no longer includes the last error code (query `WVDErrors` by `CorrelationId`, as the alert description says).

### 2. Host Pool Capacity alerts read the latest runbook run

The Capacity alerts checked every 5 minutes but only looked at runbook output from the last 5 minutes. The runbook runs every 15 minutes, so 2 of every 3 checks found nothing, and an open alert could close and reopen repeatedly. The alerts now read the latest runbook run from the last 20 minutes.

### 3. Repeat notifications muted when auto-resolve is off

When **Allow Alerts to Auto-Resolve** is **No**, Azure notifies at every check for as long as the condition holds. Log search alerts that are checked more often than hourly now mute notifications for 1 hour after firing in that mode, so a persistent problem notifies about once an hour instead of every 5 to 15 minutes. Deployments with auto-resolve on (the default) are unaffected: they already notify once per problem.

### 4. Upgrade guide

[Update to a new release](../../docs/Update-to-new-Release.md) now explains how to upgrade and what a redeployment leaves behind, including the pre-v2.3.0 metric memory alerts. If those are not deleted, memory alerts arrive twice and still fire false positives at power-on.

### Upgrade notes

- Redeploy to apply. The affected alert rules are updated in place.
- Alerts opened by the old rules close on their own at the next few checks after the update. Nothing needs clearing by hand.

---

## v2.6.0 (2026-10-19) — this fork

Six new host pool alerts (seven alert rules), each designed around one question: does it fire only when something is genuinely wrong? Every alert below lists what it looks for, the problem it catches, and what it deliberately ignores. Like every alert in this solution, they deploy **disabled**.

### 1. New: Scaling Plan Disabled over 4 Hours (Sev3) / over 24 Hours (Sev2)

**Catches:** autoscale turned off on a host pool's scaling plan assignment, typically for maintenance, and not turned back on. Session hosts are then left running out of hours (cost) or not started when users need them (capacity).

**How:** the Host Pool Info runbook now reads the scaling plan assigned to each host pool and reports its state for that pool (see item 7). The alert fires when every runbook run across the window reports `Disabled`. The enable flag lives on the scaling plan's reference to each host pool, so a plan shared by several pools alerts only for the pool(s) where it is disabled.

**Deliberately ignores:** host pools with no scaling plan (see Scaling Plan Removed), failed lookups, and runbook outages. At least 75% of the expected runs must be present (12 of 16 in 4 hours, 72 of 96 in 24 hours). The 4 hour tier gives routine maintenance time to finish. The 24 hour tier is evaluated every 6 hours, so a plan intentionally left disabled does not notify every hour when auto-resolve is turned off.

**Why not "no autoscale evaluations logged"?** That was the obvious approach, but autoscale logging volume drops to around 2 evaluations an hour overnight and at weekends (measured on a production workspace), and the logs need a diagnostic category most deployments do not have. Reading the actual setting avoids both problems and also covers personal host pools and host pools using session host configuration.

### 2. New: Scaling Plan Removed (Sev3)

**Catches:** a host pool that had a scaling plan and now has none, for example removed during a rebuild and never reassigned. Scaling Plan Disabled cannot see this, because a pool with no plan looks the same as one that never had one.

**How:** a one-time change notification. It fires once, roughly 4 hours after the removal, if no plan has been reassigned in that time, and names the removed plan. It closes at the next hourly check, so a "resolved" notice does not mean the plan was reassigned (stated in the alert description).

**Deliberately ignores:** a plan removed and re-added within 4 hours, a host pool moved to a different scaling plan, a deleted host pool, failed lookups and runbook outages. It **can** fire if the Automation Account loses read access to the plan or the plan moves resource group: the alert is then still useful, as the Scaling Plan Disabled alerts can no longer see that plan.

### 3. New: VM-Agent Upgrade Failed or Stuck (Sev3)

**Catches:** a session host whose AVD agent upgrade failed and has not recovered for an hour, or has been stuck upgrading for over 2 hours. Microsoft documents that sessions are not affected straight away, but the host falls behind on agent versions, and the failure usually points to an underlying problem (low disk space, security software blocking the agent). The existing Health Check Failure alert misses this, as it only matches hosts with a failing health check.

**Deliberately ignores:** the `Pending` and `Initial` upgrade states, which are normal (on a production workspace `Pending` made up about 9,300 rows in 30 days with no failures), retries that succeed within an hour, and hosts in drain mode, which are often on their way out of service.

### 4. New: VM-Drained and Idle over 24 Hours (Sev3)

**Catches:** a session host left in drain mode, powered on and with no user sessions for 24 hours, usually after troubleshooting or maintenance. It cannot take new users and is costing compute for nothing.

**Deliberately ignores:** drained hosts that still have users (likely being drained out of service), drained hosts that are switched off (they only cost disk), and short drains during session host configuration updates or patching. The host must report in at least 22 of the 24 hourly periods and still be running.

### 5. New: Autoscale Failures (Sev3)

**Catches:** autoscale enabled but failing, so hosts are not started or stopped. Common causes: the AVD service principal missing the Desktop Virtualization Power On Off Contributor role, VM capacity or quota, a resource lock, or an Azure Policy. The last error code is included.

**How:** fires when at least 2 evaluations fail and none succeed in an hour. A fixed count such as "3 failures an hour" could never trigger overnight, when autoscale may only log 2 evaluations an hour. Requiring zero successes absorbs one-off failures, such as autoscale acting on a VM being deleted during host replacement.

**Requires:** the **Autoscale logs for pooled host pools** category in the host pool diagnostic settings (pooled host pools only). Without it the alert never fires.

### 6. New: Diagnostic Data Not Received (Sev2)

**Catches:** a host pool whose diagnostic settings were removed or redirected, for example after a host pool was redeployed from code without them, or an Azure Policy overwrote them. Most log based alerts in this solution depend on that data, so without this alert they all go silent unnoticed.

**How:** the runbook, which reads Azure Resource Manager and not diagnostics, saw user sessions in every run for the past hour, yet no `WVDAgentHealthStatus` data arrived from the host pool. Running session hosts report roughly every 30 seconds.

**Deliberately ignores:** host pools that scale to zero (no sessions overnight means no alert).

### 7. Host Pool Info runbook reports the scaling plan for each host pool

`Get-HostPoolInfo.ps1` appends two fields to its pipe-delimited output: `ScalingPlanName` (index 13) and `ScalingPlanState` (index 14), one of `Enabled`, `Disabled`, `None` (no plan assigned) or `Unknown` (lookup failed). They are appended at the end, so existing alerts that read fields by position are unaffected. The plan is found with the list-by-host-pool API (`Get-AzWvdScalingPlan -HostPoolName`), and its enabled flag is read from that plan's reference to the host pool.

### 8. Read access on scaling plan resource groups, and a deployment form that shows it

A scaling plan can live in a different resource group, or subscription, from the host pools it serves. If the runbook cannot read the plan, the pool looks like it has no plan and the scaling plan alerts stay silent. To prevent that:

- **Template:** a new optional parameter `ScalingPlanResourceIds`. The Automation Account identity is granted Desktop Virtualization Reader on each scaling plan's resource group that is not already covered by the host pool or VM resource group assignments (compared case-insensitively, so no duplicate assignments).
- **Portal form:** looks up scaling plans via Azure Resource Graph, passes the plans assigned to the selected host pools, and shows two messages. An info box lists each selected host pool with its scaling plan and resource group. A warning lists selected host pools with **no** scaling plan, as the scaling plan alerts do not apply to them.
- **Docs:** a new FAQ entry explains when the scaling plan alerts stay silent, including the need to redeploy after assigning or moving a plan later, and includes a query to check what the runbook reports.

### 9. Runbook scripts now come from the same location as the template

The `_ArtifactsLocation` parameter defaulted to the `main` branch on GitHub, so deploying the template from any other branch or URL (for example to test a pre-release from the `dev` branch) silently installed `main`'s runbook scripts. The default is now empty. When empty, the scripts are taken from the `scripts/` folder next to the deployed template, using the template address Azure provides for URL based deployments (Deploy to Azure button, `--template-uri`). The fallback is `main` on GitHub when no template address is available, such as a local file deployment. A custom script location still overrides both. The standard Deploy to Azure button behaves exactly as before, because its template lives on `main`.

### 10. Documentation corrections

- The FAQ said a Logic App ran the runbooks every 5 minutes. The solution uses four hourly Automation schedules offset by 15 minutes, so the runbooks run **every 15 minutes**, and no Logic App is deployed. Corrected.
- The alert description header still said v2.4.0. It now says v2.6.0.

### Upgrade notes

- **Redeploy to pick up the new runbook.** The runbook script is fetched from the artifacts location at deployment time. Until it is updated, the scaling plan fields are empty and the three Scaling Plan alert rules simply stay silent. The other new alerts do not depend on the runbook change.
- If you previously granted Desktop Virtualization Reader manually on a scaling plan's resource group to the Automation Account identity, remove it before redeploying, otherwise the deployment fails with `RoleAssignmentExists`.
- The Autoscale Failures alert needs the "Autoscale logs for pooled host pools" diagnostic category. Enable it before turning the alert on.

---

## v2.5.0 (2026-07-17) — this fork

### 1. Corrected the stale networking note on the Azure File Share alerts

The descriptions for `AVD-Storage-Low Space on Azure File Share-15 Percent Remaining` and `-5 Percent Remaining` warned that the runbook "will FAIL if Networking for the storage account has anything other than 'Enabled from all networks'". That note predates the script's switch to the ARM management-plane cmdlet (`Get-AzRmStorageShare`): share usage is read via ARM, which is not subject to the storage firewall or private endpoints. Verified against a production storage account with a private endpoint and public network access locked down. Both descriptions now state the accurate behaviour. (Investigated as part of [#3](https://github.com/durrante/AVDMonitoringBaseline/issues/3).)

### 2. New: use an existing Action Group ([#4](https://github.com/durrante/AVDMonitoringBaseline/issues/4))

All alert rules previously required a new email-based Action Group created from the `DistributionGroup` address. A new optional parameter `ExistingActionGroupResourceId` lets you point every alert rule at an Action Group you already have (email, SMS, push, ITSM connectors, etc.). When set, no new Action Group is created and `DistributionGroup` is ignored. The portal UI gains a "Use an existing Action Group?" checkbox: ticked shows a subscription selector and an Action Group picker (no resource IDs to paste), unticked behaves exactly as before. The picker lists only Action Groups with location **Global**, because the Service Health alert rules reject regional Action Groups (`ServiceHealthRuleActionGroupLocationIsNotGlobal`); a warning box in the form explains this. Fully backwards compatible: leaving the parameter empty preserves the existing behaviour.

### 3. Storage runbook RBAC reduced from Storage Account Contributor to Reader

The Automation Account's managed identity was granted **Storage Account Contributor** (a write-capable role) on every storage account resource group purely to read share quota and usage. The ARM read only requires **Reader**, so the assignment is now Reader. **Upgrade note:** redeploying over an existing installation does not remove the previously created Storage Account Contributor assignment; remove it manually from the storage resource group(s) after upgrading.

### 4. Metric alerts now work across regions (and subscriptions)

Every metric alert previously stamped `targetResourceRegion` with the **deployment** region. Deploying the solution in a different region from the monitored resources failed storage/ANF alerts outright (`The following resources were not found under the region <deployment-region>`), and worse, the multi-resource VM alerts deployed successfully but would **silently never fire** because no VMs exist in the stamped region. `targetResourceRegion` is now derived from the monitored resource itself:

- Storage account and file-services alerts: the storage account's actual location
- ANF volume alerts: the volume's actual location
- VM alerts (multi-resource, scoped to the VM resource group): the VM resource group's location. Multi-resource metric alerts only support a single region (platform constraint), so session host VMs are assumed to be in the same region as their resource group.

The alerts solution can now be deployed in any region while monitoring resources in other regions and other subscriptions.

### 5. One deployment can monitor AVD environments across subscriptions

The Basics-page subscription previously constrained the whole deployment: the host pool and resource group pickers only listed that subscription, the `Get-HostPoolInfo` runbook was pointed at the deployment subscription, and the Desktop Virtualization Reader role assignments were scoped by resource group name only (implicitly the deployment subscription). Now:

- **Pickers:** host pools, the AVD resource group and the VM resource group grid column are listed via Azure Resource Graph across every subscription the deploying user can read. Labels include the resource group (host pools) or subscription (resource groups) for disambiguation. The alerts resource group picker deliberately still lists only the deployment subscription, since that's where the solution itself lives.
- **Runbook:** the `SubscriptionId` parameter of `Get-HostPoolInfo.ps1` now accepts a comma-separated list (a single value remains fully supported, so existing schedules are unaffected). The template passes the distinct set of subscriptions derived from the selected host pools, and the runbook switches context per subscription.
- **RBAC:** Desktop Virtualization Reader is granted per VM resource group and per host pool resource group (deduplicated), each in its own subscription.
- **The VMs-in-separate-resource-groups mapping grid is preserved** and each row is now cross-subscription capable.

Notes: the deploying account needs Owner or User Access Administrator in every subscription containing selected host pools or VM resource groups. In "all resources in same RG" mode the VM metric alerts still cover the single selected AVD resource group; use the mapping grid for multi-subscription or multi-resource-group estates. The runbook is fetched from `_ArtifactsLocation` at deploy time, so multi-subscription deployments require the updated `Get-HostPoolInfo.ps1` to be published (or a custom script location).

Further refinements:

- **Storage accounts are cross-subscription too:** the Azure Files picker is now a single Azure Resource Graph backed multi-select across every readable subscription (labels show `name | subscriptionId`, descriptions show SKU and region), replacing the one-subscription-at-a-time selector. The template already handled cross-subscription storage (per-account role assignments, context-switching runbook, region-aware metric alerts), so this was UI-only.
- **AVD Resource Group is now hidden when "VMs in separate Resource Group(s)" is ticked** — in grid mode the mapping rows define the VM alert scopes and the field was vestigial. The always-on Desktop Virtualization Reader assignment on that resource group is now conditional on same-RG mode to match (previously it deployed even in grid mode, an inherited upstream quirk). The form passes a placeholder value in grid mode; the template ignores it there.
- **Tooltips now explain the mode split:** the AVD Resource Group is the scope for the VM metric alerts (CPU, memory, OS disk) in same-RG mode, while host pool alerts are log based and follow the selected pools wherever they live — previously nothing in the UI explained why the host pool list ignored the resource group selection.

## v2.4.0 (2026-07-06) — this fork

### 1. Host Pool Capacity alerts (50/85/95 Percent) never fired — `toint()` on a decimal value returned `null`

**Alerts affected:** `AVD-HostPool-Capacity 50 Percent`, `AVD-HostPool-Capacity 85 Percent`, `AVD-HostPool-Capacity 95 Percent`

The capacity runbook (`Get-HostPoolInfo.ps1`) reports `$HPLoadPercent` as a decimal (for example `68.5` or `68.25`). The alert query parsed it with:

```kusto
| extend HostPoolPercentLoad=toint(split(ResultDescription, '|')[9])
```

`toint()` only parses whole-number strings; on a decimal string like `"68.5"` it silently returns `null`. Every subsequent `where HostPoolPercentLoad >= N` comparison against `null` evaluates to false, so **these alerts have never fired**, regardless of actual host pool load. Fixed by switching to `toreal()`, which correctly parses the decimal.

### 2. Host Pool Capacity alerts pointed `HPResourceId` at the wrong field

Same three alerts also read:

```kusto
| extend HPResourceId=tostring(split(ResultDescription, '|')[13])
```

Counting the pipe-delimited runbook output (`HostPoolName|ResourceGroup|Type|MaxSessionLimit|NumberHosts|TotalUsers|Disconnected|Active|Available|LoadPercent|NumPerUnhlthy|PerHostUnhlthy|ResourceId`), the resource ID is at index **12**, not 13 — index 13 doesn't exist, so `HPResourceId` (used as `resourceIdColumn`) was always empty. Fixed to read index `[12]`, so fired alerts now correctly link to the host pool resource.

### 3. Relevant computed values now surfaced as alert dimensions

Several log-query alerts computed a meaningful current value in KQL (available memory, disk free percent, storage percent remaining) but never exposed it — for Log Alerts V2, only columns listed in `dimensions` appear in the fired alert / email / portal details, so these values were silently discarded. Added as dimensions:

- **Available Memory alerts** (2GB/1GB): `AvailableMB` — the actual available memory (MB) that triggered the alert.
- **Local Disk Free Space alerts** (10%/5%): `CounterValue` — the actual free-space percentage on the VM's local disk.
- **Low Space on Azure File Share alerts** (15%/5%): `PercentAvailable` — the actual percentage remaining on the share.

The Host Pool Capacity alerts already exposed `HostPoolPercentLoad` as a dimension, so fixing bug #1 above also fixes the percentage shown for those.

### 4. Service Health alert display name typo

`AVD-ServiceHealth-Serivice Issue` corrected to `AVD-ServiceHealth-Service Issue`.

### 5. Version bump

`AlertDescriptionHeader` and docs updated from v2.3.0 to v2.4.0.

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

### 5. Customer / tenant identification for MSPs (new `CustomerName` parameter)

Alert emails all come from Microsoft's `azure-noreply` sender, and host pool names can be identical across tenants — a problem for MSPs monitoring many customers. A new **optional `CustomerName` parameter** (portal UI field "Customer / Tenant Name") stamps `Customer: <name>` at the top of every alert description, which surfaces in the alert email body, the portal alert details, and the `description` field of the common alert schema (ITSM/webhook payloads). Combined with a per-customer `AlertNamePrefix` (which appears in the email subject via the alert rule name), every notification is unambiguously attributable to a customer. Leaving `CustomerName` empty produces the original description header, so existing parameter files keep working unchanged.

### 6. `_ArtifactsLocation` default repointed to this fork

The default scripts URL pointed at `Azure/azure-monitor-baseline-alerts`; it now points at this repository so deployments pull the runbook scripts (`Get-HostPoolInfo.ps1`, `Get-StorAcctInfo.ps1`) from the maintained fork.

### 7. Version bump

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
