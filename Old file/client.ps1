
---
# Windows Server 2016 -> 2022 upgrade monitoring
# Called once from main.yml.
# Continues only while upgrade is pending.

- name: Increase monitoring attempt
  ansible.builtin.set_fact:
    monitor_attempt: "{{ (monitor_attempt | int) + 1 }}"

- name: Recover WinRM connection
  ansible.builtin.wait_for_connection:
    timeout: 300
    sleep: 15
  register: connection_state
  ignore_errors: true
  ignore_unreachable: true

- name: Check operating system state
  ansible.windows.win_powershell:
    error_action: stop
    parameters:
      StagingDirectory: "{{ upgrade_staging_directory }}"
    script: |
      param([string]$StagingDirectory)

      $ErrorActionPreference = 'Stop'
      $Ansible.Changed = $false

      $os = Get-CimInstance Win32_OperatingSystem

      $setup = @(
        Get-Process -Name setup,setuphost,setupprep `
          -ErrorAction SilentlyContinue
      )

      $result = @{
        is2022 = (
          $os.BuildNumber -eq '20348' -and
          $os.ProductType -ne 1
        )
        build = [string]$os.BuildNumber
        caption = [string]$os.Caption
        setup_running = ($setup.Count -gt 0)
        terminal_failure = $false
        reason = "Waiting for Windows Server 2022"
      }

      $statusDir = Join-Path $StagingDirectory 'Status'

      $failurePath = Join-Path $statusDir 'launch-failed.json'
      $returnedPath = Join-Path $statusDir 'setup-returned.json'

      if (Test-Path -LiteralPath $failurePath) {
        try {
          $failure = Get-Content $failurePath -Raw |
            ConvertFrom-Json

          $result.terminal_failure = $true
          $result.reason = "Launcher failed: $($failure.message)"
        }
        catch {
          $result.terminal_failure = $true
          $result.reason = "Cannot read launcher failure marker: $_"
        }
      }

      if (
        -not $result.terminal_failure -and
        (Test-Path -LiteralPath $returnedPath)
      ) {
        try {
          $returned = Get-Content $returnedPath -Raw |
            ConvertFrom-Json

          $exitHex = (
            [string]$returned.exit_code_hex
          ).ToUpperInvariant()

          if (
            $exitHex -and
            $exitHex -notin @('0X00000000','0X00000BC2')
          ) {
            $result.terminal_failure = $true
            $result.reason = "Setup returned failure: $exitHex"
          }
        }
        catch {
          $result.terminal_failure = $true
          $result.reason = "Cannot read Setup status marker: $_"
        }
      }

      if ($result.is2022 -and -not $result.terminal_failure) {
        $result.reason = "Windows Server 2022 detected"
      }

      $Ansible.Result = $result
  register: current_state
  when:
    - not (connection_state.failed | default(false) | bool)
    - not (connection_state.unreachable | default(false) | bool)
  ignore_errors: true
  ignore_unreachable: true

- name: Mark upgrade completed
  ansible.builtin.set_fact:
    upgrade_complete: true
    upgrade_failed: false
    upgrade_reason: "Windows Server 2022 detected"
  when:
    - not (current_state.failed | default(false) | bool)
    - not (current_state.unreachable | default(false) | bool)
    - current_state.result.is2022 | default(false) | bool
    - not (current_state.result.terminal_failure | default(false) | bool)

- name: Mark upgrade failed
  ansible.builtin.set_fact:
    upgrade_failed: true
    upgrade_reason: >-
      {{ current_state.result.reason |
         default('Windows Setup failed') }}
  when:
    - not (upgrade_complete | bool)
    - current_state.result.terminal_failure | default(false) | bool

- name: Show monitoring progress
  ansible.builtin.debug:
    msg:
      - "Attempt: {{ monitor_attempt }}/{{ monitor_max_attempts }}"
      - "Upgrade complete: {{ upgrade_complete }}"
      - "Upgrade failed: {{ upgrade_failed }}"
      - "Reason: {{ upgrade_reason }}"

- name: Stop on detected upgrade failure
  ansible.builtin.fail:
    msg: "{{ upgrade_reason }}"
  when: upgrade_failed | bool

- name: Stop on monitoring timeout
  ansible.builtin.fail:
    msg: >-
      Upgrade monitoring timed out after
      {{ monitor_attempt }} attempts.
      Last status: {{ upgrade_reason }}
  when:
    - not (upgrade_complete | bool)
    - (monitor_attempt | int) >= (monitor_max_attempts | int)

- name: Wait before next observation
  ansible.builtin.pause:
    seconds: 30
  when:
    - not (upgrade_complete | bool)
    - not (upgrade_failed | bool)

# Critical correction:
# Do not include another monitoring pass after success.

- name: Continue monitoring only while pending
  ansible.builtin.include_tasks:
    file: monitor_upgrade.yml
  when:
    - not (upgrade_complete | bool)
    - not (upgrade_failed | bool)
    - (monitor_attempt | int) < (monitor_max_attempts | int)
