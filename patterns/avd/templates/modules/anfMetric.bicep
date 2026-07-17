param AutoMitigate bool
param Enabled bool
param Environment string
param MetricAlertsANF array
param ANFVolumeResourceID string
param ActionGroupID string
param Tags object

// Metric alerts require targetResourceRegion to match the MONITORED resource's region,
// which may differ from the deployment region (cross-region/cross-subscription monitoring).
resource anfAccount 'Microsoft.NetApp/netAppAccounts@2022-09-01' existing = {
  name: split(ANFVolumeResourceID, '/')[8]
  scope: resourceGroup(split(ANFVolumeResourceID, '/')[2], split(ANFVolumeResourceID, '/')[4])
}

resource anfPool 'Microsoft.NetApp/netAppAccounts/capacityPools@2022-09-01' existing = {
  parent: anfAccount
  name: split(ANFVolumeResourceID, '/')[10]
}

resource anfVolume 'Microsoft.NetApp/netAppAccounts/capacityPools/volumes@2022-09-01' existing = {
  parent: anfPool
  name: split(ANFVolumeResourceID, '/')[12]
}

// Help ensure entire deployment name is under 64 characters
var ANFVolumeResourceNameOrig = split(ANFVolumeResourceID, '/')[12]
var ANFVolumeResourceName = length(ANFVolumeResourceNameOrig) < 20 ? ANFVolumeResourceNameOrig : skip(ANFVolumeResourceNameOrig, length(ANFVolumeResourceNameOrig)-20)

module metricAlerts_ANFVolumes '../carml/1.3.0/Microsoft.Insights/metricAlerts/deploy.bicep' = [for i in range(0, length(MetricAlertsANF)): {
  name: 'c_${MetricAlertsANF[i].name}-${ANFVolumeResourceName}-${Environment}'
  params: {
    enableDefaultTelemetry: false
    name: '${MetricAlertsANF[i].displayName}-${ANFVolumeResourceName}-${Environment}'
    criterias: MetricAlertsANF[i].criteria.allOf
    location: 'global'
    alertDescription: MetricAlertsANF[i].description
    severity: MetricAlertsANF[i].severity
    enabled: Enabled
    scopes: [ANFVolumeResourceID]
    evaluationFrequency: MetricAlertsANF[i].evaluationFrequency
    windowSize: MetricAlertsANF[i].windowSize
    autoMitigate: AutoMitigate
    tags: contains(Tags, 'Microsoft.Insights/metricAlerts') ? Tags['Microsoft.Insights/metricAlerts'] : {}
    targetResourceType: MetricAlertsANF[i].targetResourceType
    targetResourceRegion: anfVolume.location
    actions: [
      {
        actionGroupId: ActionGroupID
      }
    ]
  }
}]
