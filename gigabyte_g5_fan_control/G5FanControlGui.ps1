<#
.SYNOPSIS
    Window for G5FanControl.ps1: speed slider, quiet curve, and a thermal guard you can switch off.

.DESCRIPTION
    Double-click G5FanControlGui.cmd. The window drives the fans while it is open;
    "Automatic" or closing the window gives them back to the firmware.
    Untick "Thermal guard" for no-limits mode: the speed is then held whatever the temperature.
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'wmi', 'ec')]
    [string]$Backend = 'auto',

    [string]$PawnIOModule,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$GuiScriptPath = $PSCommandPath
$CoreScriptPath = Join-Path $PSScriptRoot 'G5FanControl.ps1'
$CoreArgs = @{}
foreach ($key in $PSBoundParameters.Keys) { $CoreArgs[$key] = $PSBoundParameters[$key] }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Show-GuiMessage([string]$Text, [string]$Icon = 'Error') {
    [void][System.Windows.Forms.MessageBox]::Show($Text, 'G5 fan control', 'OK', $Icon)
}

# Relaunch elevated (hidden console, same arguments).
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$GuiScriptPath`"")
    foreach ($key in $CoreArgs.Keys) {
        if ($CoreArgs[$key] -is [switch]) {
            if ($CoreArgs[$key].IsPresent) { $arguments += "-$key" }
        }
        else {
            $arguments += "-$key", "`"$($CoreArgs[$key])`""
        }
    }
    try { Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList ($arguments -join ' ') }
    catch { Show-GuiMessage 'Administrator rights are needed to control the fans.' }
    return
}

# Sharp text on scaled displays; must happen before the first window is created.
try {
    Add-Type -Namespace G5FanControlGui -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][G5FanControlGui.Native]::SetProcessDPIAware()
}
catch { }   # cosmetic only
[System.Windows.Forms.Application]::EnableVisualStyles()

# The engine: backends, controller, logon task. Dot-sourcing only loads its functions.
. $CoreScriptPath @CoreArgs

New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
try {
    Assert-SupportedModel
    Initialize-Backend
}
catch {
    Show-GuiMessage (Get-ErrorText $_)
    return
}

$script:GuiCtl = $null   # controller state while this window drives the fans

# ---------------------------------------------------------------- logic

function Invoke-GuiSafely([scriptblock]$Action) {
    try { & $Action }
    catch {
        Write-FanLog "Error: $(Get-ErrorText $_)" 'Red'
        Show-GuiMessage (Get-ErrorText $_)
    }
}

function Add-GuiLog([string]$Line) {
    if ($logBox.TextLength -gt 30000) { $logBox.Text = $logBox.Text.Substring(15000) }
    $logBox.AppendText($Line + [Environment]::NewLine)
}

function Start-GuiControl([string]$Mode, [int]$Percent = 0) {
    $noGuard = -not $guardBox.Checked
    $points = $null
    if ($Mode -eq 'quiet') {
        $points = ConvertFrom-CurveText $curveBox.Text
        $script:Curve = $curveBox.Text
    }
    if ($script:GuiCtl) {
        # Already in charge: change the target, the tick below applies it.
        $script:GuiCtl.Mode = $Mode
        $script:GuiCtl.FixedPercent = $Percent
        $script:GuiCtl.CurvePoints = $points
        $script:GuiCtl.NoGuard = $noGuard
        $what = if ($Mode -eq 'set') { "fans at $Percent%" } else { "quiet curve $($curveBox.Text)" }
        Write-FanLog "Now: $what$(if ($noGuard) { ' - NO LIMITS' })."
    }
    else {
        Enter-ControllerLock
        try { $script:GuiCtl = New-FanController -Mode $Mode -FixedPercent $Percent -CurvePoints $points -NoGuard:$noGuard }
        catch {
            Exit-ControllerLock
            throw
        }
    }
    Invoke-GuiTick
}

function Stop-GuiControl([string]$Reason) {
    if (-not $script:GuiCtl) { return }
    $script:GuiCtl = $null
    if ($Reason) { Write-FanLog $Reason }
    Stop-FanController
    Exit-ControllerLock
}

function Invoke-GuiTick {
    $state = $null
    if ($script:GuiCtl) {
        if ($script:StopEvent.WaitOne(0)) {
            Stop-GuiControl 'Another G5FanControl instance (console or logon task) took over.'
        }
        else {
            try {
                Invoke-FanControllerStep $script:GuiCtl
                $state = $script:GuiCtl.State
            }
            catch {
                Stop-GuiControl "Stopped: $(Get-ErrorText $_)"
            }
        }
    }
    if (-not $script:GuiCtl) {
        try { $state = Get-FanState } catch { $state = $null }
    }
    Update-GuiReadout $state
}

function Format-GuiFan([string]$Name, $Duty, $Rpm) {
    if ($null -eq $Duty) { return "${Name}: --" }
    $text = "${Name}: $Duty%"
    if ($null -ne $Rpm) { $text += "   $Rpm rpm" }
    return $text
}

function Update-GuiReadout($State) {
    if ($State) {
        $cpuValue.Text = if (Test-ValidTemp $State.CpuTemp) { "$($State.CpuTemp)$DegC" } else { '--' }
        $gpuValue.Text = if (Test-ValidTemp $State.GpuTemp) { "$($State.GpuTemp)$DegC" } else { '--' }
        $fan1Value.Text = Format-GuiFan 'Fan 1 (CPU)' $State.Fan1Duty $State.Fan1Rpm
        $fan2Value.Text = Format-GuiFan 'Fan 2 (GPU)' $State.Fan2Duty $State.Fan2Rpm
    }
    else {
        $cpuValue.Text = '?'
        $gpuValue.Text = '?'
        $fan1Value.Text = Format-GuiFan 'Fan 1 (CPU)' $null $null
        $fan2Value.Text = Format-GuiFan 'Fan 2 (GPU)' $null $null
    }

    if ($script:GuiCtl) {
        $text = Get-ControllerModeText $script:GuiCtl
        $modeValue.Text = 'Mode: ' + $text.Substring(0, 1).ToUpper() + $text.Substring(1)
        $modeValue.ForeColor = [System.Drawing.Color]::ForestGreen
        if ($script:GuiCtl.Released) { $modeValue.ForeColor = [System.Drawing.Color]::DarkOrange }
        if ($script:GuiCtl.NoGuard) { $modeValue.ForeColor = [System.Drawing.Color]::Firebrick }
    }
    elseif (Test-ControllerRunning) {
        $modeValue.Text = 'Mode: controlled by another instance (logon task or console)'
        $modeValue.ForeColor = [System.Drawing.Color]::DarkOrange
    }
    else {
        $modeValue.Text = 'Mode: automatic (firmware)'
        $modeValue.ForeColor = [System.Drawing.SystemColors]::ControlText
    }
}

function Update-GuardNote {
    if ($guardBox.Checked) {
        $guardNote.Text = 'Above the limit the firmware cools as usual; this window takes over again once it has cooled to the resume temperature.'
        $guardNote.ForeColor = [System.Drawing.SystemColors]::GrayText
    }
    else {
        $guardNote.Text = 'NO LIMITS: the firmware never takes over, whatever the temperature. Only the CPU and GPU''s own throttling and shutdown protect the hardware.'
        $guardNote.ForeColor = [System.Drawing.Color]::Firebrick
    }
}

# ---------------------------------------------------------------- window

function New-Control([string]$Type, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Text, $Parent) {
    $control = New-Object "System.Windows.Forms.$Type"
    $control.Location = New-Object System.Drawing.Point($X, $Y)
    $control.Size = New-Object System.Drawing.Size($Width, $Height)
    if ($Text) { $control.Text = $Text }
    $Parent.Controls.Add($control)
    return $control
}

$form = New-Object System.Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.Text = 'G5 fan control'
$form.ClientSize = New-Object System.Drawing.Size(460, 604)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$bigFont = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
$boldFont = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)

# Readout
$cpuCaption = New-Control Label 16 10 110 18 'CPU' $form
$cpuCaption.ForeColor = [System.Drawing.SystemColors]::GrayText
$cpuValue = New-Control Label 16 28 110 40 '--' $form
$cpuValue.Font = $bigFont
$gpuCaption = New-Control Label 130 10 110 18 'GPU' $form
$gpuCaption.ForeColor = [System.Drawing.SystemColors]::GrayText
$gpuValue = New-Control Label 130 28 110 40 '--' $form
$gpuValue.Font = $bigFont
$fan1Value = New-Control Label 244 24 208 20 '' $form
$fan2Value = New-Control Label 244 46 208 20 '' $form
$modeValue = New-Control Label 16 76 436 20 'Mode: automatic (firmware)' $form
$modeValue.Font = $boldFont
$interfaceLabel = New-Control Label 16 98 436 18 "Interface: $script:BackendName" $form
$interfaceLabel.ForeColor = [System.Drawing.SystemColors]::GrayText

# Fixed speed
$speedGroup = New-Control GroupBox 12 122 436 116 'Fixed speed' $form
$speedBar = New-Control TrackBar 10 22 330 45 '' $speedGroup
$speedBar.Minimum = 0
$speedBar.Maximum = 100
$speedBar.TickFrequency = 10
$speedBar.SmallChange = 1
$speedBar.LargeChange = 5
$speedBar.Value = 10
$speedValue = New-Control Label 346 24 84 32 '10%' $speedGroup
$speedValue.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$offButton = New-Control Button 10 74 100 30 'Fans OFF' $speedGroup
$tenButton = New-Control Button 116 74 80 30 '10%' $speedGroup
$applyButton = New-Control Button 202 74 140 30 'Apply slider speed' $speedGroup

# Quiet curve
$curveGroup = New-Control GroupBox 12 246 436 62 'Quiet curve (temperature:percent)' $form
$curveBox = New-Control TextBox 10 25 280 24 $Curve $curveGroup
$quietButton = New-Control Button 298 22 128 30 'Start quiet curve' $curveGroup

# Thermal guard
$guardGroup = New-Control GroupBox 12 316 436 96 'Thermal guard' $form
$guardBox = New-Control CheckBox 10 24 214 24 'Hand back to the firmware at' $guardGroup
$guardBox.Checked = $true
$releaseBox = New-Control NumericUpDown 226 24 52 24 '' $guardGroup
$releaseBox.Minimum = 50
$releaseBox.Maximum = 95
$releaseBox.Value = $ReleaseTemp
[void](New-Control Label 282 27 90 20 "$DegC, resume at" $guardGroup)
$resumeBox = New-Control NumericUpDown 372 24 52 24 '' $guardGroup
$resumeBox.Minimum = 30
$resumeBox.Maximum = [math]::Min(90, $ReleaseTemp - 1)
$resumeBox.Value = $ResumeTemp
$guardNote = New-Control Label 10 54 416 36 '' $guardGroup

# Actions
$autoButton = New-Control Button 12 420 150 32 'Automatic (firmware)' $form
$taskButton = New-Control Button 168 420 160 32 'Run this mode at logon' $form
$untaskButton = New-Control Button 334 420 114 32 'Remove logon task' $form

# Event log
$logBox = New-Control TextBox 12 462 436 130 '' $form
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.Font = New-Object System.Drawing.Font('Consolas', 8)

$form.ResumeLayout($false)
$form.PerformLayout()
Update-GuardNote

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $Interval * 1000

# ---------------------------------------------------------------- events

$script:LogSink = { param($line) Add-GuiLog $line }

$speedBar.Add_ValueChanged({
    $speedValue.Text = "$($speedBar.Value)%"
    # While holding a fixed speed, the slider adjusts it live (applied on the next tick).
    if ($script:GuiCtl -and $script:GuiCtl.Mode -eq 'set') { $script:GuiCtl.FixedPercent = $speedBar.Value }
})
$offButton.Add_Click({ Invoke-GuiSafely { $speedBar.Value = 0; Start-GuiControl 'set' 0 } })
$tenButton.Add_Click({ Invoke-GuiSafely { $speedBar.Value = 10; Start-GuiControl 'set' 10 } })
$applyButton.Add_Click({ Invoke-GuiSafely { Start-GuiControl 'set' $speedBar.Value } })
$quietButton.Add_Click({ Invoke-GuiSafely { Start-GuiControl 'quiet' } })

$guardBox.Add_CheckedChanged({
    Update-GuardNote
    if ($script:GuiCtl) {
        $script:GuiCtl.NoGuard = -not $guardBox.Checked
        if ($guardBox.Checked) { Write-FanLog 'Thermal guard on.' 'Green' }
        else { Write-FanLog 'Thermal guard off - NO LIMITS.' 'Yellow' }
    }
})
$releaseBox.Add_ValueChanged({
    $script:ReleaseTemp = [int]$releaseBox.Value
    $resumeBox.Maximum = [math]::Min(90, $script:ReleaseTemp - 1)
})
$resumeBox.Add_ValueChanged({ $script:ResumeTemp = [int]$resumeBox.Value })

$autoButton.Add_Click({
    Invoke-GuiSafely {
        if ($script:GuiCtl) { Stop-GuiControl 'Back to automatic.' }
        else { Set-FirmwareControl }
        Invoke-GuiTick
    }
})
$taskButton.Add_Click({
    Invoke-GuiSafely {
        if (-not $script:GuiCtl) {
            Show-GuiMessage 'Start the mode you want first (a speed or the quiet curve), then click this again.' 'Information'
            return
        }
        $what = if ($script:GuiCtl.Mode -eq 'quiet') { 'quiet' } else { "$($script:GuiCtl.FixedPercent)" }
        $label = if ($what -eq 'quiet') { 'the quiet curve' } else { "fans at $what%" }
        if ($script:GuiCtl.NoGuard) { $label += ', NO LIMITS' }
        $answer = [System.Windows.Forms.MessageBox]::Show("Run $label hidden at every logon?`n`nThe logon task takes over from this window now. Use 'Remove logon task' to undo.", 'G5 fan control', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { return }
        $script:NoGuard = [switch]$script:GuiCtl.NoGuard
        Install-LogonTask $what
    }
})
$untaskButton.Add_Click({
    Invoke-GuiSafely {
        Stop-GuiControl $null
        Remove-LogonTask
        Invoke-GuiTick
    }
})

$timer.Add_Tick({
    try { Invoke-GuiTick }
    catch { Write-FanLog "Error: $(Get-ErrorText $_)" 'Red' }
})
$form.Add_Shown({
    Add-GuiLog "Interface: $script:BackendName. Log file: $LogFile"
    Invoke-GuiTick
    $timer.Start()
})
$form.Add_FormClosing({
    $timer.Stop()
    Stop-GuiControl 'Window closed.'
})

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
