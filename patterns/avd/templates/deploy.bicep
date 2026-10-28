targetScope = 'subscription'

/*
@description('Determine if you would like to enable all the alerts after deployment.')
param SetEnabled bool = false
 */

@description('Optional. Location of the runbook scripts (with trailing slash). Leave empty to use the scripts folder next to the deployed template, so a deployment from the dev branch or a tagged release uses that same version of the scripts. Falls back to the main branch on GitHub when the template is deployed from a local file.')
// Empty default (resolved in the ArtifactsLocation variable) rather than deployment().properties.templateLink.uri,
// because templateLink does not exist when deploying from a local file and the deployment would fail
#disable-next-line artifacts-parameters
param _ArtifactsLocation string = ''

@description('SaS token if needed for script location.')
@secure()
param _ArtifactsLocationSasToken string = ''

@description('Telemetry Opt-Out') // Change this to true to opt out of Microsoft Telemetry
param optoutTelemetry bool = false

@description('Alert Name Prefix (Dash will be added after prefix for you.)')
param AlertNamePrefix string = 'AVD'

@description('Optional: Customer, client or tenant name included at the top of every alert description. Useful for MSPs monitoring multiple tenants to identify which customer an alert originated from, as host pool names can be identical across tenants.')
param CustomerName string = ''

@description('Flag to determine if AVD VMs and AVD resources are all in the same Resource Group.')
param AllResourcesSameRG bool = true

@description('Determine if you would like to set all deployed alerts to auto-resolve.')
param AutoResolveAlert bool = true

@description('The email address or distribution list that receives alert notifications when a new Action Group is created. Ignored (and may be empty) when ExistingActionGroupResourceId is supplied.')
param DistributionGroup string = ''

@description('Optional. The Resource ID of an existing Action Group to use for all alert rules. Leave empty to create a new email-based Action Group using DistributionGroup.')
param ExistingActionGroupResourceId string = ''

@allowed([
  'd'
  'p'
  't'
])
@description('The environment is which these resources will be deployed, i.e. Test, Production, Development.')
param Environment string = 't'

@description('Array of objects with the Resource ID for colHostPoolName and colVMresGroup for each Host Pool.')
param HostPoolInfo array = []

@description('Host Pool Resource IDs (array)')
param HostPools array = []

@description('Optional. Resource IDs of the scaling plans assigned to the selected host pools. The Automation Account is granted Desktop Virtualization Reader on their resource groups so the scaling plan alerts can read them when a plan lives outside the host pool resource group. The portal form fills this in automatically.')
param ScalingPlanResourceIds array = []

@description('Azure Region for Resources.')
param Location string = deployment().location

@description('The Resource ID for the Log Analytics Workspace.')
param LogAnalyticsWorkspaceResourceId string

@description('Resource Group to deploy the Alerts Solution in.')
param ResourceGroupName string

//placeholder needed for template validation when VMs in separate RG selected - desktop reader deployment fails otherwise
@description('AVD Resource Group ID with ALL resources including VMs')
param AVDResourceGroupId string = '/subscriptions/<subscription ID>/resourceGroups/<Resource Group Name>'

@description('Flag to determine if a new resource group needs to be created for Alert resources.')
@allowed([
  'New'
  'Existing'
])
param ResourceGroupStatus string

@description('The Resource IDs for the Azure Files Storage Accounts used for FSLogix profile storage.')
param StorageAccountResourceIds array = []

@description('ISO 8601 timestamp used for the deployment names and the Automation runbook schedule.')
param time string = utcNow()

@description('The Resource IDs for the Azure NetApp Volumes used for FSLogix profile storage.')
param ANFVolumeResourceIds array = []

param Tags object = {}

var ActionGroupName = 'ag-avdmetrics-${Environment}-${Location}-${uniqueString(subscription().displayName)}'
var AlertDescriptionHeader = empty(CustomerName) ? 'Automated AVD Alert Deployment Solution (v2.6.2)\n' : 'Customer: ${CustomerName}\nAutomated AVD Alert Deployment Solution (v2.6.2)\n' // DESCRIPTION HEADER AND VERSION <-----------------------------
var AutomationAccountName = 'aa-avdmetrics-${Environment}-${Location}-${AlertNamePrefix}'
var CloudEnvironment = environment().name
var ResourceGroupCreate = ResourceGroupStatus == 'New' ? true : false
var RunbookNameGetStorage = 'AvdStorageLogData'
var RunbookNameGetHostPool = 'AvdHostPoolLogData'
// When deployed from a URL (Deploy to Azure button or --template-uri), Azure exposes the template's own
// address, so the runbook scripts come from the same branch or release as the template. Previously the
// scripts were always fetched from main, so testing the dev branch silently installed main's runbooks
var TemplateLinkUri = deployment().properties.?templateLink.?uri ?? ''
var ArtifactsLocation = !empty(_ArtifactsLocation)
  ? _ArtifactsLocation
  : (!empty(TemplateLinkUri)
      ? uri(TemplateLinkUri, 'scripts/')
      : 'https://raw.githubusercontent.com/durrante/AVDMonitoringBaseline/main/patterns/avd/scripts/')
var RunbookScriptGetStorage = 'Get-StorAcctInfo.ps1${_ArtifactsLocationSasToken}'
var RunbookScriptGetHostPool = 'Get-HostPoolInfo.ps1${_ArtifactsLocationSasToken}'
var StorAcctsAll = [for item in StorageAccountResourceIds: '${split(item, '/')[2]},${split(item, '/')[4]}']  //format of SubscriptionId,ResourceGroup
var StorAcctsSubRGs = union(StorAcctsAll, [])
// var UsrManagedIdentityName = 'id-ds-avdAlerts-Deployment'

var RoleAssignments = {
  DesktopVirtualizationRead: {
    Name: 'Desktop-Virtualization-Reader'
    GUID: '49a72310-ab8d-41df-bbb0-79b649203868'
  }
  StorageReader: {
    Name: 'Reader'
    GUID: 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
  }
  LogAnalyticsContributor: {
    Name: 'LogAnalytics-Contributor'
    GUID: '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
  }
}
// '49a72310-ab8d-41df-bbb0-79b649203868'  // Desktop Virtualization Reader
// 'acdd72a7-3385-48ef-bd42-f606fba81ae7'  // Reader (storage share usage is read via the ARM management plane)
// '92aaf0da-9dab-42b6-94a3-d43ce8d16293'  // Log Analtyics Contributor - allows writing to workspace for Host Pool and Storage Logic Apps

var cuaid = 'b8b4a533-1bb2-402f-bbd9-3055d00d885a'
var PidcuaAvdPatternDeploymentName = take(
  'pid-${cuaid}-${uniqueString(Location, subscription().displayName, time)}',
  64
)

var LogAlertsHostPool = [
  {
    // Based on Runbook script Output to LAW
    name: '${AlertNamePrefix}-HP-Cap-85Prcnt-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Capacity 85 Percent (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Host pool xHostPoolNamex is using between 85 and 95 percent of its session capacity.\nMetric value: the load percentage, meaning user sessions (active and disconnected) as a percentage of the sessions available on session hosts that are available and accepting new sessions.\nAction: add session hosts or capacity, check that autoscale is running, and check for session hosts that are unavailable or in drain mode. Based on the Automation Account runbook, which reports every 15 minutes. Session counts are in the alert search results.'
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | where TimeGenerated > ago(20m)
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ResourceGroup=tostring(split(ResultDescription, '|')[1])
          | extend Type=tostring(split(ResultDescription, '|')[2])
          | extend MaxSessionLimit=toint(split(ResultDescription, '|')[3])
          | extend NumberSessionHosts=toint(split(ResultDescription, '|')[4])
          | extend UserSessionsTotal=toint(split(ResultDescription, '|')[5])
          | extend UserSessionsDisconnected=toint(split(ResultDescription, '|')[6])
          | extend UserSessionsActive=toint(split(ResultDescription, '|')[7])
          | extend UserSessionsAvailable=toint(split(ResultDescription, '|')[8])
          | extend HostPoolPercentLoad=toreal(split(ResultDescription, '|')[9])
          | extend HPResourceId=tostring(split(ResultDescription, '|')[12])
          | extend ResourceId=tostring(HPResourceId)
          | where HostPoolName =~ 'xHostPoolNamex'
          // Latest runbook run only. The runbook runs every 15 minutes, so a 5 minute look-back missed it on 2 of every 3 checks
          | summarize arg_max(TimeGenerated, *) by HostPoolName
          | where HostPoolPercentLoad >= 85 and HostPoolPercentLoad < 95
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'HostPoolPercentLoad'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 85
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW
    name: '${AlertNamePrefix}-HP-Cap-50Prcnt-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Capacity 50 Percent (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Host pool xHostPoolNamex is using between 50 and 85 percent of its session capacity.\nMetric value: the load percentage, meaning user sessions (active and disconnected) as a percentage of the sessions available on session hosts that are available and accepting new sessions.\nAction: early warning only. No action is needed unless the load keeps rising towards your expected peak. Based on the Automation Account runbook, which reports every 15 minutes. Session counts are in the alert search results.'
    severity: 3
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | where TimeGenerated > ago(20m)
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ResourceGroup=tostring(split(ResultDescription, '|')[1])
          | extend Type=tostring(split(ResultDescription, '|')[2])
          | extend MaxSessionLimit=toint(split(ResultDescription, '|')[3])
          | extend NumberSessionHosts=toint(split(ResultDescription, '|')[4])
          | extend UserSessionsTotal=toint(split(ResultDescription, '|')[5])
          | extend UserSessionsDisconnected=toint(split(ResultDescription, '|')[6])
          | extend UserSessionsActive=toint(split(ResultDescription, '|')[7])
          | extend UserSessionsAvailable=toint(split(ResultDescription, '|')[8])
          | extend HostPoolPercentLoad=toreal(split(ResultDescription, '|')[9])
          | extend HPResourceId=tostring(split(ResultDescription, '|')[12])
          | extend ResourceId=tostring(HPResourceId)
          | where HostPoolName =~ 'xHostPoolNamex'
          // Latest runbook run only. The runbook runs every 15 minutes, so a 5 minute look-back missed it on 2 of every 3 checks
          | summarize arg_max(TimeGenerated, *) by HostPoolName
          | where HostPoolPercentLoad >= 50 and HostPoolPercentLoad < 85
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'HostPoolPercentLoad'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 50
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW
    name: '${AlertNamePrefix}-HP-Cap-95Prcnt-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Capacity 95 Percent (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Host pool xHostPoolNamex is using 95 percent or more of its session capacity. New users may soon be unable to connect.\nMetric value: the load percentage, meaning user sessions (active and disconnected) as a percentage of the sessions available on session hosts that are available and accepting new sessions.\nAction: add capacity now. Start or add session hosts, check that autoscale is running, and bring unavailable or drained session hosts back into service. Based on the Automation Account runbook, which reports every 15 minutes. Session counts are in the alert search results.'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT30M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | where TimeGenerated > ago(20m)
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ResourceGroup=tostring(split(ResultDescription, '|')[1])
          | extend Type=tostring(split(ResultDescription, '|')[2])
          | extend MaxSessionLimit=toint(split(ResultDescription, '|')[3])
          | extend NumberSessionHosts=toint(split(ResultDescription, '|')[4])
          | extend UserSessionsTotal=toint(split(ResultDescription, '|')[5])
          | extend UserSessionsDisconnected=toint(split(ResultDescription, '|')[6])
          | extend UserSessionsActive=toint(split(ResultDescription, '|')[7])
          | extend UserSessionsAvailable=toint(split(ResultDescription, '|')[8])
          | extend HostPoolPercentLoad=toreal(split(ResultDescription, '|')[9])
          | extend HPResourceId=tostring(split(ResultDescription, '|')[12])
          | extend ResourceId=tostring(HPResourceId)
          | where HostPoolName =~ 'xHostPoolNamex'
          // Latest runbook run only. The runbook runs every 15 minutes, so a 5 minute look-back missed it on 2 of every 3 checks
          | summarize arg_max(TimeGenerated, *) by HostPoolName
          | where HostPoolPercentLoad >= 95
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'HostPoolPercentLoad'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 95
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-NoResAvail-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-No Resources Available (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Catastrophic Event! Indicates potential problems with dependencies, diagnose and resolve for xHostPoolNamex.'
    severity: 1
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: 'WVDConnections \n| where TimeGenerated > ago (15m) \n| where _ResourceId contains "xHostPoolNamex" \n| project-away TenantId,SourceSystem  \n| summarize arg_max(TimeGenerated, *), StartTime =  min(iff(State== \'Started\', TimeGenerated , datetime(null) )), ConnectTime = min(iff(State== \'Connected\', TimeGenerated , datetime(null) ))   by CorrelationId  \n| join kind=leftouter (WVDErrors\n    |summarize Errors=makelist(pack(\'Code\', Code, \'CodeSymbolic\', CodeSymbolic, \'Time\', TimeGenerated, \'Message\', Message ,\'ServiceError\', ServiceError, \'Source\', Source)) by CorrelationId  \n    ) on CorrelationId\n| join kind=leftouter (WVDCheckpoints\n    | summarize Checkpoints=makelist(pack(\'Time\', TimeGenerated, \'Name\', Name, \'Parameters\', Parameters, \'Source\', Source)) by CorrelationId  \n    | mv-apply Checkpoints on (  \n        order by todatetime(Checkpoints[\'Time\']) asc\n        | summarize Checkpoints=makelist(Checkpoints)\n        )\n    ) on CorrelationId  \n| project-away CorrelationId1, CorrelationId2  \n| order by TimeGenerated desc\n| where Errors[0].CodeSymbolic == "ConnectionFailedNoHealthyRdshAvailable"\n\n'
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-DiscUser24Hrs-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Disconnected User over 24 Hours (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Verify Remote Desktop Policies are applied relating to Session Limits for xHostPoolNamex. This could impact your scaling plan as well.'
    severity: 2
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '// Session duration \n// Lists users by session duration in the last 24 hours. \n// The "State" provides information on the connection stage of an activity.\n// The delta between "Connected" and "Completed" provides the connection time for a specific connection.\nWVDConnections \n| where TimeGenerated > ago(24h) \n| where State == "Connected" \n| where _ResourceId contains "xHostPoolNamex" \n| project CorrelationId , UserName, ConnectionType, StartTime=TimeGenerated, SessionHostName\n| join (WVDConnections  \n    | where State == "Completed"  \n    | project EndTime=TimeGenerated, CorrelationId)  \n    on CorrelationId  \n| project Duration = EndTime - StartTime, ConnectionType, UserName, SessionHostName\n| where Duration >= timespan(24:00:00)\n| sort by Duration desc'
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-DiscUser72Hrs-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Disconnected User over 72 Hours (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Verify Remote Desktop Policies are applied relating to Session Limits for xHostPoolNamex. This could impact your scaling plan as well.'
    severity: 1
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '// Session duration \n// Lists users by session duration in the last 24 hours. \n// The "State" provides information on the connection stage of an activity.\n// The delta between "Connected" and "Completed" provides the connection time for a specific connection.\nWVDConnections \n| where TimeGenerated > ago(24h) \n| where State == "Connected" \n| where _ResourceId contains "xHostPoolNamex"  \n| project CorrelationId , UserName, ConnectionType, StartTime=TimeGenerated, SessionHostName\n| join (WVDConnections  \n    | where State == "Completed"  \n    | project EndTime=TimeGenerated, CorrelationId)  \n    on CorrelationId  \n| project Duration = EndTime - StartTime, ConnectionType, UserName, SessionHostName\n| where Duration >= timespan(72:00:00)\n| sort by Duration desc'
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-LocDskFree10Prcnt-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Local Disk Free Space 10 Percent (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}A session host in xHostPoolNamex has 10 percent or less free space on a local disk (the temporary D: drive is excluded).\nMetric value: the free space percentage reported by the session host.\nAction: find what is using the space, such as local profiles, temp files, logs or update caches, then clean up or expand the disk.'
    severity: 2
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          Perf
          | where TimeGenerated > ago(15m)
          | where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
          | where InstanceName !contains "D:"
          | where InstanceName  !contains "_Total"| where CounterValue <= 10.00
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | summarize arg_max(TimeGenerated, *) by ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, CounterValue, subscription, ResourceGroup, TimeGenerated
          | join kind = leftouter
          (
              WVDAgentHealthStatus
              | where TimeGenerated > ago(15m)
              | where _ResourceId contains "xHostPoolNamex"
              | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
              | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
              | extend ComputerName=tolower(ComputerName)
              | summarize arg_max(TimeGenerated,*) by ComputerName
              | project VMresourceGroup, ComputerName, HostPool, _ResourceId
              ) on ComputerName
          | where ComputerName1 contains ComputerName
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'CounterValue'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'LessThanOrEqual'
          threshold: 10
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-LocDskFree5Prcnt-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Local Disk Free Space 5 Percent (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}A session host in xHostPoolNamex has 5 percent or less free space on a local disk (the temporary D: drive is excluded). Applications, Windows updates and sign-ins can fail when the disk fills.\nMetric value: the free space percentage reported by the session host.\nAction: free up space now, for example local profiles, temp files, logs or update caches, or expand the disk.'
    severity: 1
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          Perf
          | where TimeGenerated > ago(15m)
          | where ObjectName == "LogicalDisk" and CounterName == "% Free Space"
          | where InstanceName !contains "D:"
          | where InstanceName  !contains "_Total"| where CounterValue <= 5.00
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | summarize arg_max(TimeGenerated, *) by ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, CounterValue, subscription, ResourceGroup, TimeGenerated
          | join kind = leftouter
          (
              WVDAgentHealthStatus
              | where TimeGenerated > ago(15m)
              | where _ResourceId contains "xHostPoolNamex"
              | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
              | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
              | extend ComputerName=tolower(ComputerName)
              | summarize arg_max(TimeGenerated,*) by ComputerName
              | project VMresourceGroup, ComputerName, HostPool, _ResourceId
              ) on ComputerName
          | where ComputerName1 contains ComputerName
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'CounterValue'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'LessThanOrEqual'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf5PrcntFree-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Less Than 5 Percent Free Space (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profiles Service logged Event ID 33. Expand User\'s Virtual Profile Disk and/or clean up user profile data on the VM in xHostPoolNamex.'
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Warning"
          | where EventID == 34
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf2PrcntFree-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Less Than 2 Percent Free Space (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profiles Service logged Event ID 34. Expand User\'s Virtual Profile Disk and/or clean up user profile data on the VM in xHostPoolNamex.'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Error"
          | where EventID == 33
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf-NetwrkIssue-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Failed due to Network Issue (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profiles Service logged Event ID 43. Verify network communications between the storage and AVD VM related to xHostPoolNamex.'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Error"
          | where EventID == 43
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf-FailAttVHD-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Disk Failed to Attach (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profiles Service logged an Event ID 52 or 40. Investigate error details for reason regarding xHostPoolNamex.'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Error"
          | where EventID == 52 or EventID == 40
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf-SvcDisabled-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Service Disabled (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profile Service Disabled. Determine why service was disabled and re-enable / start the FSLogix service. Regarding xHostPoolNamex'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Warning"
          | where EventID == 60
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
              '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf-DskCmpFail-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Disk Compaction Failed (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profile Service logged Event ID 62 or 63. The profile Disk was marked for compaction due to additional white space but failed. See error details for additional information regarding xHostPoolNamex.'
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Admin"
          | where EventLevelName == "Error"
          | where EventID == 62 or EventID == 63
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | project ComputerName, RenderedDescription, UserName, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-FSLgxProf-DskInUse-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-FSLogix Profile Disk Attached to another VM (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}User Profile Service logged an Event ID 51. This indicates that a user attempted to load their profile disk but it was in use or possibly mapped to another VM. Ensure the user is not connected to another host pool or remote app with the same profile. Regarding xHostPoolNamex.'
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          Event
          | where EventLog == "Microsoft-FSLogix-Apps/Operational"
          | where EventLevelName == "Warning"
          | where EventID == 51
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | extend ProfilePath = extract(@"<Param>([\\\\][^<]+\.VHDX?)<\/Param>", 1, ParameterXml)
          | project ComputerName, UserName, ProfilePath, RenderedDescription, subscription, ResourceGroup, TimeGenerated
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, UserName, ProfilePath, RenderedDescription
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RenderedDescription'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ProfilePath'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: '_ResourceId'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-AvailMemLess-2GB-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Available Memory Less Than 2GB (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}A session host in xHostPoolNamex has averaged 2 GB or less of available memory over the last 15 minutes. This can slow down every user on that host.\nMetric value: that 15 minute average, in MB. Session hosts that have reported for less than 10 minutes are ignored, so hosts that have just powered on do not raise this alert.\nAction: check which users and processes are using the memory (including disconnected sessions), and whether the host pool maximum sessions per host suits the VM size. One alert is raised per session host and stays open until memory recovers.'
    severity: 2
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: '''
          Perf
          | where TimeGenerated > ago(15m)
          | where ObjectName == "Memory" and CounterName == "Available MBytes"
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | summarize AvailableMB = round(avg(CounterValue), 0), FirstSample = min(TimeGenerated), TimeGenerated = max(TimeGenerated) by ComputerName, subscription, ResourceGroup
          | where FirstSample <= ago(10m)
          | where AvailableMB <= 2048
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, AvailableMB
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'AvailableMB'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'LessThanOrEqual'
          threshold: 2048
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-AvailMemLess-1GB-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Available Memory Less Than 1GB (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}A session host in xHostPoolNamex has averaged 1 GB or less of available memory over the last 15 minutes. Users on that host are likely to see slowdowns, hangs or application crashes.\nMetric value: that 15 minute average, in MB. Session hosts that have reported for less than 10 minutes are ignored, so hosts that have just powered on do not raise this alert.\nAction: investigate now. Consider drain mode to stop new sessions landing on the host, sign out disconnected sessions, and check which processes are using the memory. One alert is raised per session host and stays open until memory recovers.'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      allOf: [
        {
          query: '''
          Perf
          | where TimeGenerated > ago(15m)
          | where ObjectName == "Memory" and CounterName == "Available MBytes"
          | parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" ResourceGroup "/providers/microsoft.compute/virtualmachines/" ComputerName
          | extend ComputerName=tolower(ComputerName)
          | summarize AvailableMB = round(avg(CounterValue), 0), FirstSample = min(TimeGenerated), TimeGenerated = max(TimeGenerated) by ComputerName, subscription, ResourceGroup
          | where FirstSample <= ago(10m)
          | where AvailableMB <= 1024
          | join kind = inner
              (
                WVDAgentHealthStatus
                | where _ResourceId contains "xHostPoolNamex"
                | parse _ResourceId with "/subscriptions/" subscriptionAgentHealth "/resourcegroups/" ResourceGroupAgentHealth "/providers/microsoft.desktopvirtualization/hostpools/" HostPool
                | parse SessionHostResourceId with "/subscriptions/" VMsubscription "/resourceGroups/" VMresourceGroup "/providers/Microsoft.Compute/virtualMachines/" ComputerName
                | extend ComputerName=tolower(ComputerName)
                | summarize arg_max(TimeGenerated,*) by ComputerName
                | project VMresourceGroup, ComputerName, HostPool
              ) on ComputerName
          | project TimeGenerated, ComputerName, HostPool, VMresourceGroup, AvailableMB
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'AvailableMB'
          dimensions: [
            {
              name: 'ComputerName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'VMresourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'LessThanOrEqual'
          threshold: 1024
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-HlthChkFailure-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Health Check Failure (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}VM is available for use but one of the dependent resources is in a failed state for hostpool xHostPoolNamex'
    severity: 1
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '// HealthChecks of SessionHost \n// Renders a summary of SessionHost health status. \nlet MapToDesc = (idx: long) {\n    case(idx == 0, "DomainJoin",\n    idx == 1, "DomainTrust",\n    idx == 2, "FSLogix",\n    idx == 3, "SxSStack",\n    idx == 4, "URLCheck",\n    idx == 5, "GenevaAgent",\n    idx == 6, "DomainReachable",\n    idx == 7, "WebRTCRedirector",\n    idx == 8, "SxSStackEncryption",\n    idx == 9, "IMDSReachable",\n    idx == 10, "MSIXPackageStaging",\n    idx == 11, "TURNRelayAccessHealthCheck",\n    idx == 19, "AADJoinedHealthCheck",\n    "InvalidIndex")\n};\nWVDAgentHealthStatus\n| where TimeGenerated > ago(10m)\n| where Status != \'Available\'\n| where AllowNewSessions = True\n| extend CheckFailed = parse_json(SessionHostHealthCheckResult)\n| mv-expand CheckFailed\n| where CheckFailed.AdditionalFailureDetails.ErrorCode != 0\n| extend HealthCheckName = tolong(CheckFailed.HealthCheckName)\n| extend HealthCheckResult = tolong(CheckFailed.HealthCheckResult)\n| extend HealthCheckDesc = MapToDesc(HealthCheckName)\n| where HealthCheckDesc != \'InvalidIndex\'\n| where _ResourceId contains "xHostPoolNamex"\n| parse _ResourceId with "/subscriptions/" subscription "/resourcegroups/" HostPoolResourceGroup "/providers/microsoft.desktopvirtualization/hostpools/" HostPool\n| parse SessionHostResourceId with "/subscriptions/" HostSubscription "/resourceGroups/" SessionHostRG "/providers/Microsoft.Compute/virtualMachines/" SessionHostName\n'
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HealthCheckDesc'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostRG'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-PersnlAssigndUnhlthy-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Personal Assigned Health Check Failure (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}VM is assigned to a user but one of the dependent resources is in a failed state for hostpool xHostPoolNamex'
    severity: 1
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          // Personal Session Host where Health status is NOT healthy and the VM is assigned
          AzureDiagnostics
          | where Category has "JobStreams"
              and StreamType_s == "Output"
              and RunbookName_s == "AvdHostPoolLogData"
          | sort by TimeGenerated
          | where TimeGenerated > ago(15m)
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ResourceGroup=tostring(split(ResultDescription, '|')[1])
          | extend Type=tostring(split(ResultDescription, '|')[2])
          | extend NumberSessionHosts=toint(split(ResultDescription, '|')[4])
          | extend UserSessionsActive=toint(split(ResultDescription, '|')[7])
          | extend NumPersonalUnhealthy=toint(split(ResultDescription, '|')[10])
          | extend PersonalSessionHost=extract_json("$.SessionHost", tostring(split(ResultDescription, '|')[11]), typeof(string))
          | extend PersonalAssignedUser=extract_json("$.AssignedUser", tostring(split(ResultDescription, '|')[11]), typeof(string))
          | where HostPoolName =~ 'xHostPoolNamex'
          | where Type == 'Personal'
          | where NumPersonalUnhealthy > 0
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'PersonalSessionHost'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'PersonalAssignedUser'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-Usr-ConnctnFailed-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-User-Connection Failed (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}While trying to connect to xHostPoolNamex a user had an error and failed to connect to a VM. There are lots of variables between the end uers and AVD VMs. If this is frequent for the user, determine if their Internet connection is slow or latency is over 150 ms. Regarding xHostPoolNamex.'
    severity: 3
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          // Connection Errors
          // List connection checkpoints and errors for each connection attempt, along with detailed information across all users.
          //You can also uncomment the where clause to filter to a specific user if you are troubleshooting an issue.
          WVDConnections
          //| where UserName == "upn.here@contoso.com"
          | project-away TenantId,SourceSystem
          | summarize arg_max(TimeGenerated, *), StartTime = min(iff(State=='Started', TimeGenerated , datetime(null) )), ConnectTime = min(iff(State=='Connected', TimeGenerated , datetime(null) )) by CorrelationId
          | join kind=leftouter
          (
              WVDErrors
              |summarize Errors=make_list(pack('Code', Code, 'CodeSymbolic', CodeSymbolic, 'Time', TimeGenerated, 'Message', Message ,'ServiceError', ServiceError, 'Source', Source)) by CorrelationId
          ) on CorrelationId
          | join kind=leftouter
          (
              WVDCheckpoints
              | summarize Checkpoints=make_list(pack('Time', TimeGenerated, 'Name', Name, 'Parameters', Parameters, 'Source', Source)) by CorrelationId
              | mv-apply Checkpoints on
              (
                  order by todatetime(Checkpoints['Time']) asc
                  | summarize Checkpoints=make_list(Checkpoints)
              )
          ) on CorrelationId
          | project-away CorrelationId1, CorrelationId2
          | order by TimeGenerated desc
          | where TimeGenerated > ago(15m)
          | extend ResourceGroup=tostring(split(_ResourceId, '/')[4])
          | extend HostPool=tostring(split(_ResourceId, '/')[8])
          | where HostPool =~ 'xHostPoolNamex'
          | where isnotempty(Errors)
          | extend ErrorShort=tostring(Errors[0].CodeSymbolic)
          | extend ErrorMessage=tostring(Errors[0].Message)
          | project TimeGenerated, HostPool, ResourceGroup, UserName, ClientOS, ClientVersion, ClientSideIPAddress, ConnectionType, ErrorShort, ErrorMessage
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ResourceGroup'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UserName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ClientOS'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ClientVersion'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ClientSideIPAddress'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ConnectionType'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ErrorShort'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ErrorMessage'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW (ScalingPlanName and ScalingPlanState are fields 13 and 14)
    name: '${AlertNamePrefix}-HP-ScalPlanDisabled4Hrs-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Scaling Plan Disabled over 4 Hours (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Autoscale has been disabled for host pool xHostPoolNamex on its scaling plan host pool assignment for over 4 hours. While disabled, autoscale does not start or stop session hosts, so hosts can be left running (cost) or not started when users need them (capacity). If this is planned maintenance, re-enable autoscale on the scaling plan host pool assignment when the work is complete, or suppress this alert for the maintenance window with an alert processing rule. Based on the Automation Account runbook output, which checks the scaling plan every 15 minutes.\nWho and when: open the scaling plan (shown in ScalingPlanName) and go to Activity log. Look for Create or Update Scaling Plan around the time autoscale was turned off. Event initiated by shows who made the change, and the Change history tab shows scalingPlanEnabled changing to false. For the exact time, see the FAQ entry Who disabled the scaling plan, and when? at https://github.com/durrante/AVDMonitoringBaseline/blob/main/docs/FAQ.md'
    severity: 3
    evaluationFrequency: 'PT30M'
    windowSize: 'PT4H'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where TimeGenerated > ago(4h)
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ScalingPlanName=trim(@"\s", tostring(split(ResultDescription, '|')[13]))
          | extend ScalingPlanState=trim(@"\s", tostring(split(ResultDescription, '|')[14]))
          | where HostPoolName =~ 'xHostPoolNamex'
          // Every runbook run in the window must report Disabled, and at least 12 of the 16 runs expected
          // in 4 hours must have arrived, so a runbook outage or failed lookup (Unknown) never raises the alert
          | summarize RunCount=count(), DisabledRuns=countif(ScalingPlanState == 'Disabled'), ScalingPlanName=take_anyif(ScalingPlanName, ScalingPlanState == 'Disabled') by HostPoolName
          | where RunCount >= 12 and DisabledRuns == RunCount
          | project HostPoolName, ScalingPlanName
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ScalingPlanName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW (ScalingPlanName and ScalingPlanState are fields 13 and 14)
    name: '${AlertNamePrefix}-HP-ScalPlanDisabled24Hrs-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Scaling Plan Disabled over 24 Hours (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Autoscale has been disabled for host pool xHostPoolNamex on its scaling plan host pool assignment for over 24 hours. This usually means autoscale was turned off for maintenance and not turned back on: session hosts may be running outside working hours (cost) or not starting when users need them (capacity). Re-enable autoscale on the scaling plan host pool assignment. If the plan is intentionally disabled long term, disable this alert rule for this host pool. Evaluated every 6 hours so an intentionally disabled plan does not notify every hour when auto-resolve is turned off.\nWho and when: open the scaling plan (shown in ScalingPlanName) and go to Activity log. Look for Create or Update Scaling Plan around the time autoscale was turned off. Event initiated by shows who made the change, and the Change history tab shows scalingPlanEnabled changing to false. For the exact time, see the FAQ entry Who disabled the scaling plan, and when? at https://github.com/durrante/AVDMonitoringBaseline/blob/main/docs/FAQ.md'
    severity: 2
    evaluationFrequency: 'PT6H'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where TimeGenerated > ago(24h)
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ScalingPlanName=trim(@"\s", tostring(split(ResultDescription, '|')[13]))
          | extend ScalingPlanState=trim(@"\s", tostring(split(ResultDescription, '|')[14]))
          | where HostPoolName =~ 'xHostPoolNamex'
          // Every runbook run in the window must report Disabled, and at least 72 of the 96 runs expected
          // in 24 hours must have arrived, so a runbook outage or failed lookup (Unknown) never raises the alert
          | summarize RunCount=count(), DisabledRuns=countif(ScalingPlanState == 'Disabled'), ScalingPlanName=take_anyif(ScalingPlanName, ScalingPlanState == 'Disabled') by HostPoolName
          | where RunCount >= 72 and DisabledRuns == RunCount
          | project HostPoolName, ScalingPlanName
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ScalingPlanName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW (ScalingPlanName and ScalingPlanState are fields 13 and 14)
    name: '${AlertNamePrefix}-HP-ScalPlanRemoved-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Scaling Plan Removed (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Host pool xHostPoolNamex had a scaling plan assigned, and for the last 4 hours it has had none. Without a scaling plan, autoscale does not start or stop session hosts for this host pool. If the removal was not intended, assign the scaling plan (shown in RemovedScalingPlan) to the host pool again. This can also be raised if the Automation Account identity lost read access to the scaling plan, or the scaling plan was moved to another resource group: redeploy the solution so access is granted again. This is a one-time change notification: it fires once per removal and closes at the next hourly check, so a resolved notice does NOT mean a scaling plan was reassigned.\nWho and when: open the scaling plan (shown in RemovedScalingPlan) and go to Activity log. Look for Create or Update Scaling Plan shortly after LastSeenWithPlan. Event initiated by shows who made the change, and the Change history tab shows the host pool removed from hostPoolReferences. If the scaling plan itself was deleted, look for Delete Scaling Plan in the resource group Activity log instead.'
    severity: 3
    evaluationFrequency: 'PT1H'
    windowSize: 'PT6H'
    criteria: {
      allOf: [
        {
          query: '''
          let RunbookRuns = AzureDiagnostics
          | where TimeGenerated > ago(6h)
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend ScalingPlanName=trim(@"\s", tostring(split(ResultDescription, '|')[13]))
          | extend ScalingPlanState=trim(@"\s", tostring(split(ResultDescription, '|')[14]))
          | where HostPoolName =~ 'xHostPoolNamex';
          let LastWithPlan = RunbookRuns
          | where ScalingPlanState in ('Enabled', 'Disabled')
          | summarize arg_max(TimeGenerated, ScalingPlanName) by HostPoolName;
          let RecentRuns = RunbookRuns
          | where TimeGenerated > ago(4h)
          | summarize RunCount=count(), NoPlanRuns=countif(ScalingPlanState == 'None') by HostPoolName;
          LastWithPlan
          | join kind=inner RecentRuns on HostPoolName
          // Every run in the last 4 hours explicitly reported no plan (not Unknown), with at least 12 of the
          // 16 expected runs present. Fires once per removal: only while the last run that still saw a plan
          // is between 4 hours and 5 hours 10 minutes old, which the hourly check passes through once
          | where RunCount >= 12 and NoPlanRuns == RunCount
          | where TimeGenerated between (ago(310m) .. ago(4h))
          | project HostPoolName, RemovedScalingPlan=ScalingPlanName, LastSeenWithPlan=tostring(TimeGenerated)
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'RemovedScalingPlan'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'LastSeenWithPlan'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-AgentUpgrdFailed-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Agent Upgrade Failed or Stuck (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}The Azure Virtual Desktop agent on a session host in xHostPoolNamex failed to upgrade (and has not recovered for over an hour), or has been stuck upgrading for over 2 hours. Existing and new user sessions are not affected straight away, but the host falls behind on agent versions and the failure often points to an underlying problem such as low disk space or security software blocking the agent. See https://learn.microsoft.com/troubleshoot/azure/virtual-desktop/troubleshoot-agent. Hosts in drain mode are excluded. An UpgradeState of Pending is normal (the update is waiting for its window) and never raises this alert.'
    severity: 3
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: '''
          WVDAgentHealthStatus
          | where TimeGenerated > ago(1h)
          | extend HostPool=tostring(split(_ResourceId, '/')[8])
          | where HostPool =~ 'xHostPoolNamex'
          | summarize arg_max(TimeGenerated, *) by SessionHostName
          // Drained hosts are excluded: they are often on their way out of service, and a host left
          // drained and idle for a day is covered by the Drained and Idle alert
          | where AllowNewSessions =~ 'True'
          | extend UpgradeFailed = Status in~ ('UpgradeFailed', 'Upgrade Failed') or UpgradeState =~ 'Failed'
          | extend UpgradeStuck = Status =~ 'Upgrading'
          // LastUpgradeTimeStamp is when the upgrade state last changed: allow a failed upgrade 1 hour to
          // retry, and a running upgrade 2 hours to finish. Pending and Initial upgrade states never alert
          | where (UpgradeFailed and (isnull(LastUpgradeTimeStamp) or LastUpgradeTimeStamp < ago(1h)))
              or (UpgradeStuck and LastUpgradeTimeStamp < ago(2h))
          | extend Problem=iff(UpgradeStuck, 'Stuck upgrading', 'Upgrade failed')
          | parse SessionHostResourceId with "/subscriptions/" HostSubscription "/resourceGroups/" SessionHostRG "/providers/Microsoft.Compute/virtualMachines/" VMName
          | project TimeGenerated, SessionHostName, HostPool, SessionHostRG, Problem, AgentVersion, UpgradeErrorMsg
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostRG'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'Problem'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'AgentVersion'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'UpgradeErrorMsg'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-VM-DrainedIdle24Hrs-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-VM-Drained and Idle over 24 Hours (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}A session host in xHostPoolNamex has been in drain mode, powered on and without any user sessions for over 24 hours. It cannot take new users and is costing compute while idle, which usually means drain mode was turned on for troubleshooting or maintenance and not turned off. Turn off drain mode, deallocate the VM, or remove it from the host pool. Drained hosts that are switched off are deliberately ignored, as they only cost disk storage. If a host is meant to stay drained and running, suppress it with an alert processing rule filtered on the host name.'
    severity: 3
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    criteria: {
      allOf: [
        {
          query: '''
          WVDAgentHealthStatus
          | where TimeGenerated > ago(24h)
          | extend HostPool=tostring(split(_ResourceId, '/')[8])
          | where HostPool =~ 'xHostPoolNamex'
          | summarize RowCount=count(),
              DrainedRows=countif(AllowNewSessions =~ 'False'),
              MaxSessions=max(toint(ActiveSessions) + toint(InactiveSessions)),
              HoursReporting=dcount(bin(TimeGenerated, 1h)),
              LastSeen=max(TimeGenerated),
              SessionHostResourceId=take_any(SessionHostResourceId)
              by SessionHostName, HostPool
          // Drained in every report for 24 hours, no user sessions at any point, powered on throughout
          // (reporting in at least 22 of the hourly periods) and still running now
          | where DrainedRows == RowCount and MaxSessions == 0
          | where HoursReporting >= 22 and LastSeen > ago(1h)
          | parse SessionHostResourceId with "/subscriptions/" HostSubscription "/resourceGroups/" SessionHostRG "/providers/Microsoft.Compute/virtualMachines/" VMName
          | project SessionHostName, HostPool, SessionHostRG
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'SessionHostName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'SessionHostRG'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    name: '${AlertNamePrefix}-HP-AutoscaleFailures-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Autoscale Failures (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Autoscale is enabled for host pool xHostPoolNamex but every evaluation in the last hour failed (at least 2), so session hosts may not be starting or stopping as scheduled. Common causes: the Azure Virtual Desktop service principal is missing the Desktop Virtualization Power On Off Contributor role, insufficient VM capacity or quota in the region, a resource lock, or an Azure Policy blocking the action. Query WVDErrors by CorrelationId for details. REQUIRES the "Autoscale logs for pooled host pools" category in the host pool diagnostic settings (pooled host pools only); without it this alert never fires. Tip: during session host replacement, tag outgoing hosts with the scaling plan exclusion tag to avoid failed actions against VMs being deleted.'
    severity: 3
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: '''
          let Evaluations = WVDAutoscaleEvaluationPooled
          | where TimeGenerated > ago(1h)
          | extend HostPool=tostring(split(_ResourceId, '/')[8])
          | where HostPool =~ 'xHostPoolNamex';
          let LastFailure = Evaluations
          | where ResultType != 'Succeeded'
          | summarize arg_max(TimeGenerated, CorrelationId) by HostPool
          | join kind=leftouter (
              WVDErrors
              | where TimeGenerated > ago(1h)
              | summarize arg_max(TimeGenerated, CodeSymbolic) by CorrelationId
            ) on CorrelationId
          | project HostPool, LastErrorCode=coalesce(CodeSymbolic, 'See WVDErrors');
          Evaluations
          | summarize EvaluationCount=count(), FailedCount=countif(ResultType != 'Succeeded'), ScalingPlanResourceId=take_any(ScalingPlanResourceId) by HostPool
          // At least 2 failed evaluations and none successful in the hour. Overnight, autoscale can log as few
          // as 2 evaluations an hour, so a fixed failure count would miss problems; a single success clears it,
          // which absorbs one-off failures such as a VM being deleted during host replacement
          | where FailedCount >= 2 and FailedCount == EvaluationCount
          | join kind=inner LastFailure on HostPool
          | extend ScalingPlanName=tostring(split(ScalingPlanResourceId, '/')[-1])
          | project HostPool, ScalingPlanName, FailedCount, LastErrorCode
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPool'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'ScalingPlanName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Combines Runbook script Output (reads ARM, not diagnostics) with the host pool diagnostic data
    name: '${AlertNamePrefix}-HP-DiagDataNotRcvd-xHostPoolNamex'
    displayName: '${AlertNamePrefix}-HostPool-Diagnostic Data Not Received (xHostPoolNamex)'
    description: '${AlertDescriptionHeader}Host pool xHostPoolNamex has had user sessions for the past hour, so session hosts are running, but no agent health data (WVDAgentHealthStatus) has reached the Log Analytics workspace in that time. Most log based alerts in this solution depend on this data, so they cannot fire for this host pool until it is fixed. Check the host pool diagnostic settings still exist and send the AgentHealthStatus, Checkpoint, Connection, Error, HostRegistration and Management categories to the workspace used by this solution. A common cause is a host pool redeployed from code that does not include its diagnostic settings, or an Azure Policy overwriting them.'
    severity: 2
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    criteria: {
      allOf: [
        {
          query: '''
          let AgentHealthRows = toscalar(
              WVDAgentHealthStatus
              | where TimeGenerated > ago(1h)
              | where tostring(split(_ResourceId, '/')[8]) =~ 'xHostPoolNamex'
              | count);
          AzureDiagnostics
          | where TimeGenerated > ago(1h)
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdHostPoolLogData"
          | extend HostPoolName=tostring(split(ResultDescription, '|')[0])
          | extend UserSessionsTotal=toint(split(ResultDescription, '|')[5])
          | where HostPoolName =~ 'xHostPoolNamex'
          // The runbook saw user sessions in every run for the past hour (at least 3 of the 4 expected runs),
          // yet the host pool sent no agent health data, which running session hosts report every 30 seconds.
          // Pools that scale to zero have no sessions overnight, so they never raise this alert
          | summarize RunCount=count(), RunsWithSessions=countif(UserSessionsTotal > 0) by HostPoolName
          | where RunCount >= 3 and RunsWithSessions == RunCount
          | where AgentHealthRows == 0
          | project HostPoolName
          '''
          timeAggregation: 'Count'
          dimensions: [
            {
              name: 'HostPoolName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
]

var LogAlertsStorage = [
  {
    // Based on Runbook script Output to LAW
    name: '${AlertNamePrefix}-StorLowSpaceAzFile-15PrcntRem-${uniqueString(subscription().displayName)}'
    displayName: '${AlertNamePrefix}-Storage-Low Space on Azure File Share-15 Percent Remaining'
    description: '${AlertDescriptionHeader}An Azure Files share used for AVD (FSLogix profiles or app attach) has 15 percent or less of its quota remaining. The storage account and share are in the alert details.\nMetric value: the percentage of the share quota remaining.\nAction: increase the share quota or free up space, for example by removing profiles of users who have left. Based on the Automation Account runbook, which reads share usage through the Azure management plane, so it works with storage firewalls and private endpoints.'
    severity: 2
    evaluationFrequency: 'PT10M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdStorageLogData"
          | where split(ResultDescription, ',')[1] <> ""
          //  StorageType / Subscription / RG / StorAcct / Share / Quota / GB Used / %Available
          | extend StorageType=split(ResultDescription, ',')[0]
          | extend Subscription=split(ResultDescription, ',')[1]
          | extend ResourceGroup=split(ResultDescription, ',')[2]
          | extend StorageAccount=tostring(split(ResultDescription, ',')[3])
          | extend Share=tostring(split(ResultDescription, ',')[4])
          | extend GBShareQuota=split(ResultDescription, ',')[5]
          | extend GBUsed=split(ResultDescription, ',')[6]
          | extend PercentAvailable=round(toreal(split(ResultDescription, ',')[7]))
          | extend ResourceId=tostring(split(ResultDescription, ',')[8])
          | summarize arg_max(TimeGenerated, *) by Share
          | where PercentAvailable <= 15.00
          | project TimeGenerated,ResourceId, StorageAccount, Share, PercentAvailable
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'PercentAvailable'
          dimensions: [
            {
              name: 'StorageAccount'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'Share'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'LessThanOrEqual'
          threshold: 15
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
  {
    // Based on Runbook script Output to LAW
    name: '${AlertNamePrefix}-StorLowSpaceAzFile-5PrcntRem-${uniqueString(subscription().displayName)}'
    displayName: '${AlertNamePrefix}-Storage-Low Space on Azure File Share-5 Percent Remaining'
    description: '${AlertDescriptionHeader}An Azure Files share used for AVD (FSLogix profiles or app attach) has 5 percent or less of its quota remaining. When the share fills, users can fail to sign in or lose profile changes. The storage account and share are in the alert details.\nMetric value: the percentage of the share quota remaining.\nAction: increase the share quota now, then free up space, for example by removing profiles of users who have left. Based on the Automation Account runbook, which reads share usage through the Azure management plane, so it works with storage firewalls and private endpoints.'
    severity: 1
    evaluationFrequency: 'PT10M'
    windowSize: 'PT1H'
    overrideQueryTimeRange: 'P2D'
    criteria: {
      allOf: [
        {
          query: '''
          AzureDiagnostics
          | where Category has "JobStreams" and StreamType_s == "Output" and RunbookName_s == "AvdStorageLogData"
          | where split(ResultDescription, ',')[1] <> ""
          //  StorageType / Subscription / RG / StorAcct / Share / Quota / GB Used / %Available
          | extend StorageType=split(ResultDescription, ',')[0]
          | extend Subscription=split(ResultDescription, ',')[1]
          | extend ResourceGroup=split(ResultDescription, ',')[2]
          | extend StorageAccount=tostring(split(ResultDescription, ',')[3])
          | extend Share=tostring(split(ResultDescription, ',')[4])
          | extend GBShareQuota=split(ResultDescription, ',')[5]
          | extend GBUsed=split(ResultDescription, ',')[6]
          | extend PercentAvailable=round(toreal(split(ResultDescription, ',')[7]))
          | extend ResourceId=tostring(split(ResultDescription, ',')[8])
          | summarize arg_max(TimeGenerated, *) by Share
          | where PercentAvailable <= 5.00
          | project TimeGenerated,ResourceId, StorageAccount, Share, PercentAvailable
          '''
          // Measure the value instead of splitting by it: a dimension whose value changes at every check opens a new alert every time
          timeAggregation: 'Minimum'
          metricMeasureColumn: 'PercentAvailable'
          dimensions: [
            {
              name: 'StorageAccount'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'Share'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          resourceIdColumn: 'ResourceId'
          operator: 'LessThanOrEqual'
          threshold: 5
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
  }
]
var MetricAlerts = {
  storageAccounts: [
    {
      name: '${AlertNamePrefix}-StorAcct-Ovr-50msLatncy'
      displayName: '${AlertNamePrefix}-Storage-Over 50ms Latency for Storage Acct'
      description: '${AlertDescriptionHeader}\nThis could indicate a lag or poor performance for user Profiles or Apps using MSIX App Attach.\nThis alert is specific to the Storage Account itself and does not include network latency.\nFor additional details on troubleshooting see:\n"https://learn.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-performance#very-high-latency-for-requests"'
      severity: 2
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 50
            name: 'Metric1'
            metricName: 'SuccessServerLatency'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts'
    }
    {
      name: '${AlertNamePrefix}-StorAcct-Ovr-100msLatncy'
      displayName: '${AlertNamePrefix}-Storage-Over 100ms Latency for Storage Acct'
      description: '${AlertDescriptionHeader}\nThis could indicate a lag or poor performance for user Profiles or Apps using MSIX App Attach.\nThis alert is specific to the Storage Account itself and does not include network latency.\nFor additional details on troubleshooting see:\n"https://learn.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-performance#very-high-latency-for-requests"'
      severity: 1
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 100
            name: 'Metric1'
            metricName: 'SuccessServerLatency'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts'
    }
    {
      name: '${AlertNamePrefix}-StorAcct-Ovr-50msLatncyClnt-Stor'
      displayName: '${AlertNamePrefix}-Storage-Over 50ms Latency Between Client-Storage'
      description: '${AlertDescriptionHeader}\nThis could indicate a lag or poor performance for user Profiles or Apps using MSIX App Attach.\nThis is a total latency from end to end between the Host VM and Storage to include network.\nFor additional details on troubleshooting see:\n"https://learn.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-performance#very-high-latency-for-requests"'
      severity: 2
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 50
            name: 'Metric1'
            metricName: 'SuccessE2ELatency'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts'
    }
    {
      name: '${AlertNamePrefix}-StorAcct-Ovr-100msLatncyClnt-Stor'
      displayName: '${AlertNamePrefix}-Storage-Over 100ms Latency Between Client-Storage'
      description: '${AlertDescriptionHeader}\nThis could indicate a lag or poor performance for user Profiles or Apps using MSIX App Attach.\nThis is a total latency from end to end between the Host VM and Storage to include network.\nFor additional details on troubleshooting see:\n"https://learn.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-performance#very-high-latency-for-requests"'
      severity: 1
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 100
            name: 'Metric1'
            metricName: 'SuccessE2ELatency'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts'
    }
    {
      name: '${AlertNamePrefix}-StorAzFilesAvailBlw-99-Prcnt'
      displayName: '${AlertNamePrefix}-Storage-Azure Files Availability'
      description: '${AlertDescriptionHeader}\nThis could indicate storage is unavailable for user Profiles or Apps using MSIX App Attach.'
      severity: 1
      evaluationFrequency: 'PT5M'
      windowSize: 'PT5M'
      criteria: {
        allOf: [
          {
            threshold: 99
            name: 'Metric1'
            metricName: 'Availability'
            operator: 'LessThanOrEqual'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts'
    }
  ]
  fileShares: [
    {
      name: '${AlertNamePrefix}-StorPossThrottlingHighIOPs'
      displayName: '${AlertNamePrefix}-Storage-Possible Throttling Due to High IOPs'
      description: '${AlertDescriptionHeader}\nThis indicates you may be maxing out the allowed IOPs.\nhttps://docs.microsoft.com/en-us/azure/storage/files/storage-troubleshooting-files-performance#how-to-create-an-alert-if-a-file-share-is-throttled'
      severity: 2
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 1
            name: 'Metric1'
            metricName: 'Transactions'
            dimensions: [
              {
                name: 'ResponseType'
                operator: 'Include'
                values: [
                  'SuccessWithThrottling'
                  'SuccessWithShareIopsThrottling'
                  'ClientShareIopsThrottlingError'
                ]
              }
              {
                name: 'FileShare'
                operator: 'Include'
                values: [
                  'SuccessWithShareEgressThrottling'
                  'SuccessWithShareIngressThrottling'
                  'SuccessWithShareIopsThrottling'
                  'ClientShareEgressThrottlingError'
                  'ClientShareIngressThrottlingError'
                  'ClientShareIopsThrottlingError'
                ]
              }
            ]
            operator: 'GreaterThanOrEqual'
            timeAggregation: 'Total'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.Storage/storageAccounts/fileServices'
    }
  ]
  anf: [
    {
      name: '${AlertNamePrefix}-StorLowSpcANF-15-PrcntRem'
      displayName: '${AlertNamePrefix}-Storage-Low Space on ANF Share-15 Percent Remaining'
      description: '${AlertDescriptionHeader}Storage for the follow Azure NetApp volume is Moderately low. Verify sufficient storage is available and expand when/where needed.'
      severity: 2
      evaluationFrequency: 'PT1H'
      windowSize: 'PT1H'
      criteria: {
        allOf: [
          {
            threshold: 85
            name: 'Metric1'
            metricNamespace: 'microsoft.netapp/netappaccounts/capacitypools/volumes'
            metricName: 'VolumeConsumedSizePercentage'
            operator: 'GreaterThanOrEqual'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
    }
    {
      name: '${AlertNamePrefix}-StorLowSpcANF-5-PrcntRem'
      displayName: '${AlertNamePrefix}-Storage-Low Space on ANF Share-5 Percent Remaining'
      description: '${AlertDescriptionHeader}Storage for the follow Azure NetApp volume is Critically low. Verify sufficient storage is available and expand when/where needed.'
      severity: 1
      evaluationFrequency: 'PT1H'
      windowSize: 'PT1H'
      criteria: {
        allOf: [
          {
            threshold: 95
            name: 'Metric1'
            metricNamespace: 'microsoft.netapp/netappaccounts/capacitypools/volumes'
            metricName: 'VolumeConsumedSizePercentage'
            operator: 'GreaterThanOrEqual'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes'
    }
  ]
  virtualMachines: [
    {
      name: '${AlertNamePrefix}-HP-VM-HighCPU-85-Prcnt-xHostPoolNamex'
      displayName: '${AlertNamePrefix}-HostPool-VM-High CPU 85 Percent (xHostPoolNamex)'
      description: '${AlertDescriptionHeader}Potential performance issues for users on the same host due to moderately limited CPU (Average over 1 hour.) Investigate session host CPU usage per user and/or CPU requirements and adjust if/as needed for xHostPoolNamex.  Check user active vs. disconnected status.'
      severity: 2
      evaluationFrequency: 'PT30M'
      windowSize: 'PT1H'
      criteria: {
        allOf: [
          {
            threshold: 85
            name: 'Metric1'
            metricNamespace: 'microsoft.compute/virtualmachines'
            metricName: 'Percentage CPU'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'microsoft.compute/virtualmachines'
    }
    {
      name: '${AlertNamePrefix}-HP-VM-HighCPU-95-Prcnt-xHostPoolNamex'
      displayName: '${AlertNamePrefix}-HostPool-VM-High CPU 95 Percent (xHostPoolNamex)'
      description: '${AlertDescriptionHeader}Potential performance issues for users on the same host due to critically limited CPU (Avarage over 5 mins.) Investigate session host CPU usage per user and/or CPU requirements and adjust if/as needed for xHostPoolNamex.  Check user active vs. disconnected status.'
      severity: 1
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 95
            name: 'Metric1'
            metricNamespace: 'microsoft.compute/virtualmachines'
            metricName: 'Percentage CPU'
            operator: 'GreaterThan'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'microsoft.compute/virtualmachines'
    }
    {
      name: '${AlertNamePrefix}-HP-VM-OSDiskBandwidthAvg85-xHostPoolNamex'
      displayName: '${AlertNamePrefix}-HostPool-VM-OS Disk Bandwidth Average Consumed 85 Percent (xHostPoolNamex)'
      description: '${AlertDescriptionHeader}The OS Disk is nearing it\'s allowed IO maximum based on the Disk SKU within xHostPoolNamex. Consider review of what applications are possibly causing excessive disk activity and potentially move to a larger or premium disk SKU.'
      severity: 2
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 85
            name: 'Metric1'
            metricNamespace: 'microsoft.compute/virtualmachines'
            dimensions: [
              {
                name: 'LUN'
                operator: 'Include'
                values: [
                  '*'
                ]
              }
            ]
            metricName: 'OS Disk Bandwidth Consumed Percentage'
            operator: 'GreaterThanOrEqual'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'microsoft.compute/virtualmachines'
    }
    {
      name: '${AlertNamePrefix}-HP-VM-OSDiskBandwidthAvg95-xHostPoolNamex'
      displayName: '${AlertNamePrefix}-HostPool-VM-OS Disk Bandwidth Average Consumed 95 Percent (xHostPoolNamex)'
      description: '${AlertDescriptionHeader}The OS Disk is near it\'s allowed IO maximum based on the Disk SKU within xHostPoolNamex. Consider review of what applications are possibly causing excessive disk activity and potentially move to a larger or premium disk SKU.'
      severity: 1
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      criteria: {
        allOf: [
          {
            threshold: 95
            name: 'Metric1'
            metricNamespace: 'microsoft.compute/virtualmachines'
            dimensions: [
              {
                name: 'LUN'
                operator: 'Include'
                values: [
                  '*'
                ]
              }
            ]
            metricName: 'OS Disk Bandwidth Consumed Percentage'
            operator: 'GreaterThanOrEqual'
            timeAggregation: 'Average'
            criterionType: 'StaticThresholdCriterion'
          }
        ]
        'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      }
      targetResourceType: 'microsoft.compute/virtualmachines'
    }
  ]
}

var LogAlertsSvcHealth = [
  {
    name: '${AlertNamePrefix}-ServiceHealth-ServiceIssue'
    displayName: '${AlertNamePrefix}-ServiceHealth-Service Issue'
    description: AlertDescriptionHeader
    anyof: [
      {
        field: 'properties.incidentType'
        equals: 'Incident'
      }
    ]
  }
  {
    name: '${AlertNamePrefix}-ServiceHealth-PlannedMaintenance'
    displayName: '${AlertNamePrefix}-ServiceHealth-Planned Maintenance'
    description: AlertDescriptionHeader
    anyOf: [
      {
        field: 'properties.incidentType'
        equals: 'Maintenance'
      }
    ]
  }
  {
    name: '${AlertNamePrefix}-ServiceHealth-HealthAdvisory'
    displayName: '${AlertNamePrefix}-ServiceHealth-HealthAdvisory'
    description: AlertDescriptionHeader
    anyOf: [
      {
        field: 'properties.incidentType'
        equals: 'Informational'
      }
      {
        field: 'properties.incidentType'
        equals: 'ActionRequired'
      }
    ]
  }
  {
    name: '${AlertNamePrefix}-ServiceHealth-Security'
    displayName: '${AlertNamePrefix}-ServiceHealth-Security'
    description: AlertDescriptionHeader
    anyOf: [
      {
        field: 'properties.incidentType'
        equals: 'Security'
      }
    ]
  }
]
var varJobScheduleParamsHostPool = {
  CloudEnvironment: CloudEnvironment
  SubscriptionId: join(HostPoolSubIds, ',')
}
// fixes issue with array not being in JSON format
var varStorAcctResIDsString = StorageAccountResourceIds
var varJobScheduleParamsAzFiles = {
  CloudEnvironment: CloudEnvironment
  StorageAccountResourceIDs: string(varStorAcctResIDsString)
}

// AVD host pools may live in different subscriptions and resource groups from the alerts
// deployment. Derive the distinct subscriptions and host pool resource groups from the
// selected host pools: the mapping grid (HostPoolInfo) when VMs are in separate RGs,
// otherwise the HostPools list. Falls back to the deployment subscription if nothing is selected.
var HostPoolIdsSource = AllResourcesSameRG ? HostPools : map(HostPoolInfo, info => info.colHostPoolName)
var HostPoolSubIds = empty(HostPoolIdsSource)
  ? [subscription().subscriptionId]
  : union(map(HostPoolIdsSource, item => split(item, '/')[2]), [])
var HostPoolSubRGs = union(map(HostPoolIdsSource, item => '${split(item, '/')[2]},${split(item, '/')[4]}'), [])
var AVDRGScopeEntry = toLower('${split(AVDResourceGroupId, '/')[2]},${split(AVDResourceGroupId, '/')[4]}')
// Scaling plans can live in a different resource group (or subscription) from the host pools they are
// assigned to. Grant read on those resource groups too, skipping any already covered above (compared
// case-insensitively) so the same role assignment is never created twice under different names
var ScalingPlanSubRGs = union(map(ScalingPlanResourceIds, item => toLower('${split(item, '/')[2]},${split(item, '/')[4]}')), [])
var DesktopReadCoveredSubRGs = union(
  map(HostPoolSubRGs, item => toLower(item)),
  AllResourcesSameRG ? [AVDRGScopeEntry] : map(HostPoolInfo, info => toLower('${split(info.colVMResGroup, '/')[2]},${split(info.colVMResGroup, '/')[4]}'))
)
var varScheduleName = 'AVD_Chk-'
var varTimeZone = varTimeZones[Location]
var varTimeZones = {
  australiacentral: 'AUS Eastern Standard Time'
  australiacentral2: 'AUS Eastern Standard Time'
  australiaeast: 'AUS Eastern Standard Time'
  australiasoutheast: 'AUS Eastern Standard Time'
  brazilsouth: 'E. South America Standard Time'
  brazilsoutheast: 'E. South America Standard Time'
  canadacentral: 'Eastern Standard Time'
  canadaeast: 'Eastern Standard Time'
  centralindia: 'India Standard Time'
  centralus: 'Central Standard Time'
  chinaeast: 'China Standard Time'
  chinaeast2: 'China Standard Time'
  chinanorth: 'China Standard Time'
  chinanorth2: 'China Standard Time'
  eastasia: 'China Standard Time'
  eastus: 'Eastern Standard Time'
  eastus2: 'Eastern Standard Time'
  francecentral: 'Central Europe Standard Time'
  francesouth: 'Central Europe Standard Time'
  germanynorth: 'Central Europe Standard Time'
  germanywestcentral: 'Central Europe Standard Time'
  japaneast: 'Tokyo Standard Time'
  japanwest: 'Tokyo Standard Time'
  jioindiacentral: 'India Standard Time'
  jioindiawest: 'India Standard Time'
  koreacentral: 'Korea Standard Time'
  koreasouth: 'Korea Standard Time'
  northcentralus: 'Central Standard Time'
  northeurope: 'GMT Standard Time'
  norwayeast: 'Central Europe Standard Time'
  norwaywest: 'Central Europe Standard Time'
  southafricanorth: 'South Africa Standard Time'
  southafricawest: 'South Africa Standard Time'
  southcentralus: 'Central Standard Time'
  southindia: 'India Standard Time'
  southeastasia: 'Singapore Standard Time'
  swedencentral: 'Central Europe Standard Time'
  switzerlandnorth: 'Central Europe Standard Time'
  switzerlandwest: 'Central Europe Standard Time'
  uaecentral: 'Arabian Standard Time'
  uaenorth: 'Arabian Standard Time'
  uksouth: 'GMT Standard Time'
  ukwest: 'GMT Standard Time'
  usdodcentral: 'Central Standard Time'
  usdodeast: 'Eastern Standard Time'
  usgovarizona: 'Mountain Standard Time'
  usgoviowa: 'Central Standard Time'
  usgovtexas: 'Central Standard Time'
  usgovvirginia: 'Eastern Standard Time'
  westcentralus: 'Mountain Standard Time'
  westeurope: 'Central Europe Standard Time'
  westindia: 'India Standard Time'
  westus: 'Pacific Standard Time'
  westus2: 'Pacific Standard Time'
  westus3: 'Mountain Standard Time'
}

// =========== //
// Deployments //
// =========== //
module deploymentNames_pidCuaDeployment 'modules/pid_cuaid.bicep' =
  if (!optoutTelemetry) {
    name: PidcuaAvdPatternDeploymentName
    params: {}
  }

// AVD Shared Services Resource Group
module resourceGroupAVDMetricsCreate 'carml/1.3.0/Microsoft.Resources/resourceGroups/deploy.bicep' =
  if (ResourceGroupCreate) {
    name: ResourceGroupName
    params: {
      name: ResourceGroupName
      location: Location
      enableDefaultTelemetry: false
      tags: contains(Tags, 'Microsoft.Resources/resourceGroups') ? Tags['Microsoft.Resources/resourceGroups'] : {}
    }
  }

resource resourceGroupAVDMetricsExisting 'Microsoft.Resources/resourceGroups@2025-04-01' existing = {
  name: ResourceGroupName
}

/* module identityUserManaged 'carml/1.3.0/Microsoft.ManagedIdentity/userAssignedIdentities/deploy.bicep' = {
  name: 'c_UserMgId_${UsrManagedIdentityName}'
  scope: resourceGroup(ResourceGroupCreate ? resourceGroupAVDMetricsCreate.name : resourceGroupAVDMetricsExisting.name)
  params: {
    location: Location
    name: UsrManagedIdentityName
    enableDefaultTelemetry: false
    tags: contains(Tags, 'Microsoft.ManagedIdentity/userAssignedIdentities') ? Tags['Microsoft.ManagedIdentity/userAssignedIdentities'] : {}
  }
  dependsOn: ResourceGroupCreate ? [ resourceGroupAVDMetricsCreate ] : [ resourceGroupAVDMetricsExisting ]
} */

// Deploy new automation account
module automationAccount 'carml/1.3.0/Microsoft.Automation/automationAccounts/deploy.bicep' = {
  name: 'c_AutomtnAcct-${AutomationAccountName}'
  scope: resourceGroup(ResourceGroupName)
  params: {
    diagnosticLogCategoriesToEnable: [
      'JobLogs'
      'JobStreams'
    ]
    enableDefaultTelemetry: false
    diagnosticWorkspaceId: LogAnalyticsWorkspaceResourceId
    name: AutomationAccountName
    jobSchedules: !empty(StorageAccountResourceIds)
      ? [
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-0'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-1'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-2'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-3'
          }
          {
            parameters: varJobScheduleParamsAzFiles
            runbookName: RunbookNameGetStorage
            scheduleName: '${varScheduleName}AzFilesStor-0'
          }
          {
            parameters: varJobScheduleParamsAzFiles
            runbookName: RunbookNameGetStorage
            scheduleName: '${varScheduleName}AzFilesStor-1'
          }
          {
            parameters: varJobScheduleParamsAzFiles
            runbookName: RunbookNameGetStorage
            scheduleName: '${varScheduleName}AzFilesStor-2'
          }
          {
            parameters: varJobScheduleParamsAzFiles
            runbookName: RunbookNameGetStorage
            scheduleName: '${varScheduleName}AzFilesStor-3'
          }
        ]
      : [
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-0'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-1'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-2'
          }
          {
            parameters: varJobScheduleParamsHostPool
            runbookName: RunbookNameGetHostPool
            scheduleName: '${varScheduleName}HostPool-3'
          }
        ]
    location: Location
    runbooks: !empty(StorageAccountResourceIds)
      ? [
          {
            name: RunbookNameGetHostPool
            description: 'AVD Metrics Runbook for collecting related Host Pool statistics to store in Log Analytics for specified Alert Queries'
            type: 'PowerShell'
            uri: '${ArtifactsLocation}${RunbookScriptGetHostPool}'
            version: '1.0.0.0'
          }
          {
            name: RunbookNameGetStorage
            description: 'AVD Metrics Runbook for collecting related Azure Files storage statistics to store in Log Analytics for specified Alert Queries'
            type: 'PowerShell'
            uri: '${ArtifactsLocation}${RunbookScriptGetStorage}'
            version: '1.0.0.0'
          }
        ]
      : [
          {
            name: RunbookNameGetHostPool
            description: 'AVD Metrics Runbook for collecting related Host Pool statistics to store in Log Analytics for specified Alert Queries'
            type: 'PowerShell'
            uri: '${ArtifactsLocation}${RunbookScriptGetHostPool}'
            version: '1.0.0.0'
          }
        ]
    schedules: !empty(StorageAccountResourceIds)
      ? [
          {
            name: '${varScheduleName}HostPool-0'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT15M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-1'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT30M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-2'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT45M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-3'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT60M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}AzFilesStor-0'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT15M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}AzFilesStor-1'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT30M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}AzFilesStor-2'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT45M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}AzFilesStor-3'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT60M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
        ]
      : [
          {
            name: '${varScheduleName}HostPool-0'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT15M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-1'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT30M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-2'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT45M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
          {
            name: '${varScheduleName}HostPool-3'
            frequency: 'Hour'
            interval: 1
            startTime: dateTimeAdd(time, 'PT60M')
            TimeZone: varTimeZone
            advancedSchedule: {}
          }
        ]
    skuName: 'Free'
    tags: contains(Tags, 'Microsoft.Automation/automationAccounts')
      ? Tags['Microsoft.Automation/automationAccounts']
      : {}
    systemAssignedIdentity: true
  }
  dependsOn: ResourceGroupCreate ? [resourceGroupAVDMetricsCreate] : [resourceGroupAVDMetricsExisting]
}

// Assign role to Automation Account for Desktop Virtualization Reader to account for all AVD VMs if in different Resource Groups
// (Needed for Automation Account)
module roleAssignment_AutoAcctDesktopRead 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for RG in HostPoolInfo: if (!AllResourcesSameRG) {
    scope: resourceGroup(split(RG.colVMResGroup, '/')[2], split(RG.colVMResGroup, '/')[4])
    name: 'c_DsktpRead_${split(RG.colVMResGroup, '/')[4]}'
    params: {
      enableDefaultTelemetry: false
      principalId: automationAccount.outputs.systemAssignedPrincipalId
      roleDefinitionIdOrName: 'Desktop Virtualization Reader'
      principalType: 'ServicePrincipal'
      resourceGroupName: split(RG.colVMResGroup, '/')[4]
    }
    dependsOn: [
      automationAccount
    ]
  }
]

// Assign role to Automation Account for Desktop Virtualization Reader to account for all AVD Resources and VMs if in the same Resource Group
// (Needed for Automation Account)
module roleAssignment_AutoAcctDesktopReadSameRG 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = if (AllResourcesSameRG) {
    scope: resourceGroup(split(AVDResourceGroupId, '/')[2], split(AVDResourceGroupId, '/')[4])
    name: 'c_DsktpRead_${split(AVDResourceGroupId, '/')[4]}'
    params: {
      enableDefaultTelemetry: false
      principalId: automationAccount.outputs.systemAssignedPrincipalId
      roleDefinitionIdOrName: 'Desktop Virtualization Reader'
      principalType: 'ServicePrincipal'
      resourceGroupName: split(AVDResourceGroupId, '/')[4]
    }
    dependsOn: [
      automationAccount
    ]
  }

// Assign Desktop Virtualization Reader on each HOST POOL's resource group (deduplicated across
// pools, each in its own subscription), so the Get-HostPoolInfo runbook can read pools living in
// other resource groups or subscriptions. Runs after the assignments above so any overlapping
// scope is a safe re-apply of an identical assignment rather than a race.
module roleAssignment_AutoAcctDesktopReadHostPoolRGs 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for entry in HostPoolSubRGs: if (toLower(entry) != AVDRGScopeEntry) {
    scope: resourceGroup(split(entry, ',')[0], split(entry, ',')[1])
    name: 'c_DsktpReadHP_${uniqueString(entry)}'
    params: {
      enableDefaultTelemetry: false
      principalId: automationAccount.outputs.systemAssignedPrincipalId
      roleDefinitionIdOrName: 'Desktop Virtualization Reader'
      principalType: 'ServicePrincipal'
      resourceGroupName: split(entry, ',')[1]
    }
    dependsOn: [
      roleAssignment_AutoAcctDesktopRead
      roleAssignment_AutoAcctDesktopReadSameRG
    ]
  }
]

// Assign Desktop Virtualization Reader on each SCALING PLAN's resource group not already covered above,
// so the Get-HostPoolInfo runbook can read scaling plans that live outside the host pool resource group.
// Without this a plan in another resource group looks like "no scaling plan" and its alerts stay silent.
module roleAssignment_AutoAcctDesktopReadScalingPlanRGs 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for entry in ScalingPlanSubRGs: if (!contains(DesktopReadCoveredSubRGs, entry)) {
    scope: resourceGroup(split(entry, ',')[0], split(entry, ',')[1])
    name: 'c_DsktpReadSP_${uniqueString(entry)}'
    params: {
      enableDefaultTelemetry: false
      principalId: automationAccount.outputs.systemAssignedPrincipalId
      roleDefinitionIdOrName: 'Desktop Virtualization Reader'
      principalType: 'ServicePrincipal'
      resourceGroupName: split(entry, ',')[1]
    }
    dependsOn: [
      roleAssignment_AutoAcctDesktopReadHostPoolRGs
    ]
  }
]

// Assign role to Automation Account for Log Analytics Contributor to allow Automation Account to write to Log Analytics
// (Needed for Automation Account)
module roleAssignment_LogAnalytics 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = {
  scope: resourceGroup(split(LogAnalyticsWorkspaceResourceId, '/')[2], split(LogAnalyticsWorkspaceResourceId, '/')[4])
  name: 'c_LogContrib_${split(LogAnalyticsWorkspaceResourceId, '/')[4]}'
  params: {
    enableDefaultTelemetry: false
    principalId: automationAccount.outputs.systemAssignedPrincipalId
    roleDefinitionIdOrName: '/providers/Microsoft.Authorization/roleDefinitions/${RoleAssignments.LogAnalyticsContributor.GUID}'
    principalType: 'ServicePrincipal'
    resourceGroupName: split(LogAnalyticsWorkspaceResourceId, '/')[4]
  }
  dependsOn: [
    automationAccount
  ]
}

// Assign Reader to the Automation Account on the Storage Account resource group(s) so it can gather share statistics
// (share usage is read via the ARM management plane, so Reader is sufficient - no write-capable role needed)
module roleAssignment_Storage 'carml/1.3.0/Microsoft.Authorization/roleAssignments/resourceGroup/deploy.bicep' = [
  for StorAcctInfo in StorAcctsSubRGs: {
    scope: resourceGroup(split(StorAcctInfo, ',')[0],split(StorAcctInfo, ',')[1])
    name: 'c_StorReader_${split(StorAcctInfo, ',')[1]}'
    params: {
      enableDefaultTelemetry: false
      principalId: automationAccount.outputs.systemAssignedPrincipalId
      roleDefinitionIdOrName: '/providers/Microsoft.Authorization/roleDefinitions/${RoleAssignments.StorageReader.GUID}'
      principalType: 'ServicePrincipal'
      resourceGroupName: split(StorAcctInfo, ',')[1]
    }
    dependsOn: [
      automationAccount
    ]
  }
]

module metricsResources 'modules/metricsResources.bicep' = {
  name: 'lnk_MonitoringResourcesDeployment'
  scope: resourceGroup(ResourceGroupCreate ? resourceGroupAVDMetricsCreate.name : resourceGroupAVDMetricsExisting.name)
  params: {
    AllResourcesSameRG: AllResourcesSameRG
    AVDResourceGroupId: AVDResourceGroupId
    AutoResolveAlert: AutoResolveAlert
    DistributionGroup: DistributionGroup
    Environment: Environment
    HostPoolInfo: HostPoolInfo
    HostPools: HostPools
    Location: Location
    LogAnalyticsWorkspaceResourceId: LogAnalyticsWorkspaceResourceId
    LogAlertsHostPool: LogAlertsHostPool
    LogAlertsStorage: LogAlertsStorage
    LogAlertsSvcHealth: LogAlertsSvcHealth
    MetricAlerts: MetricAlerts
    StorageAccountResourceIds: StorageAccountResourceIds
    ActionGroupName: ActionGroupName
    ExistingActionGroupResourceId: ExistingActionGroupResourceId
    ANFVolumeResourceIds: ANFVolumeResourceIds
    Tags: Tags
  }
  dependsOn: [
    roleAssignment_AutoAcctDesktopRead
    roleAssignment_LogAnalytics
    roleAssignment_Storage
  ]
}
