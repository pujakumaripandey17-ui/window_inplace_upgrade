param(
    [ValidateSet('Preflight','Policy','Scan','Install','Status','Validate')][string]$Action,
    [string[]]$AssignmentIds = @(),
    [int]$Timeout = 900,
    [string[]]$RequiredServices = @(),
    [string[]]$MonitorIds = @(),
    [string]$ExpectedKB = "",
    [string]$BeforeBuild = "",
    [string[]]$BeforeHotfixes = @()
)

$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
$ns = 'root\ccm\ClientSDK'

function Trigger([string]$suffix) {

    $id = '{00000000-0000-0000-0000-000000000' + $suffix + '}'

    for ($attempt = 1; $attempt -le 5; $attempt++) {

        try {

            Write-Verbose "Triggering SCCM schedule $id (attempt $attempt)"

            $r = Invoke-CimMethod `
                -Namespace root\ccm `
                -ClassName SMS_Client `
                -MethodName TriggerSchedule `
                -Arguments @{ sScheduleID = $id } `
                -ErrorAction Stop

            if ($null -eq $r) {
                throw "TriggerSchedule returned a null response for $id"
            }

            if ($null -eq $r.ReturnValue -or $r.ReturnValue -eq '') {
                Write-Warning "TriggerSchedule returned blank ReturnValue for $id. Submission is unconfirmed; deployment policy or fresh scan evidence is required."
                return
            }

            try {
                $returnCode = [int]$r.ReturnValue
            }
            catch {
                throw "TriggerSchedule $id returned a non-numeric value [$($r.ReturnValue)]"
            }

            if ($returnCode -eq 0) {
                return
            }

            throw "TriggerSchedule $id returned code $returnCode"
        }
        catch {

            Write-Warning (
                "TriggerSchedule failed for {0} on attempt {1}/5. Error: {2}" -f
                $id,
                $attempt,
                $_.Exception.Message
            )

            if ($attempt -eq 5) {
                throw
            }

            Start-Sleep -Seconds 15
        }
    }
}

function Updates {
    @(Get-CimInstance -Namespace $ns -ClassName CCM_SoftwareUpdate)
}

function RebootPending {

    $r = Invoke-CimMethod `
        -Namespace $ns `
        -ClassName CCM_ClientUtilities `
        -MethodName DetermineIfRebootPending

    if ($null -eq $r -or $null -eq $r.RebootPending -or $null -eq $r.IsHardRebootPending) {
        throw "Reboot status could not be determined."
    }
    if ($null -ne $r.ReturnValue -and [string]$r.ReturnValue -ne "" -and [int]$r.ReturnValue -ne 0) {
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
    $names = @('None','Available','Submitted','Detecting','PreDownload','Downloading','WaitInstall','Installing','PendingSoftReboot','PendingHardReboot','WaitReboot','Verifying','InstallComplete','Error','WaitServiceWindow','WaitUserLogon','WaitUserLogoff','WaitJobUserLogon','WaitUserReconnect','PendingUserLogoff','PendingUpdate','WaitingRetry','WaitPresModeOff','WaitForOrchestration')
    $u = @(Updates)
    foreach ($item in $u) {
        if ($null -eq $item.EvaluationState -or [int]$item.EvaluationState -notin (0..23) -or $null -eq $item.ComplianceState -or $item.ComplianceState -notin @(0,1) -or $null -eq $item.ErrorCode -or $item.ErrorCode -ne 0 -or $item.EvaluationState -eq 13) {
            throw ('Update error/unknown state: ' + ($item | Select-Object Name,UpdateID,ComplianceState,EvaluationState,ErrorCode | ConvertTo-Json -Compress))
        }
        if ($item.ComplianceState -eq 0 -and $item.EvaluationState -in @(15,16,17,18,19)) {
            throw "Update '$($item.Name)' requires user/session action: $($names[[int]$item.EvaluationState]). Review UpdatesDeployment.log; unattended automation will not log off users."
        }
    }

    $remaining = @($u | Where-Object { $_.ComplianceState -eq 0 -and $_.EvaluationState -ne 0 })
    $unoffered = @($u | Where-Object { $_.ComplianceState -eq 0 -and $_.EvaluationState -eq 0 })
    $active = @($u | Where-Object { $_.EvaluationState -in @(2,3,4,5,6,7,11) })
    $submittable = @($remaining | Where-Object { $_.EvaluationState -eq 1 })
    $reboot = (RebootPending) -or @($u | Where-Object { $_.EvaluationState -in @(8,9,10) }).Count -gt 0
    $expectedInstalled = $false
    if ($ExpectedKB) { $expectedInstalled = @((Get-HotFix -ErrorAction Stop) | Where-Object HotFixID -IEQ $ExpectedKB).Count -gt 0 }
    $waiting = @($u | Where-Object { $_.EvaluationState -in @(12,14,20,21,22,23) -and $_.ComplianceState -eq 0 })
    $complete = $remaining.Count -eq 0 -and $active.Count -eq 0 -and -not $reboot -and $expectedInstalled
    $batchDone = $MonitorIds.Count -gt 0 -and @($remaining | Where-Object { $_.UpdateID -in $MonitorIds }).Count -eq 0 -and $active.Count -eq 0
    # Exit monitoring immediately if nothing is actively installing and either an Available update is unsubmitted OR ExpectedKB is still not installed/active
    $idleUnsubmitted = ($active.Count -eq 0 -and -not $reboot -and $waiting.Count -eq 0 -and ($submittable.Count -gt 0 -or ($ExpectedKB -and -not $expectedInstalled)))

    return @{
        remaining          = $remaining.Count
        unoffered          = $unoffered.Count
        active             = $active.Count
        submittable        = $submittable.Count
        idle_unsubmitted   = [bool]$idleUnsubmitted
        reboot             = [bool]$reboot
        terminal           = [bool]($complete -or ($reboot -and $active.Count -eq 0) -or ($batchDone -and -not $reboot))
        complete           = [bool]$complete
        expected_kb        = $ExpectedKB
        expected_installed = [bool]$expectedInstalled
        waiting_for_offer  = [bool](-not $expectedInstalled -and $remaining.Count -eq 0)
        updates            = @($u | Select-Object Name,ArticleID,UpdateID,ComplianceState,EvaluationState,@{n='StateName';e={$names[[int]$_.EvaluationState]}},PercentComplete,ErrorCode)
        waiting_states     = @($waiting | ForEach-Object { $names[[int]$_.EvaluationState] })
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

    if (-not $ExpectedKB -or -not $s.complete) {
        throw 'Final compliance/reboot validation failed.'
    }

    foreach ($service in $RequiredServices) {
        if ((Get-Service -Name $service).Status -ne 'Running') {
            throw "Required service $service is not running."
        }
    }

    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $fullBuild = "$($version.CurrentBuildNumber).$($version.UBR)"
    if ($BeforeBuild) {
        if ([version]$fullBuild -lt [version]$BeforeBuild) { throw "OS build regressed: $BeforeBuild -> $fullBuild" }
        if ($ExpectedKB -notin $BeforeHotfixes -and [version]$fullBuild -le [version]$BeforeBuild) {
            throw "Expected OS CU was absent before this run, but build did not advance: $BeforeBuild -> $fullBuild. Review servicing evidence."
        }
    }

    $Ansible.Result = @{
        expected_kb        = $ExpectedKB
        expected_installed = $true
        before_build       = $BeforeBuild
        full_build         = $fullBuild
        os                 = $os.Caption
        build              = $os.BuildNumber
        remaining          = 0
        reboot             = $false
        services           = @($RequiredServices)
        updates            = $s.updates
    }

    return
}

if ($Action -eq 'Policy') {
    if (-not $AssignmentIds.Count) { throw 'Expected deployment assignment IDs are required.' }

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

    if (-not (Test-Path $log)) {
        throw 'WUAHandler.log missing; initialize/troubleshoot software update agent first.'
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

    $expectedNum = $ExpectedKB -replace '^(?i)KB', ''

    # Wait up to 300s for Deployment Evaluation (108) to surface ExpectedKB (if not already installed)
    # and move KB updates from EvaluationState 0 (None) to 1 (Available)
    $evalDeadline = (Get-Date).AddSeconds(300)
    do {
        $expectedAlreadyInstalled = $false
        if ($ExpectedKB) {
            $expectedAlreadyInstalled = @((Get-HotFix -ErrorAction Stop) | Where-Object HotFixID -IEQ $ExpectedKB).Count -gt 0
        }

        $u = @(Updates | Where-Object ComplianceState -EQ 0)
        $unreadyKBs = @($u | Where-Object { $_.EvaluationState -eq 0 -and [string]$_.ArticleID -ne '' })
        $expectedInWmi = if ($expectedNum) { @($u | Where-Object { [string]$_.ArticleID -eq $expectedNum }).Count -gt 0 } else { $true }

        # Stop waiting once ExpectedKB is either already installed OR present in WMI with EvaluationState != 0, and no KB updates are stuck at 0
        if (($expectedAlreadyInstalled -or $expectedInWmi) -and $unreadyKBs.Count -eq 0) {
            break
        }

        Trigger '108'
        Start-Sleep -Seconds 20
    } while ((Get-Date) -lt $evalDeadline)

    $s = State
    $u = @(Updates | Where-Object ComplianceState -EQ 0)

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

    $active = @(
        $u | Where-Object {
            $_.EvaluationState -in @(2,3,4,5,6,7,11)
        }
    )

    if ($active.Count -gt 0) {
        $Ansible.Result = @{
            missing     = $u.Count
            submitted   = @()
            monitor_ids = @($u | ForEach-Object UpdateID)
            reason      = "Install already in progress"
        }
        return
    }

    $pendingInstall = @(
        $u | Where-Object {
            $_.ComplianceState -eq 0 -and (
                $_.EvaluationState -eq 1 -or
                ($_.EvaluationState -eq 0 -and $expectedNum -and [string]$_.ArticleID -eq $expectedNum)
            )
        }
    )

    if ($pendingInstall.Count -eq 0) {
        $Ansible.Result = @{
            missing     = 0
            submitted   = @()
            monitor_ids = @()
        }
        return
    }

    $exclusive = @(
        $pendingInstall | Where-Object ExclusiveUpdate
    )

    [Microsoft.Management.Infrastructure.CimInstance[]]$batch =
        if ($exclusive.Count -gt 0) {
            @($exclusive[0])
        }
        else {
            $pendingInstall
        }

    Write-Warning (
        "Submitting {0} update(s) for installation." -f
        $batch.Count
    )

    $result = Invoke-CimMethod `
        -Namespace $ns `
        -ClassName CCM_SoftwareUpdatesManager `
        -MethodName InstallUpdates `
        -Arguments @{ CCMUpdates = $batch } `
        -ErrorAction Stop

    if ($null -eq $result) { throw 'InstallUpdates returned no response.' }
    if ($null -eq $result.ReturnValue -or [string]$result.ReturnValue -eq '') {
        Write-Warning 'InstallUpdates submission is unconfirmed; installation and build validation remain required.'
    }
    elseif ([uint32]$result.ReturnValue -ne 0) {
        throw "InstallUpdates returned $($result.ReturnValue)"
    }

    $Ansible.Changed = $true

    $Ansible.Result = @{
        missing     = $pendingInstall.Count
        submitted   = @(
            $batch | Select-Object Name, UpdateID
        )
        monitor_ids = @(
            $batch | ForEach-Object UpdateID
        )
    }
}
