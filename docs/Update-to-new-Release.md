# Update to a new release

## How to update to a new release

Redeploy the solution with the **Deploy to Azure** button, choosing the same resource group, Alert Name Prefix and Environment as your existing deployment. Alert rules with the same names are updated in place, new alert rules are added, and the Automation Account runbooks are replaced with the version that matches the release.

Like every alert in this solution, new alert rules deploy **disabled**. Existing alert rules are updated by the redeployment, so review them afterwards and enable the ones you want.

Check the [change log](../patterns/avd/CHANGES.md) for the release's upgrade notes before redeploying.

## Clean up after upgrading

A redeployment never deletes anything. Anything a newer release has replaced stays in place until you remove it:

- **Old metric memory alerts (deployments from before v2.3.0).** v2.3.0 replaced the metric based Available Memory alerts with log search alerts. If you deployed an earlier version, delete the old metric alert rules named `*-HP-VM-AvailMemLess-1GB-*` and `*-HP-VM-AvailMemLess-2GB-*` in your session host VM resource groups. Until you do, memory alerts arrive twice, and the old ones still fire false positives while session hosts power on. You can list them in **Resource Graph Explorer** (not Log Analytics) with:

  ```kusto
  resources
  | where type =~ 'microsoft.insights/metricalerts'
  | where name contains 'AvailMemLess'
  | project name, subscriptionId, resourceGroup, enabled = properties.enabled
  ```

- **Storage Account Contributor (deployments from before v2.5.0).** v2.5.0 reduced the storage runbook's access to Reader. Remove the old Storage Account Contributor role assignment for the Automation Account identity from the storage account resource group(s).

- **Alerts still showing as "Fired" for deleted rules.** When an alert rule is deleted, its open alerts stay in the alert history and never resolve. Close them in the Alerts view if you want a tidy list.
