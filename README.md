# AVD Monitoring Baseline Alerts

A maintained fork of the Azure Virtual Desktop (AVD) pattern from Microsoft's [Azure Monitor Baseline Alerts (AMBA)](https://github.com/Azure/azure-monitor-baseline-alerts) project.

<a href="../../releases"><img src="https://img.shields.io/github/v/release/durrante/AVDMonitoringBaseline?style=for-the-badge&label=Current%20Version&color=4A2B8F" alt="Latest release"></a>&nbsp;<a href="../../releases"><img src="https://img.shields.io/github/release-date/durrante/AVDMonitoringBaseline?style=for-the-badge&label=Released&color=0693E3" alt="Release date"></a>&nbsp;<a href="LICENSE"><img src="https://img.shields.io/github/license/durrante/AVDMonitoringBaseline?style=for-the-badge&color=2EA44F" alt="MIT licence"></a>

See [What's New](docs/Whats-New.md) and the full [change log](patterns/avd/CHANGES.md), or read the [blog post](https://modernworksplacehub.com/avd-monitoring-baseline-community-edition) for the story behind this fork.

## 🙏 Credit

This solution is around 95% the work of the original AMBA AVD pattern authors: the Microsoft AMBA team, the AVD product group and community contributors. A particular shout-out to [@JCoreMS](https://github.com/JCoreMS), who built and maintained the AVD pattern for a long time, and [@fbloemhof](https://github.com/fbloemhof), whose unmerged upstream fixes are incorporated here. The design, alert coverage, deployment experience and documentation are theirs.

## 💡 Why this fork exists

The upstream AVD pattern appears to be abandoned. Deployment-blocking bugs such as [issue #812](https://github.com/Azure/azure-monitor-baseline-alerts/issues/812) (which stopped any portal deployment from validating) and community fixes such as [PR #839](https://github.com/Azure/azure-monitor-baseline-alerts/pull/839) sat unaddressed for months. Rather than let a good solution go to waste, I've taken over maintenance here, merged the outstanding fixes and made a small number of improvements around false positives, alert context and noise. Input, issues and PRs are all welcome.

What's changed from the original baseline (details and rationale in [CHANGES.md](patterns/avd/CHANGES.md)):

| Change | Why |
|---|---|
| `LogAlertsStorage` template fix (via upstream PR #839) | Upstream template failed validation, blocking all deployments (issue #812) |
| FSLogix queries: `leftouter` changed to `inner` join (via upstream PR #839) | Duplicate/incorrect alerts when multiple host pools share a workspace |
| Available Memory alerts converted from metric to log query (KQL) alerts | Metric alerts fired false positives while session hosts were powering on (issue #656). The KQL version only evaluates hosts that have been reporting for the full window |
| Health Check Failure alert maps health checks 11 and 19 | `TURNRelayAccessHealthCheck` and `AADJoinedHealthCheck` were previously dropped as `InvalidIndex` |
| FSLogix "Profile Disk Attached to another VM" includes `UserName` and `ProfilePath` | Fired alerts now identify whose profile disk is locked and which VHD(X), without digging through event logs |
| High CPU 85% alert: every 30 min over a 1-hour window (was 5 min / 15 min) | Reduces noise from short CPU spikes. The 95% Sev1 alert keeps the fast 5-minute cadence |
| New optional `CustomerName` parameter | Identifies the customer/tenant in every alert description, useful for MSPs |
| Host Pool Capacity alerts (50/85/95%) fixed | `toint()` on the runbook's decimal load percentage silently returned `null`, so these alerts never fired regardless of actual load |
| Available Memory, Local Disk Free Space and Azure File Share alerts now show the value that triggered them | The current MB/percent value was computed in the query but not surfaced in the fired alert |

## 📖 Overview

This solution provides a baseline of alerts for AVD that are disabled by default, so administrators get meaningful and timely alerts when there are problems with an AVD deployment. It has been tested in Azure Global and Azure US Government and includes storage alerts for Azure Files and/or Azure NetApp Files. Enable alerts in phases and tune thresholds to suit your environment.

## 🚀 Deploy

<a href="https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdArm.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdCustomUi.json" target="_blank" rel="noopener"><img src="https://aka.ms/deploytoazurebutton" alt="Deploy to Azure"></a>&nbsp;&nbsp;<a href="https://portal.azure.us/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdArm.json/uiFormDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fdurrante%2FAVDMonitoringBaseline%2Fmain%2Fpatterns%2Favd%2FavdCustomUi.json" target="_blank" rel="noopener"><img src="https://aka.ms/deploytoazuregovbutton" alt="Deploy to Azure Gov"></a>

See the [Deployment Guide](docs/Avd-Deploy.md) for prerequisites, screenshots and post-deployment steps, including enabling the alerts (they deploy disabled by design).

## ✅ Prerequisites and required data

An AVD deployment with AVD Insights configured per the AVD portal's Insights configuration workbook:

1. An Azure tenant and subscription
2. At least one host pool with session hosts deployed
3. A Log Analytics workspace with:
   - Host pool diagnostic settings enabled (populates `WVDAgentHealthStatus`, used by the health check, FSLogix and memory alerts)
   - AVD workspace diagnostics enabled
   - The AVD Insights data collection rule (`microsoft-avdi-<region>`) associated with your session hosts, collecting at minimum:
     - Performance counter `\Memory\Available Mbytes` into the `Perf` table (required by the redesigned Available Memory alerts)
     - Performance counter `\LogicalDisk(C:)\% Free Space` into the `Perf` table (local disk alerts)
     - Windows event logs `Microsoft-FSLogix-Apps/Operational` and `Microsoft-FSLogix-Apps/Admin` into the `Event` table (FSLogix alerts)
4. Storage, either Azure Files or Azure NetApp Files, for FSLogix profiles (optional)

> **Note on the memory alerts:** the Available Memory alerts are now scheduled query rules against the `Perf` table instead of platform metric alerts. If you deployed the default AVD Insights DCR, no extra configuration is needed, as `\Memory\Available Mbytes` is part of its standard counter set. The change was made because the platform metric emits a 0 sample as a session host powers on (common with autoscale), which fired false "memory critically low" alerts. The KQL version skips hosts that haven't been reporting performance data for the full evaluation window, so hosts are only evaluated once they're properly up.

## 🏢 For MSPs: identifying which customer or tenant an alert came from

Alert emails all arrive from Microsoft's `azure-noreply` sender, and host pool names are often identical across tenants. Two parameters make the origin obvious:

- **Alert Name Prefix** (1 to 5 characters, e.g. `CON01`) flows into every alert rule name and display name, which appears in the email subject line, e.g. `Azure: Activated Severity: 2 CON01-HostPool-VM-High CPU 85 Percent (hostpool01)`. Use a unique prefix per customer.
- **Customer / Tenant Name** (new in this fork, optional, up to 64 characters) adds `Customer: <name>` at the top of every alert description. This appears in the email body and in the alert details in the portal, ITSM connectors and webhook payloads (the common alert schema `description` field).

Both are fields in the portal deployment UI. Every log-based alert also carries `HostPool`, `ComputerName` and `VMresourceGroup` dimensions, and the alert payload includes the subscription, so routing rules in your PSA/ITSM tooling can key off those as well.

## 📊 Alerts Table

The number of alert rules created may be multiple based on severity and/or additional volume or storage name designators. Download as [CSV](docs/alerts-table.csv).

| Name                                                                      | Threshold(s) (Severity)    |  Signal Type   |  Frequency          |  # Alert Rules |
|---                                                                        |---                         |---             |---                  |---          |
| AVD-HostPool-Capacity (1.)                                                | 95% (1) / 85% (2) / 50% (3)| Log Analytics  |  5 min              |  3/hostpool |
| AVD-HostPool-Disconnected User over n Hours (hostpoolname)                | 24 (1) / 72 (2)            | Log Analytics  |  1 hour             |  2/hostpool |
| AVD-HostPool-No Resources Available (hostpoolname)                        | Any are Sev1               | Log Analytics  |  15 min             |  1/hostpool |
| AVD-HostPool-VM-Available Memory Less Than nGB (hostpoolname) (3.)        | 1gb (Sev1) / 2gb (Sev2)    | Log Analytics  |  5 min              |  2/hostpool |
| AVD-HostPool-VM-FSLogix Profile DiskCompactFailed (hostpoolname)          | (2)                        | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-FSLogix Profile FailedAttachVHD (hostpoolname)            | (1)                        | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-FSLogix Profile Less Than n% Free Space (hostpoolname)    | 2% (1) / 5% (2)            | Log Analytics  |  5 min              |  2/hostpool |
| AVD-HostPool-VM-FSLogix Profile Failed due to Network Issue (hostpoolname)| (1)                        | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-FSLogix Profile Service Disabled (hostpoolname)           | (1)                        | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-FSLogix Profile Disk Attached to another VM (hostpoolname) (3.) | (2)                  | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-Health Check Failure (hostpoolname) (3.)                  | (1)                        | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-High CPU nn Percent (hostpoolname) (3.)                   | 95 (1) / 85 (2)            | Metric Alerts  |  5 min (1) / 30 min (2) |  2/hostpool |
| AVD-HostPool-VM-Local Disk Free Space n% (hostpoolname)                   | 5 (1) / 10 (2)             | Log Analytics  |  15 min             |  2/hostpool |
| AVD-HostPool-VM-Personal Assigned Not Healthy (hostpoolname)              | Any are Sev 1              | Log Analytics  |  5 min              |  1/hostpool |
| AVD-HostPool-VM-OS Disk Bandwidth Avg n% (hostpoolname)                   | 95 (1) / 85 (2)            | Metric Alerts  |  5 min              |  2/hostpool |
| AVD-HostPool-VM-User Connection Failed (hostpoolname)                     | Any are Sev 3              | Log Analytics  |  15 min             |  1/hostpool |
| AVD-HostPool-VM-Missing Critical Updates (hostpoolname)                   | Any are Sev 1              | Log Analytics  |  1 day              |  1/hostpool |
| AVD-Storage-Low Space on ANF Share-XX Percent Remaining-{volumename}      | 5 / 15                     | Metric Alerts  |  1 hour             |  2/vol  |
| AVD-Storage-Low Space on Azure File Share-X% Remaining-{volumename} (1.)  | 5 / 15                     | Log Analytics  |  1 hour             |  2/share  |
| AVD-Storage-Over XXms Latency for Storage Act-{storacctname}              | 100ms / 50ms               | Metric Alerts  |  15 min             |  2/stor acct |
| AVD-Storage-Over XXms Latency Between Client-Storage-{storacctname}       | 100ms / 50ms               | Metric Alerts  |  15 min             |  2/stor acct |
| AVD-Storage-Possible Throttling Due to High IOPs-{storacctname}  (2.)     | na / custom (2.)           | Metric Alerts  |  15 min             |  1/stor acct |
| AVD-Storage-Azure Files Availability-{storacctname}                       | 99 / na                    | Metric Alerts  |  5 min              |  1/stor acct |
| AVD-ServiceHealth-Health Advisory                                         | na                         | Service Health |  na                 |   4  |
| AVD-ServiceHealth-Planned Maintenance                                     | na                         | Service Health |  na                 |   4  |
| AVD-ServiceHealth-Security                                                | na                         | Service Health |  na                 |   4  |
| AVD-ServiceHealth-Service Issue                                           | na                         | Service Health |  na                 |   4  |

**NOTES:**

1. Alert based on associated Automation Account / Runbook
2. See ['How to create an alert if a file share is throttled'](https://docs.microsoft.com/azure/storage/files/storage-troubleshooting-files-performance#how-to-create-an-alert-if-a-file-share-is-throttled). Both Standard and Premium values are incorporated into the alert rule. Service Health alert severity cannot be changed from 'Verbose'.
3. Modified from the original baseline in this fork, see [CHANGES.md](patterns/avd/CHANGES.md)

## 📚 Documentation

- [Blog post: AVD Monitoring Baseline, Community Edition](https://modernworksplacehub.com/avd-monitoring-baseline-community-edition)
- [Deployment Guide](docs/Avd-Deploy.md)
- [What's New](docs/Whats-New.md)
- [Change log vs the original baseline](patterns/avd/CHANGES.md)
- [Update to a new release](docs/Update-to-new-Release.md)
- [Known Issues](docs/Known-Issues.md)
- [FAQ](docs/FAQ.md)
- [Telemetry / opt-out](docs/Telemetry.md)

## 🗂️ Repo structure

```text
patterns/avd/
  avdArm.json            # Generated ARM template (do not hand-edit, built from templates/deploy.bicep)
  avdCustomUi.json       # Portal custom deployment UI definition
  CHANGES.md             # All deltas from the original Microsoft baseline
  templates/deploy.bicep # The source of truth. Edit here, then rebuild
  scripts/               # Runbook scripts (host pool capacity, storage data)
docs/                    # Deployment guide and docs (from the original AMBA site)
```

To rebuild the ARM template after editing the Bicep:

```text
bicep build patterns/avd/templates/deploy.bicep --outfile patterns/avd/avdArm.json
```

## 🤝 Contributing

Issues and pull requests are welcome. If upstream AMBA resumes AVD maintenance, the intent is to contribute fixes back.

## 📄 License and attribution

Licensed under the [MIT License](LICENSE). Original work © Microsoft Corporation, from [Azure/azure-monitor-baseline-alerts](https://github.com/Azure/azure-monitor-baseline-alerts). This fork retains the original license and attribution. This project is not affiliated with or endorsed by Microsoft.
