param(
    [ValidateSet('Prepare','Add','Member','Remove')][string]$Action,
    [string]$SiteCode, [string]$Provider, [string]$ModulePath,
    [string]$CollectionName, [bool]$CreateCollection = $false,
    [string]$LimitingCollectionId, [string[]]$DeploymentNames,
    [string]$DeviceName, [string]$CollectionId, [int]$ResourceId
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
Import-Module $ModulePath -ErrorAction Stop
if (-not (Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue)) {
    New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $Provider | Out-Null
}
$drive = Get-PSDrive -Name $SiteCode -PSProvider CMSite
if ($drive.Root -ine $Provider) { throw 'Existing CMSite drive points at a different provider.' }
Push-Location ($SiteCode + ':\')
try {
    if ($Action -eq 'Prepare') {

    $devices = @(
        Get-CMDevice -Name $DeviceName -DisableWildcardHandling |
        Where-Object Name -IEQ $DeviceName
    )

    if ($devices.Count -eq 0) {

        Write-Warning "Get-CMDevice returned no results. Falling back to SMS_R_System."

        $devices = @(
            Get-WmiObject `
                -ComputerName $Provider `
                -Namespace "root\SMS\site_$SiteCode" `
                -Class SMS_R_System |
            Where-Object {
                $_.Name -ieq $DeviceName
            }
        )
    }

    if ($devices.Count -ne 1) {
        throw "Expected one discovered device named $DeviceName; found $($devices.Count). Resolve duplicates/discovery first."
    }

    $cols = @(
        Get-CMDeviceCollection -Name $CollectionName |
        Where-Object Name -EQ $CollectionName
    )

    if ($cols.Count -gt 1) {
        throw 'Collection name is ambiguous.'
    }

    if ($cols.Count -eq 0) {

        if (-not $CreateCollection) {
            throw 'Collection missing and creation disabled.'
        }

        New-CMDeviceCollection `
            -Name $CollectionName `
            -LimitingCollectionId $LimitingCollectionId `
            -Comment 'Dedicated post-upgrade patching' | Out-Null

        $Ansible.Changed = $true

        $cols = @(
            Get-CMDeviceCollection -Name $CollectionName |
            Where-Object Name -EQ $CollectionName
        )
    }

    if ($cols.Count -ne 1) {
        throw 'Could not uniquely resolve collection after creation.'
    }

    $col = $cols[0]

    if ($col.CollectionID -like 'SMS*') {
        throw 'Built-in collections cannot be used.'
    }

    $all = @(Get-CMSoftwareUpdateDeployment -CollectionId $col.CollectionID)

    $ids = @()
    $assigned = @()

    foreach ($name in $DeploymentNames) {

        $found = @($all | Where-Object AssignmentName -EQ $name)

        if ($found.Count -ne 1) {
            throw "Expected exactly one existing deployment '$name' on collection. New collections need deployments configured separately; no server was added."
        }

        $d = $found[0]

        $d.Get() | Out-Null

        if (-not $d.Enabled) {
            throw "Deployment '$name' is disabled."
        }

        if (@($d.AssignedCIs).Count -eq 0) {
            throw "Deployment '$name' has no assigned updates."
        }

        $start = $d.StartTime

        if ($start -is [string] -and $start -match '^\d{14}\.') {
            $start = [Management.ManagementDateTimeConverter]::ToDateTime($start)
        }

        if ($start -and ([datetime]$start -gt (Get-Date))) {
            throw "Deployment '$name' is not yet available."
        }

        if (-not $d.AssignmentUniqueID) {
            throw 'Deployment AssignmentUniqueID is unavailable.'
        }

        $ids += [string]$d.AssignmentUniqueID
        $assigned += @($d.AssignedCIs)
    }

    # Freeze the newest available OS CU assigned to these deployments for this run.
    $updates = @()
    foreach ($ci in @($assigned | Sort-Object -Unique)) {
        $ci = [int]$ci
        $direct = @(Get-WmiObject -ComputerName $Provider -Namespace "root\SMS\site_$SiteCode" -Class SMS_SoftwareUpdate -Filter "CI_ID=$ci" -ErrorAction Stop)
        if ($direct.Count) { $updates += $direct; continue }
        $groups = @(Get-WmiObject -ComputerName $Provider -Namespace "root\SMS\site_$SiteCode" -Class SMS_AuthorizationList -Filter "CI_ID=$ci" -ErrorAction Stop)
        if ($groups.Count -ne 1) { throw "Cannot resolve assigned CI $ci as update or software update group." }
        $groups[0].Get() | Out-Null
        foreach ($updateId in @($groups[0].Updates)) {
            $updates += @(Get-WmiObject -ComputerName $Provider -Namespace "root\SMS\site_$SiteCode" -Class SMS_SoftwareUpdate -Filter "CI_ID=$([int]$updateId)" -ErrorAction Stop)
        }
    }
    $candidates = @($updates | Sort-Object CI_ID -Unique | Where-Object {
        $_.LocalizedDisplayName -match '(?i)Cumulative Update for Microsoft server operating system version 21H2 for x64-based Systems' -and
        $_.LocalizedDisplayName -notmatch '(?i)\.NET|Preview|Dynamic Update' -and
        -not $_.IsExpired -and -not $_.IsSuperseded
    } | ForEach-Object {
        $date = $_.DatePosted
        if ($date -is [string]) { $date = [Management.ManagementDateTimeConverter]::ToDateTime($date) }
        if (-not $date) { throw 'OS CU DatePosted is missing.' }
        if ([datetime]$date -le (Get-Date)) {
            [pscustomobject]@{ kb=('KB' + ([string]$_.ArticleID -replace '^KB','')); title=$_.LocalizedDisplayName; date=[datetime]$date; ci_id=[int]$_.CI_ID }
        }
    } | Sort-Object date -Descending)
    if (-not $candidates.Count) { throw 'No current Server 2022 x64 OS cumulative update found in configured deployments. Refusing an empty-list success.' }
    $latest = $candidates[0]
    if ($latest.kb -notmatch '^KB\d+$') { throw 'Selected OS CU has no valid ArticleID.' }
    if (@($candidates | Where-Object { $_.date -eq $latest.date -and $_.kb -ne $latest.kb }).Count) { throw 'Latest OS CU is ambiguous. Review deployment contents.' }

    $resourceId = if ($devices[0].PSObject.Properties['ResourceID']) {
        [int]$devices[0].ResourceID
    }
    elseif ($devices[0].PSObject.Properties['ResourceId']) {
        [int]$devices[0].ResourceId
    }
    else {
        throw "Unable to determine ResourceID for $DeviceName"
    }

    $Ansible.Result = @{
        collection_id = [string]$col.CollectionID
        resource_id   = $resourceId
        assignment_ids = @($ids)
        expected_update = $latest
    }

    return
}
    if (-not $CollectionId -or $ResourceId -le 0) { throw 'Collection/resource IDs required.' }
    $rules = @(Get-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId | Where-Object ResourceID -EQ $ResourceId)
    if ($Action -eq 'Remove') {
        if ($rules.Count -gt 0) {
            Remove-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId -ResourceId $ResourceId -Force
            $Ansible.Changed = $true
        }
        if (@(Get-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId | Where-Object ResourceID -EQ $ResourceId).Count -gt 0) { throw 'Direct rule removal verification failed.' }
        Invoke-CMCollectionUpdate -CollectionId $CollectionId
        $Ansible.Result = @{ direct_rule_removed=$true }
        return
    }
    $member = @(Get-CMCollectionMember -CollectionId $CollectionId -ResourceId $ResourceId).Count -gt 0
    if ($Action -eq 'Member') { $Ansible.Result = @{member=$member}; return }
    $added = $false
    if (-not $member -and $rules.Count -eq 0) {
        Add-CMDeviceCollectionDirectMembershipRule -CollectionId $CollectionId -ResourceId $ResourceId
        $added = $true
        $Ansible.Changed = $true
    }
    # Set ownership before evaluation; any later failure conservatively retains the rule.
    $Ansible.Result = @{ added=$added; member_before=$member; preexisting_direct_rule=($rules.Count -gt 0) }
    Invoke-CMCollectionUpdate -CollectionId $CollectionId
}
finally { Pop-Location }
