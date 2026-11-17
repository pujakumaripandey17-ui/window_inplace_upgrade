param(
    [string[]]$AssignmentIds,
    [int]$Timeout = 1800,
    [int]$RetrievalInterval = 120,
    [int]$PollInterval = 30
)
$ErrorActionPreference = 'Stop'
$Ansible.Changed = $false
if (-not $AssignmentIds.Count) { throw 'Expected deployment assignment IDs are required.' }
if ($Timeout -lt 60 -or $RetrievalInterval -lt 30 -or $PollInterval -lt 5) { throw 'Invalid policy wait intervals.' }
function Normalize-ID([string]$id) { $id.Trim().Trim('{}').ToUpperInvariant() }
$wanted = @($AssignmentIds | ForEach-Object {
    $id = Normalize-ID $_
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($id, [ref]$parsed)) { throw "Invalid expected assignment GUID: $_" }
    $parsed.ToString().ToUpperInvariant()
} | Sort-Object -Unique)
$clock = [Diagnostics.Stopwatch]::StartNew()
$nextRetrieval = 0
$missing = @($wanted)
$actualIds = @()
$requestedIds = @()
$lastRetrievalError = ''
$lastEvaluationError = ''
$lastQueryError = ''
$retrievalAttempts = 0
$blankStatusWarned = @{}
function Request-Schedule([string]$suffix) {
    $id = '{00000000-0000-0000-0000-000000000' + $suffix + '}'
    $r = Invoke-CimMethod -Namespace root\ccm -ClassName SMS_Client -MethodName TriggerSchedule `
        -Arguments @{sScheduleID=$id} -OperationTimeoutSec 30 -ErrorAction Stop
    if ($null -eq $r) { throw "Schedule $id returned no response." }
    if ($null -eq $r.ReturnValue -or [string]::IsNullOrWhiteSpace([string]$r.ReturnValue)) {
        if (-not $blankStatusWarned.ContainsKey($id)) {
            Write-Warning "Schedule $id returned no status. Only actual deployment assignment evidence can pass this gate."
            $blankStatusWarned[$id] = $true
        }
    }
    elseif ([uint32]$r.ReturnValue -ne 0) { throw "Schedule $id failed: ReturnValue=$($r.ReturnValue)." }
    $Ansible.Changed = $true
}
while ($clock.Elapsed.TotalSeconds -lt $Timeout) {
    if ($clock.Elapsed.TotalSeconds -ge $nextRetrieval) {
        $retrievalAttempts++
        try { Request-Schedule '021'; $lastRetrievalError = '' }
        catch { $lastRetrievalError = $_.Exception.Message }
        $nextRetrieval = $clock.Elapsed.TotalSeconds + $RetrievalInterval
    }
    if ($clock.Elapsed.TotalSeconds -ge $Timeout) { break }
    try { Request-Schedule '022'; $lastEvaluationError = '' }
    catch { $lastEvaluationError = $_.Exception.Message }
    if ($clock.Elapsed.TotalSeconds -ge $Timeout) { break }
    try {
        $actual = @(Get-CimInstance -Namespace 'root\ccm\Policy\Machine\ActualConfig' `
            -ClassName CCM_UpdateCIAssignment -OperationTimeoutSec 30 -ErrorAction Stop)
        $actualIds = @($actual | ForEach-Object { Normalize-ID ([string]$_.AssignmentID) })
        $missing = @($wanted | Where-Object { $_ -notin $actualIds })
        $lastQueryError = ''
        if (-not $missing.Count) {
            $Ansible.Result = @{
                received=$true; assignment_ids=@($AssignmentIds)
                actual_assignment_ids=@($actualIds)
                elapsed_seconds=[int]$clock.Elapsed.TotalSeconds
                retrieval_attempts=$retrievalAttempts
            }
            return
        }
    }
    catch { $lastQueryError = $_.Exception.Message }
    $secondsLeft = $Timeout - $clock.Elapsed.TotalSeconds
    if ($secondsLeft -gt 0) { Start-Sleep -Seconds ([int][Math]::Min($PollInterval, [Math]::Ceiling($secondsLeft))) }
}
# Capture requested policy only for diagnosis; it never substitutes for ActualConfig.
$requestedQueryError = ''
try {
    $requestedIds = @(Get-CimInstance -Namespace 'root\ccm\Policy\Machine\RequestedConfig' `
        -ClassName CCM_UpdateCIAssignment -OperationTimeoutSec 30 -ErrorAction Stop |
        ForEach-Object { Normalize-ID ([string]$_.AssignmentID) })
}
catch { $requestedQueryError = $_.Exception.Message }
$Ansible.Result = @{
    received=$false; missing_assignment_ids=@($missing)
    actual_assignment_ids=@($actualIds); requested_assignment_ids=@($requestedIds)
    elapsed_seconds=[int]$clock.Elapsed.TotalSeconds; retrieval_attempts=$retrievalAttempts
    last_retrieval_error=$lastRetrievalError; last_evaluation_error=$lastEvaluationError
    last_actual_query_error=$lastQueryError; requested_query_error=$requestedQueryError
}
throw ('Expected deployment policy did not arrive in ActualConfig. ' + ($Ansible.Result | ConvertTo-Json -Depth 4 -Compress) + '. Review PolicyAgent.log, PolicyEvaluator.log and CcmMessaging.log. Subsequent cleanup may remove membership; retain this evidence.')
