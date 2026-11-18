
---
# ============================================================
# WINDOWS SERVER 2016 -> 2022 UPGRADE EXECUTION
# ============================================================
# Requires:
#   upgrade_staging_directory
#   templates/start-upgrade.ps1.j2
#   tasks/monitor_upgrade.yml
#
# Success:
#   final_upgrade_success = true
#
# No upgrade is relaunched if existing activity is detected.
# ============================================================

# ============================================================
# 1. INITIALIZE VARIABLES
# ============================================================

- name: Initialize Windows upgrade variables
  ansible.builtin.set_fact:
    upgrade_complete: false
    upgrade_failed: false
    upgrade_reason: "Waiting for Windows Server 2022"
    upgrade_check_markers: false
    upgrade_started_this_run: false
    monitor_attempt: 0
    monitor_max_attempts: 180
    monitor_deadline_epoch: >-
      {{ (lookup('pipe', 'date +%s') | int) + 28800 }}
    final_upgrade_success: false
    upgrade_task_name: "Ansible-Windows-2022-Upgrade"

# ============================================================
# 2. CHECK CURRENT OPERATING SYSTEM
# ============================================================

- name: Check current Windows operating system
  ansible.windows.win_powershell:
    error_action: stop
    script: |
      $ErrorActionPreference = 'Stop'
      $Ansible.Changed = $false

      $os = Get-CimInstance Win32_OperatingSystem

      $is2016 = (
        [string]$os.BuildNumber -eq '14393' -and
        [int]$os.ProductType -ne 1 -and
        [string]$os.Caption -match 'Server 2016'
      )

      $is2022 = (
        [string]$os.BuildNumber -eq '20348' -and
        [int]$os.ProductType -ne 1 -and
        [string]$os.Caption -match 'Server 2022'
      )

      $Ansible.Result = @{
        caption = [string]$os.Caption
        build = [string]$os.BuildNumber
        is2016 = [bool]$is2016
        is2022 = [bool]$is2022
      }
  register: initial_os
  changed_when: false

- name: Display current operating system
  ansible.builtin.debug:
    msg:
      - "OS: {{ initial_os.result.caption }}"
      - "Build: {{ initial_os.result.build }}"

- name: Validate supported Windows version
  ansible.builtin.assert:
    that:
      - >-
        (initial_os.result.is2016 | bool)
        or (initial_os.result.is2022 | bool)
    fail_msg: >-
      Unsupported operating system:
      {{ initial_os.result.caption }}.
      Only Windows Server 2016 to 2022 is supported.

- name: Mark already upgraded Windows Server
  ansible.builtin.set_fact:
    upgrade_complete: true
    upgrade_reason: "Windows Server 2022 already installed"
  when: initial_os.result.is2022 | bool

# ============================================================
# 3. START UPGRADE ONLY WHEN REQUIRED
# ============================================================

- name: Execute Windows Server 2022 upgrade
  when: not (upgrade_complete | bool)
  block:

    # --------------------------------------------------------
    # 3.1 PREVENT DUPLICATE UPGRADE
    # --------------------------------------------------------

    - name: Check existing upgrade activity
      ansible.windows.win_powershell:
        error_action: stop
        parameters:
          TaskName: "{{ upgrade_task_name }}"
          StagingDirectory: "{{ upgrade_staging_directory }}"
        script: |
          param(
            [string]$TaskName,
            [string]$StagingDirectory
          )

          $ErrorActionPreference = 'Stop'
          $Ansible.Changed = $false

          $task = Get-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction SilentlyContinue

          $taskRunning = $false

          if ($task) {
            $taskRunning = (
              $task.State -eq 'Running'
            )
          }

          $setup = @(
            Get-Process -Name setup,setuphost,setupprep `
              -ErrorAction SilentlyContinue
          )

          $statusDir = Join-Path $StagingDirectory 'Status'

          $markerNames = @(
            'upgrade-started.json',
            'setup-returned.json',
            'launch-failed.json'
          )

          $existingMarkers = @(
            foreach ($name in $markerNames) {
              $path = Join-Path $statusDir $name

              if (Test-Path -LiteralPath $path) {
                $name
              }
            }
          )

          $Ansible.Result = @{
            task_running = [bool]$taskRunning
            setup_running = [bool]($setup.Count -gt 0)
            markers_present = [bool](
              $existingMarkers.Count -gt 0
            )
            marker_names = $existingMarkers
          }
      register: prelaunch_state
      changed_when: false

    - name: Prevent duplicate or uncertain upgrade execution
      ansible.builtin.assert:
        that:
          - not (prelaunch_state.result.task_running | bool)
          - not (prelaunch_state.result.setup_running | bool)
          - not (prelaunch_state.result.markers_present | bool)
        fail_msg: >-
          Existing Windows upgrade activity or status
          markers were detected.
          Task running:
          {{ prelaunch_state.result.task_running }}.
          Setup running:
          {{ prelaunch_state.result.setup_running }}.
          Markers:
          {{ prelaunch_state.result.marker_names }}.
          Upgrade was not launched.
          Investigate the existing attempt before retrying.

    # --------------------------------------------------------
    # 3.2 PREPARE UPGRADE LAUNCHER
    # --------------------------------------------------------

    - name: Create upgrade status directory
      ansible.windows.win_file:
        path: "{{ upgrade_staging_directory }}\\Status"
        state: directory

    - name: Install upgrade launcher script
      ansible.windows.win_template:
        src: start-upgrade.ps1.j2
        dest: "{{ upgrade_staging_directory }}\\start-upgrade.ps1"

    # --------------------------------------------------------
    # 3.3 REGISTER AND START SYSTEM TASK
    # --------------------------------------------------------

    - name: Register and start SYSTEM upgrade task
      ansible.windows.win_powershell:
        error_action: stop
        parameters:
          ScriptPath: "{{ upgrade_staging_directory }}\\start-upgrade.ps1"
          TaskName: "{{ upgrade_task_name }}"
        script: |
          param(
            [string]$ScriptPath,
            [string]$TaskName
          )

          $ErrorActionPreference = 'Stop'
          $Ansible.Changed = $false

          if (-not (Test-Path -LiteralPath $ScriptPath)) {
            throw "Upgrade launcher script not found"
          }

          $existing = Get-ScheduledTask `
            -TaskName $TaskName `
            -ErrorAction SilentlyContinue

          if ($existing) {
            if ($existing.State -eq 'Running') {
              throw "Upgrade task is already running"
            }

            Unregister-ScheduledTask `
              -TaskName $TaskName `
              -Confirm:$false
          }

          $action = New-ScheduledTaskAction `
            -Execute 'PowerShell.exe' `
            -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ScriptPath`""

          $principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

          $settings = New-ScheduledTaskSettingsSet `
            -StartWhenAvailable `
            -ExecutionTimeLimit (New-TimeSpan -Hours 8)

          Register-ScheduledTask `
            -TaskName $TaskName `
            -Action $action `
            -Principal $principal `
            -Settings $settings `
            -Force | Out-Null

          Start-ScheduledTask -TaskName $TaskName

          $Ansible.Changed = $true

          $Ansible.Result = @{
            started = $true
            task_name = $TaskName
          }
      register: upgrade_launch

    - name: Confirm upgrade task launched
      ansible.builtin.assert:
        that:
          - upgrade_launch.result.started | bool
        fail_msg: "Windows upgrade scheduled task failed to start"

    - name: Enable current upgrade status monitoring
      ansible.builtin.set_fact:
        upgrade_started_this_run: true
        upgrade_check_markers: true

    # --------------------------------------------------------
    # 3.4 MONITOR UPGRADE
    # --------------------------------------------------------

    - name: Reset WinRM connection before monitoring
      ansible.builtin.meta: reset_connection

    - name: Monitor Windows Server upgrade
      ansible.builtin.include_tasks:
        file: monitor_upgrade.yml

# ============================================================
# 4. CONFIRM WINDOWS SERVER 2022 DETECTED
# ============================================================

- name: Confirm Windows Server 2022 detected
  ansible.builtin.assert:
    that:
      - upgrade_complete | bool
      - not (upgrade_failed | bool)
    fail_msg: "{{ upgrade_reason }}"
    success_msg: "Windows Server 2022 detected"

# ============================================================
# 5. WAIT FOR WINDOWS SETUP COMPLETION
# ============================================================

- name: Wait until Windows Setup processes exit
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

      $setup = @(
        Get-Process -Name setup,setuphost,setupprep `
          -ErrorAction SilentlyContinue
      )

      $state = @{
        completed = [bool]($setup.Count -eq 0)
        terminal_failure = $false
        reason = 'Waiting for Windows Setup processes'
      }

      if ($CheckMarkers) {

        $statusDir = Join-Path $StagingDirectory 'Status'

        $failurePath = Join-Path `
          $statusDir 'launch-failed.json'

        $returnedPath = Join-Path `
          $statusDir 'setup-returned.json'

        if (Test-Path -LiteralPath $failurePath) {
          $state.terminal_failure = $true
          $state.reason = 'Upgrade launcher failure marker found'
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

            if (
              -not $exitHex -or
              $exitHex -notin @(
                '0X00000000',
                '0X00000BC2'
              )
            ) {
              $state.terminal_failure = $true
              $state.reason = "Setup result requires review: $exitHex"
            }
          }
          catch {
            $state.terminal_failure = $true
            $state.reason = "Invalid Setup result marker: $_"
          }
        }
      }

      $Ansible.Result = $state
  register: setup_status
  until: >-
    (setup_status.result.completed | default(false) | bool)
    or
    (setup_status.result.terminal_failure | default(false) | bool)
  retries: 240
  delay: 15
  changed_when: false

- name: Confirm Setup process monitoring passed
  ansible.builtin.assert:
    that:
      - setup_status.result.completed | bool
      - not (setup_status.result.terminal_failure | bool)
    fail_msg: "{{ setup_status.result.reason }}"
    success_msg: "Windows Setup processes have exited"

# ============================================================
# 6. RESTORE AND VALIDATE WINRM
# ============================================================

- name: Reset WinRM connection after upgrade
  ansible.builtin.meta: reset_connection

- name: Wait for WinRM connectivity
  ansible.builtin.wait_for_connection:
    delay: 15
    sleep: 15
    connect_timeout: 15
    timeout: 3600

- name: Verify PowerShell and WinRM
  ansible.windows.win_powershell:
    error_action: stop
    script: |
      $ErrorActionPreference = 'Stop'
      $Ansible.Changed = $false

      $service = Get-Service WinRM -ErrorAction Stop

      $Ansible.Result = @{
        winrm_ready = [bool](
          $service.Status -eq 'Running'
        )
        hostname = [string]$env:COMPUTERNAME
        service_status = [string]$service.Status
      }
  register: winrm_validation
  changed_when: false

- name: Confirm WinRM is operational
  ansible.builtin.assert:
    that:
      - winrm_validation.result.winrm_ready | bool
    fail_msg: "WinRM is not operational after upgrade"

# ============================================================
# 7. FINAL WINDOWS SERVER 2022 VALIDATION
# ============================================================

- name: Validate final Windows Server version
  ansible.windows.win_powershell:
    error_action: stop
    script: |
      $ErrorActionPreference = 'Stop'
      $Ansible.Changed = $false

      $os = Get-CimInstance Win32_OperatingSystem

      $setup = @(
        Get-Process -Name setup,setuphost,setupprep `
          -ErrorAction SilentlyContinue
      )

      $is2022 = (
        [string]$os.BuildNumber -eq '20348' -and
        [int]$os.ProductType -ne 1 -and
        [string]$os.Caption -match 'Server 2022'
      )

      $Ansible.Result = @{
        caption = [string]$os.Caption
        build = [string]$os.BuildNumber
        setup_running = [bool]($setup.Count -gt 0)
        success = [bool](
          $is2022 -and
          $setup.Count -eq 0
        )
      }
  register: final_validation
  changed_when: false

- name: Confirm final Windows Server 2022 validation
  ansible.builtin.assert:
    that:
      - final_validation.result.success | bool
    fail_msg: >-
      Windows Server 2022 validation failed.
      Build: {{ final_validation.result.build }}.
      Setup running:
      {{ final_validation.result.setup_running }}.
    success_msg: "Windows Server 2022 final validation passed"

# ============================================================
# 8. SAVE FINAL RESULT
# ============================================================

- name: Save final upgrade success
  ansible.builtin.set_fact:
    final_upgrade_success: true

- name: Confirm upgrade execution completed successfully
  ansible.builtin.assert:
    that:
      - upgrade_complete | bool
      - not (upgrade_failed | bool)
      - final_upgrade_success | bool
      - final_validation.result.success | bool
      - winrm_validation.result.winrm_ready | bool
    success_msg: >-
      Windows Server 2022 verified.
      WinRM operational.
      Returning to 03_upgrade.yml.

# ============================================================
# 9. DISPLAY FINAL STATUS
# ============================================================

- name: Display successful upgrade completion
  ansible.builtin.debug:
    msg:
      - "Windows Server 2022 upgrade execution completed"
      - "OS: {{ final_validation.result.caption }}"
      - "Build: {{ final_validation.result.build }}"
      - "Setup processes: Exited"
      - "WinRM: Ready"
      - "Final upgrade success: {{ final_upgrade_success }}"
      - "Returning to next task in 03_upgrade.yml"
