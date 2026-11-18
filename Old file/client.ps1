
---
# ==========================================================
# WINDOWS SERVER 2016 -> 2022 MONITORING
# ==========================================================
# Called once from main.yml.
# Recursively checks only while upgrade is pending.
#
# Expected facts from main.yml:
# upgrade_complete
# upgrade_failed
# upgrade_reason
# monitor_attempt
# monitor_max_attempts
# monitor_deadline_epoch
# upgrade_check_markers
# upgrade_staging_directory
# ==========================================================

- name: Increase monitoring attempt
  ansible.builtin.set_fact:
    monitor_attempt: "{{ (monitor_attempt | int) + 1 }}"

- name: Reset connection before monitoring
  ansible.builtin.meta: reset_connection

- name: Recover WinRM connection
  ansible.builtin.wait_for_connection:
    timeout: 120
    connect_timeout: 15
    sleep: 15
  register: connection_state
  ignore_errors: true
  ignore_unreachable: true

- name: Check operating system and Setup state
  ansible.windows.win_powershell:
    error_action: stop
    parameters:
      StagingDirectory: "{{ upgrade_staging_directory }}"
      CheckMarkers: "{{ upgrade_check_markers | bool }}"
    script: |
      param(
        [string]$StagingDirectory,
        [bool]$CheckMarkers
      )

      $ErrorActionPreference = 'Stop'
      $Ansible.Changed = $false

      $os = Get-CimInstance Win32_OperatingSystem

      $processes = @(
        Get-Process -Name setup,setuphost,setupprep `
          -ErrorAction SilentlyContinue
      )

      $is2022 = (
        [string]$os.BuildNumber -eq '20348' -and
        [int]$os.ProductType -ne 1 -and
        [string]$os.Caption -match 'Server 2022'
      )

      $state = @{
        is2022 = [bool]$is2022
        build = [string]$os.BuildNumber
        caption = [string]$os.Caption
        setup_running = [bool]($processes.Count -gt 0)
        terminal_failure = $false
        reason = 'Waiting for Windows Server 2022'
      }

      if ($CheckMarkers) {

        $statusDir = Join-Path $StagingDirectory 'Status'
        $failurePath = Join-Path $statusDir 'launch-failed.json'
        $returnedPath = Join-Path $statusDir 'setup-returned.json'

        if (Test-Path -LiteralPath $failurePath) {
          try {
            $failure = Get-Content `
              -LiteralPath $failurePath -Raw |
              ConvertFrom-Json

            $state.terminal_failure = $true
            $state.reason = "Launcher failed: $($failure.message)"
          }
          catch {
            $state.terminal_failure = $true
            $state.reason = "Invalid launcher failure marker: $_"
          }
        }

        if (
          -not $state.terminal_failure -and
          (Test-Path -LiteralPath $returnedPath)
        ) {
          try {
            $returned = Get-Content `
              -LiteralPath $returnedPath -Raw |
              ConvertFrom-Json

            $exitHex = (
              [string]$returned.exit_code_hex
            ).Trim().ToUpperInvariant()

            if (-not $exitHex) {
              $state.terminal_failure = $true
              $state.reason = 'Setup result has no exit code'
            }
            elseif (
              $exitHex -notin @(
                '0X00000000',
                '0X00000BC2'
              )
            ) {
              $state.terminal_failure = $true
              $state.reason = "Setup returned failure: $exitHex"
            }
          }
          catch {
            $state.terminal_failure = $true
            $state.reason = "Invalid Setup result marker: $_"
          }
        }
      }

      if ($state.is2022 -and -not $state.terminal_failure) {
        $state.reason = 'Windows Server 2022 detected'
      }

      $Ansible.Result = $state
  register: current_state
  when:
    - not (connection_state.failed | default(false) | bool)
    - not (connection_state.unreachable | default(false) | bool)
  ignore_errors: true
  ignore_unreachable: true

- name: Normalize monitoring result
  ansible.builtin.set_fact:
    monitor_observation_valid: >-
      {{
        current_state is defined
        and not (current_state.skipped | default(false) | bool)
        and not (current_state.failed | default(false) | bool)
        and not (current_state.unreachable | default(false) | bool)
        and current_state.result is defined
      }}

- name: Mark confirmed upgrade failure
  ansible.builtin.set_fact:
    upgrade_failed: true
    upgrade_reason: "{{ current_state.result.reason }}"
  when:
    - monitor_observation_valid | bool
    - current_state.result.terminal_failure | default(false) | bool

- name: Mark upgrade completed
  ansible.builtin.set_fact:
    upgrade_complete: true
    upgrade_reason: "Windows Server 2022 detected"
  when:
    - monitor_observation_valid | bool
    - not (upgrade_failed | bool)
    - current_state.result.is2022 | default(false) | bool

- name: Record temporary connection or observation failure
  ansible.builtin.set_fact:
    upgrade_reason: >-
      WinRM unavailable or OS state could not be read.
      Retrying monitoring.
  when:
    - not (monitor_observation_valid | bool)
    - not (upgrade_complete | bool)
    - not (upgrade_failed | bool)

- name: Display monitoring status
  ansible.builtin.debug:
    msg:
      - "Attempt: {{ monitor_attempt }}/{{ monitor_max_attempts }}"
      - "Build: {{ (current_state.result | default({})).build | default('Unavailable') }}"
      - "Complete: {{ upgrade_complete }}"
      - "Failed: {{ upgrade_failed }}"
      - "Reason: {{ upgrade_reason }}"

- name: Fail on confirmed Setup failure
  ansible.builtin.fail:
    msg: "{{ upgrade_reason }}"
  when: upgrade_failed | bool

- name: Check monitoring deadline
  ansible.builtin.set_fact:
    monitor_deadline_reached: >-
      {{
        (lookup('pipe', 'date +%s') | int)
        >= (monitor_deadline_epoch | int)
      }}

- name: Fail on monitoring timeout
  ansible.builtin.fail:
    msg: >-
      Windows Server 2022 was not confirmed.
      Attempts: {{ monitor_attempt }}.
      Last status: {{ upgrade_reason }}.
      Check Setup logs and scheduled task before retrying.
  when:
    - not (upgrade_complete | bool)
    - >-
      (monitor_attempt | int) >= (monitor_max_attempts | int)
      or (monitor_deadline_reached | bool)

- name: Wait before next observation
  ansible.builtin.pause:
    seconds: 30
  when:
    - not (upgrade_complete | bool)
    - not (upgrade_failed | bool)

# IMPORTANT:
# Once upgrade_complete is true, this include is skipped.
# Control returns to main.yml.

- name: Continue monitoring only while upgrade is pending
  ansible.builtin.include_tasks:
    file: monitor_upgrade.yml
  when:
    - not (upgrade_complete | bool)
    - not (upgrade_failed | bool)
    - (monitor_attempt | int) < (monitor_max_attempts | int)
    - not (monitor_deadline_reached | bool)
