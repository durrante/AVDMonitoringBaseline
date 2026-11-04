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

## Who disabled the scaling plan, and when?

The runbook records each host pool's scaling plan state every 15 minutes, so its history shows **when** the state changed. The Azure Activity Log shows **who** changed it.

**When:** run this in the Log Analytics workspace used by this solution, replacing the host pool name. The row where `ScalingPlanState` changes from `Enabled` to `Disabled` (or to `None` if the plan was removed) is the change; it happened in the 15 minutes before that row's `TimeGenerated`. An earlier row going from blank to `Enabled` only marks when the v2.6.0 runbook started reporting.

```kusto
AzureDiagnostics
| where TimeGenerated > ago(7d)
| where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
| extend HostPoolName = tostring(split(ResultDescription, '|')[0])
| extend ScalingPlanState = trim(@"\s", tostring(split(ResultDescription, '|')[14]))
| where HostPoolName =~ '<host pool name>'
| order by TimeGenerated asc
| extend PreviousState = prev(ScalingPlanState)
| where ScalingPlanState != PreviousState
| project TimeGenerated, PreviousState, ScalingPlanState
```

**Who:** turning autoscale off for a host pool, or removing the host pool from the plan, is recorded as a change to the **scaling plan**, not the host pool.

1. In the Azure portal, open the scaling plan, then **Activity log** (kept for 90 days).
2. Set the timespan to cover the time found above, and look for **Create or Update Scaling Plan**.
3. **Event initiated by** shows who made the change.
4. Open the entry and select **Change history**. It shows `scalingPlanEnabled` changing to `false` (disabled), or the host pool disappearing from `hostPoolReferences` (removed). Schedule edits are recorded as separate *pooled schedule* operations, so they are easy to tell apart.

If the scaling plan itself was deleted, look for **Delete Scaling Plan** in the resource group's Activity log instead.

If your Activity Log is sent to a Log Analytics workspace, this finds the same entries in one go. It returns nothing if the Activity Log is not sent there; it may be in a different workspace from the one this solution uses.

```kusto
AzureActivity
| where TimeGenerated > ago(7d)
| where OperationNameValue has "Microsoft.DesktopVirtualization/scalingPlans"
| where _ResourceId has "<scaling plan name>"
| project TimeGenerated, OperationNameValue, ActivityStatusValue, Caller, CallerIpAddress
| order by TimeGenerated desc
```

**The query shows the plan disabled, but I can't see an alert.** Check two things before anything else:

- **The Alerts page shows the last 24 hours by default.** An alert that fired earlier is still open but outside that window, so widen the time range.
- **An open alert does not notify again.** Each alert notifies once when it fires and once when it resolves. If autoscale has been off for days, the notifications went out when each alert first fired: about 4 hours after the change for the Sev3 alert, and about 24 to 30 hours after it for the Sev2 alert.

## Should I allow alerts to auto-resolve?

Yes, keep **Allow Alerts to Auto-Resolve** set to **Yes** (the default).

- **Yes:** each problem raises one alert, for example one per session host that is low on memory. The alert stays open while the problem lasts and sends a single notification. When the problem has been clear for a short period (about 15 minutes for alerts checked every 5 minutes), it resolves and sends a Resolved notification. A problem on a different host, or one caught by a different alert rule, always raises its own alert straight away.
- **No:** alerts never resolve, and Azure sends a new notification at **every check** for as long as the problem lasts. For most alerts in this solution that is every 5 to 15 minutes. The solution deliberately does not mute these repeats. Azure's mute setting applies to a whole alert rule, so it would also hold back a genuine alert for a different session host.

To check which setting a deployment uses, run this in Resource Graph Explorer:

```kusto
resources
| where type =~ 'microsoft.insights/scheduledqueryrules'
| where properties.description has 'Automated AVD Alert Deployment Solution'
| summarize AlertRules = count() by subscriptionId, AutoResolve = tostring(properties.autoMitigate)
```

## How do I stop alerts firing during planned maintenance?

Use an [alert processing rule](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-processing-rules) to suppress notifications for the maintenance window, filtered on the alert rule and, where useful, the host name. A few of the alerts are also built to tolerate routine work on their own:

- **Scaling Plan Disabled over 4 Hours** gives most maintenance time to finish before it fires, and **Scaling Plan Removed** waits 4 hours so a plan removed and re-added during the work never fires.
- **Autoscale Failures** only fires when every evaluation in an hour fails. During session host replacement, tag outgoing hosts with the scaling plan's exclusion tag so autoscale does not try to start or stop VMs that are being deleted.
- **Drained and Idle over 24 Hours** ignores drained hosts that still have users, and drained hosts that are switched off.
- **FSLogix Service Stopped** ignores host shutdowns and restarts, and a service that is started again. Upgrading or reinstalling FSLogix on a running host stops the service, so it can fire during that work.

## Users cannot sign in to one session host

A session host can get stuck so that every new sign-in hangs or fails, while Azure Virtual Desktop still reports it as **Available** and keeps sending users to it. The FSLogix service stays running, the agent health checks pass, and autoscale does not add capacity because failed sign-ins do not count as sessions. In a host pool with one powered-on host, that is a full outage.

**What the alerts show.** In the incident these alerts were built from, the profile disk storage stopped responding and the alerts would have fired in this order:

1. **VM-Disk IO Timeouts** (Sev2): vhdmp 129 and disk 153 warnings, at the same time as the first failed sign-ins.
2. **VM-FSLogix Profile Logon Blocked** (Sev2), about 35 minutes later, when FSLogix gave up waiting for the first user's logon lock.
3. **VM-Multiple Users Unable to Connect** (Sev2) and **VM-FSLogix Profile Logon Blocked for Multiple Users** (Sev1), within the next 15 minutes.

**What to do first:**

1. Turn off **Allow new sessions** (drain mode) on the host, so no more users are sent to it.
2. Make sure another session host is running and available. Start one if needed.
3. Ask affected users to sign out and sign in again, so they land on a healthy host.
4. Collect evidence if you can (below), then restart the host. A stuck host can hang while shutting down: if it has not restarted after 10 minutes, restart it from the Azure portal.
5. Turn drain mode off once users can sign in to the host again.

**Timeline query.** Run this in the Log Analytics workspace, with the session host's computer name and a time range covering the problem. It lists each connection (a connection showing `Started,Completed` without `Connected` failed) alongside the host's warning and error events in 5 minute buckets, so you can see what started first.

```kusto
let HostName = "vm-avd-01";   // the session host's computer name, without the domain
let StartTime = ago(6h);
let EndTime = now();
let Connections = WVDConnections
| where TimeGenerated between (StartTime .. EndTime)
| summarize States = strcat_array(make_set(State), ","), Start = min(TimeGenerated),
    Host = take_anyif(tolower(tostring(split(SessionHostName, ".")[0])), isnotempty(SessionHostName)),
    User = take_any(UserName)
    by CorrelationId
| where Host == HostName
| project Time = Start, Kind = "Connection", Detail = strcat(User, " | ", States);
let HostEvents = Event
| where TimeGenerated between (StartTime .. EndTime)
| where tolower(tostring(split(Computer, ".")[0])) == HostName
| where EventLevelName != "Information"
    or (Source == "Microsoft-FSLogix-Apps" and EventID == 25)
    or (Source == "User32" and EventID == 1074)
| summarize Count = count(), Sample = take_any(substring(RenderedDescription, 0, 150))
    by Source, EventID, Time = bin(TimeGenerated, 5m)
| project Time, Kind = "Event", Detail = strcat(Source, " ", EventID, " x", Count, " | ", Sample);
union Connections, HostEvents
| order by Time asc
```

What to look for:

- **vhdmp 129** (reset to a virtual disk) and **disk 153** (IO retried): disk IO stopped responding. Usually the first sign.
- **RemoteConnectionManager 20498** ("taken too long to complete the client connection"): sign-ins are hanging.
- **Winlogon 6005, 6006 and 6004** naming `frxsvc`: FSLogix is taking too long to handle, or failing, sign-ins.
- **FSLogix 26** "Failed to acquired logon lock … (Elapsed time: 60000)": a sign-in blocked for 60 seconds. A single "Failed to acquire mutex" or "check session lock" error on its own is normal.
- **FSLogix 25** (profile load) stopping: no one has signed in successfully since.
- **Kernel-Power 41** and **EventLog 6008** after the restart: the host did not shut down cleanly, which fits stuck IO.

**Evidence to collect before the restart.** On the host, in an elevated PowerShell session. If a command hangs, skip it: the host is stuck on disk IO.

```powershell
$Out = "C:\Temp\AVD-Evidence-$(Get-Date -Format yyyyMMdd-HHmm)"
New-Item -ItemType Directory -Path $Out -Force | Out-Null
Copy-Item "C:\ProgramData\FSLogix\Logs" "$Out\FSLogix-Logs" -Recurse -Force
foreach ($Log in "System", "Application", "Microsoft-FSLogix-Apps/Operational", "Microsoft-FSLogix-Apps/Admin") {
    wevtutil epl $Log "$Out\$($Log -replace '[/ ]', '-').evtx"
}
# The Location column shows the VHD(X) path of each attached profile disk, so Disk numbers in
# vhdmp and disk events can be matched to a user
Get-Disk | Select-Object Number, FriendlyName, Location, OperationalStatus, Size |
    Format-Table -AutoSize | Out-File "$Out\Disks.txt"
Get-Service frxsvc, frxccds -ErrorAction SilentlyContinue | Out-File "$Out\FSLogix-Services.txt"
Compress-Archive -Path "$Out\*" -DestinationPath "$Out.zip" -Force
```

**Storage checks.** On the storage account holding the profiles, look at the metrics for the time the problem started: Availability, Success E2E Latency against Success Server Latency, and Transactions split by ResponseType. High end-to-end latency with normal server latency points at the host or the network path (SMB, private endpoint, DNS, firewall). High server latency, throttling or availability drops point at storage. If only one host was affected and storage looks normal, the cause is most likely on that host: the virtual disk or SMB client stack, one attached profile disk, or a third-party file system filter driver (for example security or DLP software).

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
