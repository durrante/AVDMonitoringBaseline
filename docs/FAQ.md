# Frequently Asked Questions

## What are the Prerequisites?

An AVD deployment, and Owner (or User Access Administrator) in every subscription containing the selected host pools, VM resource groups and storage accounts, since the deployment creates role assignments there. You must have also pre-configured the AVD Insights as it will enable diagnostic logging for the Host Pools and associated VMs in which the alerts rely on. All selected host pools must send AVD Insights data to the single Log Analytics workspace chosen at deployment.

## What's deployed to my Subscription?

Names will be created with a standard 'avdmetrics' in the name and vary based on input for things like site, environment type, etc.

Resource Group starting with the name "rg-avdmetrics-" with the following:

- Automation Account with a Runbook (for Host Pool Information not otherwise available)
- Identity for the Automation Account in which the name will start with "aa-avdmetrics-"
- Logic App that execute every 5 minutes (Host Pool Info Runbook)

The Automation Account Identity will be assigned the following roles:

- Desktop Virtualization Reader
- Reader on the storage account resource group(s) (share usage is read via the ARM management plane, so no data-plane or write-capable role is needed)

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

- Automation Account runs a script every 5 minutes to collect additional Azure File Share data and averages around $5/month
- Alert Rules vary based on number of times triggered but estimates are under $1/mo each.
