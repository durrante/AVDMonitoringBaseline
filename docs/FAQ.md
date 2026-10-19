# Frequently Asked Questions

## What are the Prerequisites?

An AVD deployment, and Owner (or User Access Administrator) in every subscription containing the selected host pools, VM resource groups and storage accounts, since the deployment creates role assignments there. You must have also pre-configured the AVD Insights as it will enable diagnostic logging for the Host Pools and associated VMs in which the alerts rely on. All selected host pools must send AVD Insights data to the single Log Analytics workspace chosen at deployment.

## What's deployed to my Subscription?

Names will be created with a standard 'avdmetrics' in the name and vary based on input for things like site, environment type, etc.

Resource Group starting with the name "rg-avdmetrics-" with the following:

- Automation Account with a Runbook (for Host Pool Information not otherwise available)
- Identity for the Automation Account in which the name will start with "aa-avdmetrics-"
- Four hourly Automation schedules, offset by 15 minutes, so the Host Pool Info runbook (and the Azure Files runbook, when storage is selected) runs every 15 minutes

The Automation Account Identity will be assigned the following roles:

- Desktop Virtualization Reader on the resource groups holding the selected host pools, their session host VMs, and any scaling plans assigned to them
- Reader on the storage account resource group(s) (share usage is read via the ARM management plane, so no data-plane or write-capable role is needed)

## Why don't the scaling plan alerts fire for my host pool?

The **Scaling Plan Disabled** and **Scaling Plan Removed** alerts rely on the Host Pool Info runbook reading the scaling plan assigned to each host pool every 15 minutes. They stay silent, by design, in these cases:

- **The host pool has no scaling plan.** A pool without a plan may be intentionally always on, or scaled by another tool, so it is never treated as a problem. The deployment form lists any selected host pools without a scaling plan.
- **The runbook cannot read the scaling plan.** The deployment finds the scaling plans assigned to the selected host pools and grants the Automation Account identity Desktop Virtualization Reader on their resource groups, including plans in other resource groups or subscriptions. If you assign a scaling plan from another resource group, or move one, **after** deploying, redeploy the solution so access is granted. If you instead grant the role manually, remove that assignment before your next redeployment, otherwise the deployment fails with `RoleAssignmentExists`.
- **The runbook is not running, or its lookup failed.** Both alerts require most of the expected runbook runs to be present and ignore failed lookups, so a runbook outage never raises a false alert.
- **The runbook predates v2.6.0.** The runbook script is fetched from the artifacts location at deployment time, so redeploy to pick up the version that reports scaling plans.

You can check what the runbook currently reports for each host pool with this query:

```kusto
AzureDiagnostics
| where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
| where TimeGenerated > ago(1h)
| extend HostPoolName = tostring(split(ResultDescription, '|')[0]),
         ScalingPlanName = tostring(split(ResultDescription, '|')[13]),
         ScalingPlanState = tostring(split(ResultDescription, '|')[14])
| summarize arg_max(TimeGenerated, ScalingPlanName, ScalingPlanState) by HostPoolName
```

`ScalingPlanState` is `Enabled`, `Disabled`, `None` (no plan assigned) or `Unknown` (the lookup failed).

## How do I stop alerts firing during planned maintenance?

Use an [alert processing rule](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-processing-rules) to suppress notifications for the maintenance window, filtered on the alert rule and, where useful, the host name. A few of the alerts are also built to tolerate routine work on their own:

- **Scaling Plan Disabled over 4 Hours** gives most maintenance time to finish before it fires, and **Scaling Plan Removed** waits 4 hours so a plan removed and re-added during the work never fires.
- **Autoscale Failures** only fires when every evaluation in an hour fails. During session host replacement, tag outgoing hosts with the scaling plan's exclusion tag so autoscale does not try to start or stop VMs that are being deleted.
- **Drained and Idle over 24 Hours** ignores drained hosts that still have users, and drained hosts that are switched off.

## Why are there four Service Health alerts instead of one?

A single activity log alert can match every Service Health incident type in one rule, so four rules are not needed for coverage. They are separate because most of the useful configuration on a Service Health alert happens per rule, and once the four are merged you cannot split them again without deleting and recreating:

- **Routing.** Security advisories, planned maintenance and service issues often belong to different teams. Separate rules let you point each one at a different Action Group. The deployment wires all four to the same Action Group to start with, so this is a change you make after deployment.
- **Enabling them independently.** Planned Maintenance is noise in a lot of environments, Security rarely is. With one combined rule it is all or nothing.
- **Suppression.** Alert processing rules target a specific alert rule, so you can silence maintenance notifications during a known window without silencing security ones at the same time.
- **The rule name travels with the notification.** Email subjects, webhooks, Logic Apps and ITSM connectors key off the alert rule name. With one combined rule every notification arrives under the same name and whatever is downstream has to read `properties.incidentType` to work out what happened.

If you do not want all four, leave the ones you do not need disabled. Every alert in this solution is deployed disabled by design (see [Avd-Deploy.md](Avd-Deploy.md)), and the portal's default filter hides disabled rules, so unused ones stay out of the way.

## Can Service Health alerts be created at the tenant (Directory) scope?

Azure supports it, see [Create tenant-level Service Health alerts](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-create-tenant-level-service-heath-alerts), but this solution deliberately does not. The alerts here are scoped to the subscription you deploy to. A tenant-level rule needs elevated access at the tenant root plus a role assignment there, it sits well outside the AVD scope this baseline covers, and it fires for every subscription in the tenant regardless of the region filter used here. If you want tenant-wide Service Health coverage, create it separately alongside this deployment.

## What's the cost?

While this is highly subjective on the environment, number of triggered alerts, etc. it was designed with cost in mind. The primary resources in this deployment are the Automation Account and Alerts. We recommend you enable alerts in stages and monitor costs, however the overall cost should be minimal.

- Automation Account runs its scripts every 15 minutes to collect host pool and Azure File Share data and averages around $5/month
- Alert Rules vary based on number of times triggered but estimates are under $1/mo each.
