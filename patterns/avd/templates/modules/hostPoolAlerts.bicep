param AutoMitigate bool
param ActionGroupId string
param Environment string
param HostPoolName string
param LogAlertsHostPool array
param LogAnalyticsWorkspaceResourceId string
param Location string
param Tags object

// Help ensure entire deployment name is under 64 characters
var HostPoolResourceName = length(HostPoolName) < 20 ? HostPoolName : skip(HostPoolName, length(HostPoolName)-20)

// When alerts are not set to auto-resolve, Azure notifies at every evaluation while the condition holds.
// Mute notifications for an hour after firing on rules that are evaluated more often than hourly
var MuteActionsDuration = 'PT1H'
var SubHourlyFrequencies = ['PT1M', 'PT5M', 'PT10M', 'PT15M', 'PT30M', 'PT45M']

module logAlertHostPoolQueries '../carml/1.3.0/Microsoft.Insights/scheduledQueryRules/deploy.bicep' = [for i in range(0, length(LogAlertsHostPool)): {
  name: 'c_${replace(LogAlertsHostPool[i].name, 'xHostPoolNamex', HostPoolResourceName)}-${Environment}'
  params: {
    enableDefaultTelemetry: false
    name: '${replace(LogAlertsHostPool[i].name, 'xHostPoolNamex', HostPoolResourceName)}-${Environment}'
    autoMitigate: AutoMitigate
    criterias: {
      allOf: [
        // metricMeasureColumn is passed only for alerts that measure a value (e.g. AvailableMB) rather than count rows
        union(
          {
            query: replace(LogAlertsHostPool[i].criteria.allOf[0].query, 'xHostPoolNamex', HostPoolName)
            timeAggregation: LogAlertsHostPool[i].criteria.allOf[0].timeAggregation
            dimensions: LogAlertsHostPool[i].criteria.allOf[0].dimensions
            operator: LogAlertsHostPool[i].criteria.allOf[0].operator
            threshold: LogAlertsHostPool[i].criteria.allOf[0].threshold
            failingPeriods: LogAlertsHostPool[i].criteria.allOf[0].failingPeriods
          },
          contains(LogAlertsHostPool[i].criteria.allOf[0], 'metricMeasureColumn')
            ? { metricMeasureColumn: LogAlertsHostPool[i].criteria.allOf[0].metricMeasureColumn }
            : {}
        )
      ]
    }
    suppressForMinutes: !AutoMitigate && contains(SubHourlyFrequencies, LogAlertsHostPool[i].evaluationFrequency) ? MuteActionsDuration : ''
    scopes: [LogAnalyticsWorkspaceResourceId]
    location: Location
    actions: [ActionGroupId]
    alertDisplayName: '${replace(LogAlertsHostPool[i].displayName, 'xHostPoolNamex', HostPoolResourceName)}-${Environment}'
    alertDescription: '${replace(LogAlertsHostPool[i].description, 'xHostPoolNamex', HostPoolName)}-${Environment}'
    enabled: false
    evaluationFrequency: LogAlertsHostPool[i].evaluationFrequency
    severity: LogAlertsHostPool[i].severity
    tags: contains(Tags, 'Microsoft.Insights/scheduledQueryRules') ? Tags['Microsoft.Insights/scheduledQueryRules'] : {}
    windowSize: LogAlertsHostPool[i].windowSize
  }
}]

output HostPoolResourceName string = HostPoolResourceName
output HostPoolName string = HostPoolName
output HostPoolNameLength int = length(HostPoolName)
