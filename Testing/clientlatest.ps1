param(
    [ValidateSet('Preflight','Policy','Scan','Install','Status','Validate')][string]$Action,
    [string[]]$AssignmentIds = @(),
    [int]$Timeout = 900,
    [string[]]$RequiredServices = @(),
    [string[]]$MonitorIds = @()
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$ns = 'root\ccm\ClientSDK'

function Trigger([string]$suffix) {
    $id = '{00000000-0000-0000-0000-000000000' + $suffix + '}'
    $attempt = 0
    $end = (Get-Date).AddSeconds($(if ($suffix -eq '113') { $Timeout } else { 90 }))
    do {
        $attempt++
        try {
            $r = Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $id } -ErrorAction Stop
            if ($null -eq $r) {
                throw "TriggerSchedule $id returned no response."
            }
            if ($null -eq $r.ReturnValue -or [string]::IsNullOrWhiteSpace([string]$r.ReturnValue)) {
                Write-Warning "TriggerSchedule $id returned no status. Submission is unconfirmed; the caller must verify deployment policy or fresh scan evidence."
                return
            }
            if ([uint32]$r.ReturnValue -ne 0) { throw "TriggerSchedule $id returned $($r.ReturnValue)." }
            return
        }
        catch {
            $detail = $_.Exception.Message
            if ((Get-Date) -ge $end) {
                throw "TriggerSchedule $id failed after $attempt attempts: $detail. Check client registration, Software Updates client settings, update-source/SUP policy, ScanAgent.log and LocationServices.log. Reinstall alone does not guarantee policy readiness."
            }
            Write-Warning "Waiting for schedule $id; attempt=$attempt; error=$detail"
            if ($suffix -eq '113') {
                # Retry initialization; never replace a failed scan with a fabricated pass.
                foreach ($policyId in @('{00000000-0000-0000-0000-000000000021}', '{00000000-0000-0000-0000-000000000022}')) {
                    try {
                        Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule -Arguments @{ sScheduleID = $policyId } -ErrorAction Stop | Out-Null
                    } catch { Write-Verbose $_.Exception.Message }
                }
            }
            Start-Sleep -Seconds 15
        }
    } while ($true)
}
function Updates {
    @(Get-CimInstance -Namespace $ns -ClassName CCM_SoftwareUpdate)
}

function RebootPending {

    $r = Invoke-CimMethod `
        -Namespace $ns `
        -ClassName CCM_ClientUtilities `
        -MethodName DetermineIfRebootPending

    if ($r.ReturnValue -ne 0) {
        throw "DetermineIfRebootPending failed: $($r.ReturnValue)"
    }

    $cbsPending = Test-Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

    $wuPending = Test-Path `
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

    $pendingFiles = (
        Get-ItemProperty `
            'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' `
            -Name PendingFileRenameOperations `
            -ErrorAction SilentlyContinue
    ).PendingFileRenameOperations

    if ($pendingFiles) {
        Write-Warning "PendingFileRenameOperations detected:"
        $pendingFiles | ForEach-Object {
            Write-Warning $_
        }
    }

    return (
        [bool]$r.RebootPending `
        -or [bool]$r.IsHardRebootPending `
        -or [bool]$cbsPending `
        -or [bool]$wuPending
    )
}

function State {

    $u = @(Updates)

    $bad = @(
        $u | Where-Object {
            $_.EvaluationState -eq 13 -or
            $_.ErrorCode -ne 0 -or
            $_.ComplianceState -notin @(0,1)
        }
    )

    if ($bad.Count) {
        throw (
            'Update error/unknown compliance: ' +
            ($bad |
                Select-Object Name,UpdateID,ComplianceState,EvaluationState,ErrorCode |
                ConvertTo-Json -Compress)
        )
    }

    $remaining = @(
        $u | Where-Object ComplianceState -EQ 0
    )

    $active = @(
        $u | Where-Object {
            $_.EvaluationState -in @(2,3,4,5,6,7,11)
        }
    )

    $reboot =
        (RebootPending) -or
        @(
            $u | Where-Object {
                $_.EvaluationState -in @(8,9,10)
            }
        ).Count -gt 0

    $watched = @(
        $remaining | Where-Object {
            $MonitorIds.Count -eq 0 -or
            $_.UpdateID -in $MonitorIds
        }
    )

    return @{
        remaining = $remaining.Count
        reboot    = [bool]$reboot
        terminal  = (
            ($watched.Count -eq 0 -and $active.Count -eq 0) -or
            ($reboot -and $active.Count -eq 0)
        )
        updates   = @(
            $u | Select-Object `
                Name,
                UpdateID,
                ComplianceState,
                EvaluationState,
                PercentComplete,
                ErrorCode
        )
    }
}

if ($Action -in @('Preflight','Validate')) {

    $os = Get-CimInstance Win32_OperatingSystem

    if (
        $os.Caption -notmatch 'Windows Server 2022' -or
        $os.BuildNumber -ne '20348' -or
        $os.ProductType -eq 1
    ) {
        throw 'Target must be Windows Server 2022 build 20348.'
    }

    if ((Get-Service CcmExec).Status -ne 'Running') {
        throw 'CcmExec is not running.'
    }

    Get-CimClass -Namespace $ns -ClassName CCM_SoftwareUpdate | Out-Null
    Get-CimClass -Namespace root\ccm -ClassName SMS_Client | Out-Null

    if ($Action -eq 'Preflight') {

    $Ansible.Result = @{
        computer_name  = $env:COMPUTERNAME
        os             = $os.Caption
        build          = $os.BuildNumber
        reboot_pending = (RebootPending)
    }

    return
}

    $s = State

    if ($s.remaining -ne 0 -or $s.reboot) {
        throw 'Final compliance/reboot validation failed.'
    }

    foreach ($service in $RequiredServices) {
        if ((Get-Service -Name $service).Status -ne 'Running') {
            throw "Required service $service is not running."
        }
    }

    $Ansible.Result = @{
        os        = $os.Caption
        build     = $os.BuildNumber
        remaining = 0
        reboot    = $false
        services  = @($RequiredServices)
        updates   = $s.updates
    }

    return
}

if ($Action -eq 'Policy') {

    if ($AssignmentIds.Count -eq 0 -or @($AssignmentIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'Expected deployment assignment IDs are required for policy verification.'
    }

    Trigger '021'
    $Ansible.Changed = $true

    $end = (Get-Date).AddSeconds($Timeout)

    do {

        Trigger '022'

        $p = @(
            Get-CimInstance `
                -Namespace 'root\ccm\Policy\Machine\ActualConfig' `
                -ClassName CCM_UpdateCIAssignment
        )

        $missing = @(
            $AssignmentIds | Where-Object {

                $wanted = ([string]$_).Trim('{}')

                @(
                    $p | Where-Object {
                        ([string]$_.AssignmentID).Trim('{}') -ieq $wanted
                    }
                ).Count -eq 0
            }
        )

        if ($missing.Count -eq 0) {
            $Ansible.Result = @{
                assignment_ids = @($AssignmentIds)
                received       = $true
            }
            return
        }

        Start-Sleep -Seconds 15

    } while ((Get-Date) -lt $end)

    throw "Expected deployment policy did not arrive: $($missing -join ', ')"
}

if ($Action -eq 'Scan') {

    $log = Join-Path $env:windir 'CCM\Logs\WUAHandler.log'

    $readyDeadline = (Get-Date).AddSeconds($Timeout)
    while (-not (Test-Path $log)) {
        if ((Get-Date) -ge $readyDeadline) {
            throw 'WUAHandler.log did not initialize. Check Software Updates client settings, SUP policy and registration.'
        }
        Trigger '021'
        Trigger '022'
        Start-Sleep -Seconds 15
    }

    $before = Get-Item $log
    $offset = $before.Length
    $created = $before.CreationTimeUtc

    Trigger '113'
    $Ansible.Changed = $true

    $end = (Get-Date).AddSeconds($Timeout)

    do {

        Start-Sleep -Seconds 10

        $now = Get-Item $log

        if ($now.Length -lt $offset -or $now.CreationTimeUtc -ne $created) {
            throw 'WUAHandler.log rotated/truncated during scan. Evidence is uncertain; rerun after review.'
        }

        $stream = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')

        try {
            $null = $stream.Seek($offset, 'Begin')
            $reader = New-Object IO.StreamReader($stream)
            $fresh = $reader.ReadToEnd()
        }
        finally {
            if ($reader) { $reader.Dispose() }
            $stream.Dispose()
        }

        if ($fresh -match '(?i)failed to (run|complete|start|search)|scan failed|onsearchcomplete.*failed') {
            throw "Fresh WUAHandler scan failure: $fresh"
        }

        if ($fresh -match 'Successfully completed scan\.') {
            Trigger '108'

            $Ansible.Result = @{
                scan_success = $true
                evidence     = 'Fresh WUAHandler.log scan completion'
            }

            return
        }

    } while ((Get-Date) -lt $end)

    throw 'No fresh successful scan evidence before timeout. Review ScanAgent.log and WUAHandler.log.'
}

if ($Action -eq 'Status') {
    $Ansible.Result = State
    return
}

if ($Action -eq 'Install') {

    $s = State

    $u = @(
        Updates | Where-Object ComplianceState -EQ 0
    )

    if (@($u | Where-Object IsUpgrade).Count) {
        throw 'Feature upgrade offered by deployment; refuse post-upgrade patch run.'
    }

    $Ansible.Result = @{
        missing     = $u.Count
        submitted   = @()
        monitor_ids = @($u | ForEach-Object UpdateID)
    }

    if ($s.reboot -or $u.Count -eq 0) {
        return
    }

    if (@($u | Where-Object {
        $_.EvaluationState -in @(2,3,4,5,6,7,11)
    }).Count) {
        return
    }

    $exclusive = @(
        $u | Where-Object ExclusiveUpdate
    )

    [Microsoft.Management.Infrastructure.CimInstance[]]$batch =
        if ($exclusive.Count) {
            @($exclusive[0])
        }
        else {
            $u
        }

    $result = Invoke-CimMethod `
        -Namespace $ns `
        -ClassName CCM_SoftwareUpdatesManager `
        -MethodName InstallUpdates `
        -Arguments @{ CCMUpdates = $batch }

    if ($result.ReturnValue -ne 0) {
        throw "InstallUpdates returned $($result.ReturnValue)"
    }

    $Ansible.Changed = $true

    $Ansible.Result = @{
        missing     = $u.Count
        submitted   = @($batch | Select-Object Name,UpdateID)
        monitor_ids = @($batch | ForEach-Object UpdateID)
    }
}
