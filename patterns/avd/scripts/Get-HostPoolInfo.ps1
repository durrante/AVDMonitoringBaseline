<#
LAST UPDTATE: October 2026
-- October 2026: Appended ScalingPlanName and ScalingPlanState (fields 13 and 14) for the scaling plan
   alerts. Appended at the end so the existing field positions used by other alerts are unchanged
-- July 2026: SubscriptionId now accepts a comma-separated list so one Automation Account can
   collect host pool data across multiple subscriptions (single value remains fully supported)
-- July 2023: Added info for Personal Host Pool Info regarding need for alert where assigned but unhealthy
#>


[CmdletBinding(SupportsShouldProcess)]
param(
	[Parameter(Mandatory)]
	[string]$CloudEnvironment,
    [Parameter(Mandatory)]
    [string]$SubscriptionId
)

Connect-AzAccount -Identity -Environment $CloudEnvironment | Out-Null

# $HostPoolInfoObj= @()
$Output = @()

# SubscriptionId accepts a single subscription ID or a comma-separated list, so one
# Automation Account can collect host pool data across multiple subscriptions
Foreach($AVDSubscription in ($SubscriptionId -split ',' | Where-Object { $_ })) {
$AVDSubscription = $AVDSubscription.Trim()
Set-AzContext -SubscriptionId $AVDSubscription | Out-Null
$AVDHostPools = Get-AzWvdHostPool -SubscriptionId $AVDSubscription

Foreach($AVDHostPool in $AVDHostPools){
    $HPPerUnhlthy = $null
    $HPNumPerUnhlthy = $null
    $HPPerHostUnhlthy = $null
	$HPName = $AVDHostPool.Name
    $HPResGroup = ($AVDHostPool.Id -split '/')[4]
    $HPType = $AVDHostPool.HostPoolType
    $HPMaxSessionLimit = $AVDHostPool.MaxSessionLimit
    $HPSessionHosts = Get-AzWvdSessionHost -HostPoolName $HPName -ResourceGroupName $HPResGroup
    $HPUsrSessions = Get-AzWvdUserSession -HostPoolName $HPName -ResourceGroupName $HPResGroup
    $HPNumSessionHosts = $HPSessionHosts.count
    $HPUsrSession = $HPUsrSessions.count
    $HPUsrDisonnected = ($HPUsrSessions | Where-Object {$_.sessionState -eq "Disconnected" -AND $_.userPrincipalName -ne $null}).count
    $HPUsrActive = ($HPUsrSessions | Where-Object {$_.sessionState -eq "Active" -AND $_.userPrincipalName -ne $null}).count
    If($HPType -eq "Personal"){
        $HPPerUnhlthy = $HPSessionHosts | Where-Object {$_.AssignedUser -ne $null -AND $_.Status -ne "Available"}
        $HPNumPerUnhlthy = $HPPerUnhlthy.count
        $HostList = New-Object PSObject
        foreach($item in $HPPerUnhlthy){
            $HostList | Add-Member -Type NoteProperty -Name SessionHost -Value ($item.name -split '/')[1]
            $HostList | Add-Member -Type NoteProperty -Name AssignedUser -Value $item.AssignedUser
            }
        $HPPerHostUnhlthy = $HostList | ConvertTo-Json
        }
   
    #Adding number of hosts available and allowing sessions, and Host Pool resource ID
    $HP_ResID = $AVDHostPool.Id
    $HPNumHostsAllowingSessions = (Get-AzWvdSessionHost -HostPoolName $HPName -ResourceGroupName $HPResGroup | where {$_.AllowNewSession}).count
    $HPNumHostsAvailable = (Get-AzWvdSessionHost -HostPoolName $HPName -ResourceGroupName $HPResGroup | where {$_.Status -eq "Available"}).count
    $HPNumHostsAvailableAndAllowingSessions = (Get-AzWvdSessionHost -HostPoolName $HPName -ResourceGroupName $HPResGroup | where {$_.Status -eq "Available" -and $_.AllowNewSession}).count

    # Scaling plan assignment for this host pool. The enabled flag lives on the scaling plan's
    # reference to each host pool, not on the plan itself, so one plan can be enabled for one pool
    # and disabled for another. ScalingPlanState is one of:
    #   Enabled / Disabled - a plan is assigned and that is its state for THIS host pool
    #   None               - no scaling plan is assigned to this host pool
    #   Unknown            - the lookup failed; the scaling plan alerts ignore these runs
    $HPScalingPlanName = ''
    $HPScalingPlanState = 'None'
    Try {
        $HPScalingPlans = Get-AzWvdScalingPlan -ResourceGroupName $HPResGroup -HostPoolName $HPName -SubscriptionId $AVDSubscription -ErrorAction Stop
        Foreach($HPScalingPlan in $HPScalingPlans){
            # ARM path casing (and occasionally trailing whitespace) can differ from the host pool ID; -eq is case-insensitive
            $HPScalingPlanRef = $HPScalingPlan.HostPoolReference | Where-Object { "$($_.HostPoolArmPath)".Trim() -eq $HP_ResID } | Select-Object -First 1
            If($HPScalingPlanRef){
                $HPScalingPlanName = $HPScalingPlan.Name
                $HPScalingPlanState = If($HPScalingPlanRef.ScalingPlanEnabled){'Enabled'} Else {'Disabled'}
            }
        }
    }
    Catch {
        $HPScalingPlanName = ''
        $HPScalingPlanState = 'Unknown'
    }
    #Changing how we calculate available sessions to be based on number of hosts that are available and allowing sessions, instead of total number of hosts

# Max allowed Sessions - Based on Total given unavailable may be on scaling plan
    #$HPSessionsAvail = ($HPMaxSessionLimit * $HPNumSessionHosts)-$HPUsrSession
    #if($HPUsrSession -ne 0)	{
	#	$HPLoadPercent = ($HPUsrSession/($HPMaxSessionLimit * $HPNumSessionHosts))*100
	#}
    $HPSessionsAvail = ($HPMaxSessionLimit * $HPNumHostsAvailableAndAllowingSessions)-$HPUsrSession
    if($HPUsrSession -ne 0)	{
		$HPLoadPercent = ($HPUsrSession/($HPMaxSessionLimit * $HPNumHostsAvailableAndAllowingSessions))*100
	}
	Else {$HPLoadPercent = 0}
    $Output += $HPName + "|" + $HPResGroup + "|" + $HPType + "|" + $HPMaxSessionLimit  + "|" + $HPNumSessionHosts + "|" + $HPUsrSession  + "|" + $HPUsrDisonnected  + "|" + $HPUsrActive + "|" + $HPSessionsAvail + "|" + $HPLoadPercent + "|" + $HPNumPerUnhlthy + "|" + $HPPerHostUnhlthy  + "|" + $HP_ResID + "|" + $HPScalingPlanName + "|" + $HPScalingPlanState
}
} # end foreach subscription

# $Output = ConvertTo-Json -InputObject $HostPoolInfoObj
Write-Output $Output