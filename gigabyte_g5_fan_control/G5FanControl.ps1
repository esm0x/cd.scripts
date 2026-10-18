<#
.SYNOPSIS
    Fan control for the Gigabyte G5 KF / KF5 (Clevo NP50RND platform): run the fans
    below the firmware's ~30% floor, or switch them off, with a thermal guard.

.DESCRIPTION
    The firmware never lets the fans drop below roughly 28-30% duty. This script takes
    over the fans through the same embedded-controller commands the vendor software uses,
    and keeps a thermal guard running the whole time:

      * at -ReleaseTemp (default 80 C) the fans are handed back to the firmware,
      * at -ResumeTemp  (default 65 C) the script takes control again,
      * when the script stops (Q, Esc, Ctrl+C or another command) the fans go back to
        automatic, and so do they if temperatures cannot be read.

    -NoGuard switches the guard off (no-limits mode): the speed is held whatever the
    temperature. Only the CPU's and GPU's own throttling and shutdown limits remain.
    For a window instead of a console, run G5FanControlGui.ps1.

    Two ways to reach the fans are tried, in this order:
      WMI - Clevo WMBB method (ACPI WMI GUID ABBC0F6D-8EA1-11D1-00A0-C90629100000).
            Built into Windows; the script registers a small WMI class with mofcomp once.
      EC  - Clevo EC mailbox (doorbell 0xC1 at 0xF8) through the PawnIO driver.
            Needs PawnIO installed and LpcACPIEC.bin next to this script. See README.md.

.EXAMPLE
    .\G5FanControl.ps1
    Interactive menu.

.EXAMPLE
    .\G5FanControl.ps1 set 0
    Fans off until the laptop warms up to 80 C. Press Q to stop.

.EXAMPLE
    .\G5FanControl.ps1 set 0 -NoGuard
    Fans off, and the firmware never takes over while the script runs.

.EXAMPLE
    .\G5FanControl.ps1 quiet -Curve "62:0,63:20,72:35,78:50"
    Temperature curve: off while cool, gentle ramp when warm.

.EXAMPLE
    .\G5FanControl.ps1 install-task quiet
    Run the quiet curve in the background at every logon.
#>
[CmdletBinding()]
param(
    # menu | status | set | quiet | auto | install-task | remove-task | uninstall | help
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'status', 'set', 'quiet', 'auto', 'install-task', 'remove-task', 'uninstall', 'help')]
    [string]$Command = 'menu',

    # 'set': fan speed in percent. 'install-task': 'quiet' or a percentage.
    [Parameter(Position = 1)]
    [string]$Value,

    # Quiet-mode curve as temperature:percent pairs. Linear in between, flat outside.
    [string]$Curve = '60:0,61:20,70:30,76:45',

    # Hand the fans back to the firmware at this temperature (C).
    [ValidateRange(50, 95)]
    [int]$ReleaseTemp = 80,

    # Take fan control back once cooled down to this temperature (C).
    [ValidateRange(30, 90)]
    [int]$ResumeTemp = 65,

    # Quiet mode only slows the fans down after cooling this many degrees (C).
    [ValidateRange(0, 15)]
    [int]$Hysteresis = 4,

    # Seconds between updates. The EC drops manual mode if it is not refreshed.
    [ValidateRange(1, 10)]
    [int]$Interval = 2,

    [ValidateSet('auto', 'wmi', 'ec')]
    [string]$Backend = 'auto',

    # PawnIO LpcACPIEC.bin module for the EC backend (default: next to this script).
    [string]$PawnIOModule,

    # No-limits mode: never hand the fans back to the firmware, whatever the temperature.
    [switch]$NoGuard,

    # Skip the model check.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$BoundParameters = $PSBoundParameters

# ---------------------------------------------------------------- constants

$ClevoWmiGuid  = 'ABBC0F6D-8EA1-11D1-00A0-C90629100000'
$WmiNamespace  = 'root/wmi'
$WmiClassName  = 'G5FanControl_ClevoWmbb'
$TaskName      = 'G5FanControl'
$MutexName     = 'Global\G5FanControl.Controller'
$StopEventName = 'Global\G5FanControl.Stop'
$DataDir       = Join-Path $env:ProgramData 'G5FanControl'
$LogFile       = Join-Path $DataDir 'G5FanControl.log'
$DegC          = "$([char]0xB0)C"

if (-not $PawnIOModule) { $PawnIOModule = Join-Path $PSScriptRoot 'LpcACPIEC.bin' }

# Clevo EC registers and mailbox (reverse-engineered on the G6 KF, same platform).
$EcRegCpuTemp = 0x07
$EcRegGpuTemp = 0x0A
$EcRegDuty1   = 0xCE
$EcRegDuty2   = 0xCF
$EcRegTach1   = 0xD0   # 16-bit big-endian period, 0xD0-0xD1
$EcRegTach2   = 0xD2   # 0xD2-0xD3
$EcFanCommand = 0xC1   # doorbell: FDAT = fan (1 CPU, 2 GPU) or 0xFF for auto, FBUF = duty or fan

# Clevo WMBB method ids are the same command ids the Linux tuxedo/clevo drivers use:
# 0x63/0x64 fan info, 0x68 set duty, 0x69 auto, 0x70 tachometers.
$ClevoMof = @'
#pragma namespace("\\\\.\\root\\wmi")
#pragma classflags("forceupdate")

[WMI, Dynamic, Provider("WmiProv"), Locale("MS\\0x409"),
 Description("Clevo WMBB fan methods, registered by G5FanControl.ps1"),
 guid("{ABBC0F6D-8EA1-11d1-00A0-C90629100000}")]
class G5FanControl_ClevoWmbb
{
    [key, read] string InstanceName;
    [read] boolean Active;

    [WmiMethodId(99), Implemented, read, write, Description("Fan 1 info: duty in bits 0-7, temperature in bits 16-23")]
    void Fan1Info([in, Description("Unused")] uint32 Data, [out, Description("Fan info")] uint32 Data1);

    [WmiMethodId(100), Implemented, read, write, Description("Fan 2 info: duty in bits 0-7, temperature in bits 16-23")]
    void Fan2Info([in, Description("Unused")] uint32 Data, [out, Description("Fan info")] uint32 Data1);

    [WmiMethodId(104), Implemented, read, write, Description("Set fan duty, one byte per fan")]
    void SetFanDuty([in, Description("Duties")] uint32 Data, [out, Description("Result")] uint16 Data1);

    [WmiMethodId(105), Implemented, read, write, Description("Return fans to automatic, one bit per fan")]
    void SetFanAutoDuty([in, Description("Fan mask")] uint32 Data, [out, Description("Result")] uint16 Data1);

    [WmiMethodId(112), Implemented, read, write, Description("Fan 1 and 2 tachometer periods")]
    void GetFan12RPM([in, Description("Unused")] uint32 Data, [out, Description("Periods")] uint32 Data1);
};
'@

$ClevoMofRemove = @'
#pragma namespace("\\\\.\\root\\wmi")
#pragma deleteclass("G5FanControl_ClevoWmbb", NOFAIL)
'@

# ACPI embedded controller access through the PawnIO driver's LpcACPIEC module.
# Kept to C# 5 so it compiles under Windows PowerShell 5.1.
$PawnEcSource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace G5FanControl
{
    public sealed class PawnEc : IDisposable
    {
        private const uint PawnDeviceType = 41394u << 16;
        private const uint IoctlLoadBinary = PawnDeviceType | (0x821u << 2);
        private const uint IoctlExecute = PawnDeviceType | (0x841u << 2);
        private const int FunctionNameLength = 32;

        private const byte DataPort = 0x62;
        private const byte CommandPort = 0x66;
        private const byte OutputBufferFull = 0x01;
        private const byte InputBufferFull = 0x02;
        private const byte EcReadCommand = 0x80;
        private const byte EcWriteCommand = 0x81;

        private const byte MailboxCommand = 0xF8;
        private const byte MailboxData = 0xF9;
        private const byte MailboxBuffer = 0xFA;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern SafeFileHandle CreateFile(string fileName, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool DeviceIoControl(SafeFileHandle device, uint code, byte[] input, int inputSize,
            byte[] output, int outputSize, out int returned, IntPtr overlapped);

        private readonly SafeFileHandle device;
        private readonly Mutex ecMutex;

        public PawnEc(byte[] module)
        {
            // FILE_READ_DATA | FILE_WRITE_DATA, shared read/write, OPEN_EXISTING - as LibreHardwareMonitor opens it.
            device = CreateFile(@"\\?\GLOBALROOT\Device\PawnIO", 3, 3, IntPtr.Zero, 3, 0x80, IntPtr.Zero);
            if (device.IsInvalid)
                throw new IOException("cannot open the PawnIO driver (Win32 error " + Marshal.GetLastWin32Error() + "). Is PawnIO installed?");

            int returned;
            if (!DeviceIoControl(device, IoctlLoadBinary, module, module.Length, null, 0, out returned, IntPtr.Zero))
            {
                int error = Marshal.GetLastWin32Error();
                device.Dispose();
                throw new IOException("PawnIO rejected the LpcACPIEC module (Win32 error " + error + ").");
            }

            // Shared with LibreHardwareMonitor, FanControl, HWiNFO and others that talk to the EC.
            try { ecMutex = new Mutex(false, @"Global\Access_EC"); }
            catch (UnauthorizedAccessException) { ecMutex = null; }
        }

        public byte Read(byte register)
        {
            Lock();
            try { return ReadUnlocked(register); }
            finally { Unlock(); }
        }

        // Clevo EC mailbox: parameters first, the command byte last (it is the doorbell).
        public void SendMailbox(byte command, byte data, byte buffer)
        {
            Lock();
            try
            {
                WaitMailboxIdle();
                WriteUnlocked(MailboxData, data);
                WriteUnlocked(MailboxBuffer, buffer);
                WriteUnlocked(MailboxCommand, command);
                WaitMailboxIdle();
            }
            finally { Unlock(); }
        }

        public void Dispose()
        {
            device.Dispose();
            if (ecMutex != null) ecMutex.Dispose();
        }

        private void Lock()
        {
            if (ecMutex == null) return;
            try
            {
                if (!ecMutex.WaitOne(2000))
                    throw new IOException("timed out waiting for the Global\\Access_EC mutex.");
            }
            catch (AbandonedMutexException) { }
        }

        private void Unlock()
        {
            if (ecMutex != null) ecMutex.ReleaseMutex();
        }

        // The EC clears the command byte once it has consumed a mailbox command.
        private void WaitMailboxIdle()
        {
            for (int i = 0; i < 50; i++)
            {
                if (ReadUnlocked(MailboxCommand) == 0) return;
                Thread.Sleep(10);
            }
        }

        private byte ReadUnlocked(byte register)
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                if ((InPort(CommandPort) & OutputBufferFull) != 0) InPort(DataPort); // drop a stale byte
                if (!WaitStatus(InputBufferFull, false)) continue;
                OutPort(CommandPort, EcReadCommand);
                if (!WaitStatus(InputBufferFull, false)) continue;
                OutPort(DataPort, register);
                if (!WaitStatus(OutputBufferFull, true)) continue;
                return InPort(DataPort);
            }
            throw new IOException("EC read of register 0x" + register.ToString("X2") + " timed out.");
        }

        private void WriteUnlocked(byte register, byte value)
        {
            for (int attempt = 0; attempt < 5; attempt++)
            {
                if (!WaitStatus(InputBufferFull, false)) continue;
                OutPort(CommandPort, EcWriteCommand);
                if (!WaitStatus(InputBufferFull, false)) continue;
                OutPort(DataPort, register);
                if (!WaitStatus(InputBufferFull, false)) continue;
                OutPort(DataPort, value);
                if (WaitStatus(InputBufferFull, false)) return;
            }
            throw new IOException("EC write of register 0x" + register.ToString("X2") + " timed out.");
        }

        private bool WaitStatus(byte mask, bool set)
        {
            for (int i = 0; i < 500; i++)
            {
                if (((InPort(CommandPort) & mask) != 0) == set) return true;
                if (i > 20) Thread.Sleep(1);
            }
            return false;
        }

        private byte InPort(byte port)
        {
            return (byte)Execute("ioctl_pio_read", new long[] { port }, 1)[0];
        }

        private void OutPort(byte port, byte value)
        {
            Execute("ioctl_pio_write", new long[] { port, value }, 0);
        }

        private long[] Execute(string function, long[] input, int outputCount)
        {
            byte[] inBuffer = new byte[FunctionNameLength + input.Length * 8];
            byte[] name = Encoding.ASCII.GetBytes(function);
            Buffer.BlockCopy(name, 0, inBuffer, 0, Math.Min(name.Length, FunctionNameLength - 1));
            Buffer.BlockCopy(input, 0, inBuffer, FunctionNameLength, input.Length * 8);

            byte[] outBuffer = new byte[outputCount * 8];
            int returned;
            if (!DeviceIoControl(device, IoctlExecute, inBuffer, inBuffer.Length, outBuffer, outBuffer.Length, out returned, IntPtr.Zero))
                throw new IOException("PawnIO " + function + " failed (Win32 error " + Marshal.GetLastWin32Error() + ").");

            long[] result = new long[outputCount];
            Buffer.BlockCopy(outBuffer, 0, result, 0, Math.Min(returned, outBuffer.Length));
            return result;
        }
    }
}
'@

# ---------------------------------------------------------------- helpers

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Restart-Elevated {
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
    if ($Command -ne 'menu') { $arguments += '-NoExit' }
    $arguments += @('-File', "`"$PSCommandPath`"")
    foreach ($entry in $BoundParameters.GetEnumerator()) {
        if ($entry.Value -is [switch]) {
            if ($entry.Value.IsPresent) { $arguments += "-$($entry.Key)" }
        }
        else {
            $arguments += "-$($entry.Key)"
            $arguments += "`"$($entry.Value)`""
        }
    }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList ($arguments -join ' ')
    }
    catch {
        Write-Host 'Administrator rights are needed to talk to the fan controller.' -ForegroundColor Red
    }
}

function Get-ErrorText($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    return $exception.Message
}

function Write-FanLog([string]$Message, [string]$Color = 'Gray') {
    if ($script:StatusLength) {
        Write-Host ("`r" + (' ' * $script:StatusLength) + "`r") -NoNewline
        $script:StatusLength = 0
    }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line -ForegroundColor $Color
    if ($script:LogSink) { & $script:LogSink $line }   # the GUI shows events too
    try {
        if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
            Remove-Item -LiteralPath $LogFile
        }
        Add-Content -LiteralPath $LogFile -Value $line -Encoding ASCII
    }
    catch { }   # logging must never stop fan control
}

function ConvertTo-Percent([string]$Text) {
    if ($Text -notmatch '^\s*(\d{1,3})\s*%?\s*$' -or [int]$Matches[1] -gt 100) {
        throw "Fan speed must be a number from 0 to 100, got '$Text'."
    }
    return [int]$Matches[1]
}

function ConvertTo-RawDuty([int]$Percent) {
    return [int][math]::Round($Percent * 255 / 100)
}

function ConvertTo-DutyPercent([int]$Raw) {
    return [int][math]::Round($Raw * 100 / 255)
}

# Argument for Clevo command 0x68: one duty byte per fan (fan 1, fan 2, fan 3).
function Get-WmbbDutyArgument([int]$Percent) {
    $raw = ConvertTo-RawDuty $Percent
    return [uint32]($raw -bor ($raw -shl 8) -bor ($raw -shl 16))
}

function ConvertFrom-TachPeriod([int]$Period) {
    if ($Period -le 0 -or $Period -ge 0xFF00) { return 0 }
    return [int][math]::Round(2156220 / $Period)
}

# The WMI tachometer word may come back byte-swapped; take the reading that is a plausible rpm.
function ConvertFrom-TachWord([int]$Word) {
    if ($Word -eq 0 -or $Word -ge 0xFF00) { return 0 }
    $rpm = ConvertFrom-TachPeriod $Word
    if ($rpm -ge 300 -and $rpm -le 9000) { return $rpm }
    $swapped = (($Word -band 0xFF) -shl 8) -bor (($Word -shr 8) -band 0xFF)
    $rpm = ConvertFrom-TachPeriod $swapped
    if ($rpm -ge 300 -and $rpm -le 9000) { return $rpm }
    return $null
}

function Test-ValidTemp($Temp) {
    return ($null -ne $Temp) -and ($Temp -ge 5) -and ($Temp -le 125)
}

function ConvertFrom-CurveText([string]$Text) {
    $points = @()
    foreach ($pair in ($Text -split '[,; ]+' | Where-Object { $_ })) {
        if ($pair -notmatch '^(\d{1,3}):(\d{1,3})%?$') {
            throw "Bad curve point '$pair'. Use temperature:percent pairs, for example 60:0,70:30."
        }
        $points += [pscustomobject]@{ Temp = [int]$Matches[1]; Duty = [int]$Matches[2] }
    }
    if ($points.Count -eq 0) { throw 'The fan curve is empty.' }
    for ($i = 0; $i -lt $points.Count; $i++) {
        if ($points[$i].Duty -gt 100) { throw "Curve point $($points[$i].Temp):$($points[$i].Duty) is above 100%." }
        if ($i -gt 0 -and $points[$i].Temp -le $points[$i - 1].Temp) { throw 'Curve temperatures must increase.' }
        if ($i -gt 0 -and $points[$i].Duty -lt $points[$i - 1].Duty) { throw 'Curve speeds must not decrease.' }
    }
    return , $points
}

function Get-CurveDuty([object[]]$Points, [int]$Temp) {
    if ($Temp -le $Points[0].Temp) { return [int]$Points[0].Duty }
    for ($i = 1; $i -lt $Points.Count; $i++) {
        if ($Temp -le $Points[$i].Temp) {
            $a = $Points[$i - 1]
            $b = $Points[$i]
            return [int][math]::Round($a.Duty + ($b.Duty - $a.Duty) * ($Temp - $a.Temp) / ($b.Temp - $a.Temp))
        }
    }
    return [int]$Points[-1].Duty
}

# Curve duty with hysteresis: speed up right away, slow down only after cooling $Hysteresis degrees.
function Get-QuietDuty([object[]]$Points, [int]$Temp, [int]$Current, [int]$Hysteresis) {
    $target = Get-CurveDuty $Points $Temp
    if ($Current -ge 0 -and $target -lt $Current) {
        $target = [math]::Min($Current, (Get-CurveDuty $Points ($Temp + $Hysteresis)))
    }
    return [int]$target
}

# Hottest readable temperature. $null when the CPU temperature is unreadable.
function Get-ControlTemp($State) {
    if (-not $State -or -not (Test-ValidTemp $State.CpuTemp)) { return $null }
    $temp = [int]$State.CpuTemp
    if ((Test-ValidTemp $State.GpuTemp) -and $State.GpuTemp -gt $temp) { $temp = [int]$State.GpuTemp }
    return $temp
}

function Format-FanState($State) {
    if (-not $State) { return 'no reading' }
    $parts = foreach ($fan in @(@($State.Fan1Duty, $State.Fan1Rpm), @($State.Fan2Duty, $State.Fan2Rpm))) {
        if ($null -ne $fan[1]) { '{0}% {1}rpm' -f $fan[0], $fan[1] } else { '{0}%' -f $fan[0] }
    }
    $cpu = if (Test-ValidTemp $State.CpuTemp) { "$($State.CpuTemp)$DegC" } else { '--' }
    $gpu = if (Test-ValidTemp $State.GpuTemp) { "$($State.GpuTemp)$DegC" } else { '--' }
    return "CPU $cpu  GPU $gpu  |  fan1 $($parts[0])  fan2 $($parts[1])"
}

function Get-ControllerModeText($Ctl) {
    if ($Ctl.Released) { return 'firmware (warm)' }
    if ($Ctl.Commanded -lt 0) { return 'firmware' }
    $text = "holding $($Ctl.Commanded)%"
    if ($Ctl.Mode -eq 'quiet') { $text += ' (quiet curve)' }
    if ($Ctl.NoGuard) { $text += ' - NO LIMITS' }
    return $text
}

function Write-StatusLine($Ctl) {
    $text = '{0:HH:mm:ss}  {1}  |  {2}   [Q = stop]' -f (Get-Date), (Format-FanState $Ctl.State), (Get-ControllerModeText $Ctl)
    Write-Host ("`r" + $text.PadRight([int]$script:StatusLength)) -NoNewline
    $script:StatusLength = $text.Length
}

function Assert-SupportedModel {
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $board = (Get-CimInstance -ClassName Win32_BaseBoard).Product
    $isGigabyte = $system.Manufacturer -match 'GIGABYTE'
    $isG = ($system.Model -match '\bG[5-7]\s+[A-Z]{1,3}\d?\b') -or ($board -match '\bG[5-7]\s+[A-Z]{1,3}\d?\b|NP[5-7]0')
    if ($isGigabyte -and $isG) { return }

    $message = "This laptop reports '$($system.Manufacturer) $($system.Model)' (board '$board'), not a Gigabyte G5/G6/G7."
    if ($Force) {
        Write-Warning "$message Continuing because -Force was given."
        return
    }
    throw "$message The fan commands are specific to that Clevo platform. Re-run with -Force to try anyway."
}

# ---------------------------------------------------------------- backends

function Register-ClevoWmiClass {
    $mofPath = Join-Path $env:TEMP 'G5FanControl.mof'
    Set-Content -LiteralPath $mofPath -Value $ClevoMof -Encoding ASCII
    $output = & (Join-Path $env:windir 'System32\wbem\mofcomp.exe') $mofPath 2>&1
    $exitCode = $LASTEXITCODE
    Remove-Item -LiteralPath $mofPath -ErrorAction SilentlyContinue
    if ($exitCode -ne 0 -or -not (Get-CimClass -Namespace $WmiNamespace -ClassName $WmiClassName -ErrorAction SilentlyContinue)) {
        throw "mofcomp could not register the WMI class: $($output -join ' ')"
    }
}

function Unregister-ClevoWmiClass {
    if (-not (Get-CimClass -Namespace $WmiNamespace -ClassName $WmiClassName -ErrorAction SilentlyContinue)) { return }
    $mofPath = Join-Path $env:TEMP 'G5FanControl-remove.mof'
    Set-Content -LiteralPath $mofPath -Value $ClevoMofRemove -Encoding ASCII
    & (Join-Path $env:windir 'System32\wbem\mofcomp.exe') $mofPath | Out-Null
    Remove-Item -LiteralPath $mofPath -ErrorAction SilentlyContinue
}

function Invoke-Wmbb([string]$Method, [uint32]$Argument = 0) {
    $result = Invoke-CimMethod -InputObject $script:WmiInstance -MethodName $Method -Arguments @{ Data = $Argument }
    return $result.Data1
}

function Initialize-WmiBackend {
    if (-not (Get-CimClass -Namespace $WmiNamespace -ClassName $WmiClassName -ErrorAction SilentlyContinue)) {
        Write-Host 'Registering the Clevo fan WMI class (one time only)...'
        Register-ClevoWmiClass
    }
    try {
        $instance = Get-CimInstance -Namespace $WmiNamespace -ClassName $WmiClassName | Select-Object -First 1
    }
    catch {
        throw "the firmware does not answer on the Clevo WMI interface ($(Get-ErrorText $_))."
    }
    if (-not $instance) { throw "the firmware does not expose the Clevo WMI interface ($ClevoWmiGuid)." }

    $script:WmiInstance = $instance
    $script:WmiHasRpm = $true
    $script:BackendName = 'WMI'
    try { $probe = Get-FanState }
    catch { $script:BackendName = $null; throw "fan info call failed ($(Get-ErrorText $_))." }
    if (-not (Test-ValidTemp $probe.CpuTemp)) {
        $script:BackendName = $null
        throw "the interface answered with an implausible CPU temperature ($($probe.CpuTemp))."
    }
}

function Initialize-EcBackend {
    if (-not (Test-Path -LiteralPath $PawnIOModule)) {
        throw "PawnIO module not found at '$PawnIOModule'. See README.md, 'EC fallback'."
    }
    if (-not ('G5FanControl.PawnEc' -as [type])) {
        Add-Type -TypeDefinition $PawnEcSource -Language CSharp
    }
    try {
        $script:Ec = [G5FanControl.PawnEc]::new([IO.File]::ReadAllBytes($PawnIOModule))
    }
    catch {
        throw (Get-ErrorText $_)
    }
    $script:BackendName = 'EC'
    try { $probe = Get-FanState }
    catch { $probe = $null }
    if (-not $probe -or -not (Test-ValidTemp $probe.CpuTemp)) {
        $script:BackendName = $null
        $script:Ec.Dispose()
        throw 'the EC did not return a plausible CPU temperature.'
    }
}

function Initialize-Backend {
    if ($script:BackendName) { return }
    $problems = @()
    if ($Backend -ne 'ec') {
        try { Initialize-WmiBackend; return }
        catch { $problems += "WMI: $(Get-ErrorText $_)" }
    }
    if ($Backend -ne 'wmi') {
        try { Initialize-EcBackend; return }
        catch { $problems += "EC (PawnIO): $(Get-ErrorText $_)" }
    }
    throw ("No working fan interface found.`n  " + ($problems -join "`n  ") + "`nSee README.md, 'Troubleshooting'.")
}

function Get-FanState {
    if ($script:BackendName -eq 'WMI') {
        $info1 = [uint32](Invoke-Wmbb 'Fan1Info')
        $info2 = [uint32](Invoke-Wmbb 'Fan2Info')
        $rpm1 = $null
        $rpm2 = $null
        if ($script:WmiHasRpm) {
            try {
                $tach = [uint32](Invoke-Wmbb 'GetFan12RPM')
                $rpm1 = ConvertFrom-TachWord ($tach -band 0xFFFF)
                $rpm2 = ConvertFrom-TachWord (($tach -shr 16) -band 0xFFFF)
            }
            catch { $script:WmiHasRpm = $false }
        }
        return [pscustomobject]@{
            CpuTemp  = [int](($info1 -shr 16) -band 0xFF)
            GpuTemp  = [int](($info2 -shr 16) -band 0xFF)
            Fan1Duty = ConvertTo-DutyPercent ($info1 -band 0xFF)
            Fan2Duty = ConvertTo-DutyPercent ($info2 -band 0xFF)
            Fan1Rpm  = $rpm1
            Fan2Rpm  = $rpm2
        }
    }
    $ec = $script:Ec
    return [pscustomobject]@{
        CpuTemp  = [int]$ec.Read($EcRegCpuTemp)
        GpuTemp  = [int]$ec.Read($EcRegGpuTemp)
        Fan1Duty = ConvertTo-DutyPercent $ec.Read($EcRegDuty1)
        Fan2Duty = ConvertTo-DutyPercent $ec.Read($EcRegDuty2)
        Fan1Rpm  = ConvertFrom-TachPeriod ((([int]$ec.Read($EcRegTach1)) -shl 8) -bor $ec.Read($EcRegTach1 + 1))
        Fan2Rpm  = ConvertFrom-TachPeriod ((([int]$ec.Read($EcRegTach2)) -shl 8) -bor $ec.Read($EcRegTach2 + 1))
    }
}

function Set-FanDuty([int]$Percent) {
    if ($script:BackendName -eq 'WMI') {
        Invoke-Wmbb 'SetFanDuty' (Get-WmbbDutyArgument $Percent) | Out-Null
        return
    }
    $raw = ConvertTo-RawDuty $Percent
    $script:Ec.SendMailbox($EcFanCommand, 1, $raw)
    $script:Ec.SendMailbox($EcFanCommand, 2, $raw)
}

function Set-FanAuto {
    if ($script:BackendName -eq 'WMI') {
        Invoke-Wmbb 'SetFanAutoDuty' 0xF | Out-Null
        return
    }
    $script:Ec.SendMailbox($EcFanCommand, 0xFF, 1)
    $script:Ec.SendMailbox($EcFanCommand, 0xFF, 2)
}

# ---------------------------------------------------------------- controller

# A controller that was killed (window closed, task stopped) leaves the mutex abandoned;
# the wait still hands over ownership, it just reports it with an exception.
function Wait-Mutex($Mutex, [int]$Milliseconds) {
    try { return $Mutex.WaitOne($Milliseconds) }
    catch {
        for ($e = $_.Exception; $e; $e = $e.InnerException) {
            if ($e -is [System.Threading.AbandonedMutexException]) { return $true }
        }
        throw
    }
}

# One controller at a time. A new command asks the running one to stop (it restores
# automatic mode on its way out) and takes over.
function Enter-ControllerLock {
    $script:StopEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::ManualReset, $StopEventName)
    $script:ControllerMutex = New-Object System.Threading.Mutex($false, $MutexName)
    $acquired = Wait-Mutex $script:ControllerMutex 0
    if (-not $acquired) {
        Write-FanLog 'Stopping the fan controller that is already running...'
        [void]$script:StopEvent.Set()
        $acquired = Wait-Mutex $script:ControllerMutex 15000
        if (-not $acquired) {
            $script:ControllerMutex.Dispose()
            $script:ControllerMutex = $null
            throw 'The running fan controller did not stop. Close its window and try again.'
        }
    }
    [void]$script:StopEvent.Reset()
}

function Exit-ControllerLock {
    if ($script:ControllerMutex) {
        try { $script:ControllerMutex.ReleaseMutex() } catch { }
        $script:ControllerMutex.Dispose()
        $script:ControllerMutex = $null
    }
}

function Test-ControllerRunning {
    $mutex = New-Object System.Threading.Mutex($false, $MutexName)
    try {
        $free = Wait-Mutex $mutex 0
        if ($free) { $mutex.ReleaseMutex() }
        return -not $free
    }
    finally { $mutex.Dispose() }
}

function Test-QuitKey {
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Q' -or $key.Key -eq 'Escape') { return $true }
        }
    }
    catch { }   # no interactive console, e.g. when started by the logon task
    return $false
}

# Waits one interval. $true means stop: another instance asked, or the user pressed Q/Esc.
function Wait-NextTick {
    $deadline = [DateTime]::UtcNow.AddSeconds($Interval)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($script:StopEvent.WaitOne(200)) { return $true }
        if (Test-QuitKey) { return $true }
    }
    return $false
}

# Hands the fans back to the firmware. If the firmware refuses, full speed is the safe fallback.
function Restore-FanAuto {
    try {
        Set-FanAuto
        return
    }
    catch { $reason = Get-ErrorText $_ }
    Write-FanLog "Returning the fans to automatic failed ($reason) - forcing 100% instead." 'Red'
    Set-FanDuty 100
}

function Set-FirmwareControl {
    Enter-ControllerLock
    try { Set-FanAuto }
    finally { Exit-ControllerLock }
    Write-FanLog 'Fans are back under automatic (firmware) control.' 'Green'
}

# Controller state. $Ctl.Mode / FixedPercent / CurvePoints / NoGuard may be changed between steps.
function New-FanController {
    param(
        [ValidateSet('set', 'quiet')]
        [string]$Mode,
        [int]$FixedPercent = 0,
        [object[]]$CurvePoints,
        [switch]$NoGuard
    )
    # With the guard on, make sure the way back to automatic works before slowing anything down.
    if (-not $NoGuard) {
        try { Set-FanAuto }
        catch { throw "Returning the fans to automatic does not work here ($(Get-ErrorText $_)), so the script will not take control. Use -NoGuard to control them anyway." }
    }
    $what = if ($Mode -eq 'set') { "fans at $FixedPercent%" } else { "quiet curve $Curve" }
    if ($NoGuard) {
        Write-FanLog "Started ($script:BackendName backend): $what. NO LIMITS: the firmware will not take over, whatever the temperature." 'Yellow'
    }
    else {
        Write-FanLog "Started ($script:BackendName backend): $what. Firmware takes over at $ReleaseTemp$DegC, control resumes at $ResumeTemp$DegC." 'Green'
    }
    if ($Mode -eq 'set' -and $FixedPercent -gt 0 -and $FixedPercent -lt 25) {
        Write-FanLog 'Below about 25% the fans may not spin at all, or may pulse. Watch the rpm readout.' 'Yellow'
    }
    return @{
        Mode           = $Mode
        FixedPercent   = $FixedPercent
        CurvePoints    = $CurvePoints
        NoGuard        = [bool]$NoGuard
        Released       = $false        # $true while the firmware has the fans
        Commanded      = -1            # duty we last asked for; -1 while the firmware is in charge
        Failures       = 0
        TargetSince    = Get-Date
        WarnedMismatch = $false
        State          = $null         # last fan reading
    }
}

# One control cycle: read, apply the guard, refresh the duty (the EC drops manual mode otherwise).
function Invoke-FanControllerStep($Ctl) {
    $state = $null
    try {
        $state = Get-FanState
        $Ctl.Failures = 0
    }
    catch {
        $Ctl.Failures++
        Write-FanLog "Reading the fans failed: $(Get-ErrorText $_)" 'Yellow'
    }
    $Ctl.State = $state
    $temp = Get-ControlTemp $state

    $handBack = $null
    if ($Ctl.NoGuard -and $Ctl.Mode -eq 'set') {
        if ($Ctl.Released) { $Ctl.Released = $false }   # no limits: hold the speed no matter what
    }
    elseif ($null -eq $temp) {
        # The quiet curve needs a temperature; so does the guard.
        if (-not $Ctl.Released) { $handBack = 'Temperature unreadable - fans handed back to the firmware.' }
    }
    elseif (-not $Ctl.NoGuard -and -not $Ctl.Released -and $temp -ge $ReleaseTemp) {
        $handBack = "$temp$DegC reached - fans handed back to the firmware until $ResumeTemp$DegC."
    }
    elseif ($Ctl.Released -and ($Ctl.NoGuard -or $temp -le $ResumeTemp)) {
        $Ctl.Released = $false
        Write-FanLog "$temp$DegC - taking fan control back." 'Green'
    }

    if ($handBack) {
        try {
            Restore-FanAuto
            $Ctl.Released = $true
            $Ctl.Commanded = -1
            Write-FanLog $handBack 'Yellow'
        }
        catch {
            $Ctl.Failures++
            Write-FanLog "Handing the fans back failed: $(Get-ErrorText $_)" 'Red'
        }
    }
    elseif (-not $Ctl.Released) {
        $target = $Ctl.FixedPercent
        if ($Ctl.Mode -eq 'quiet') {
            $target = Get-QuietDuty -Points $Ctl.CurvePoints -Temp $temp -Current $Ctl.Commanded -Hysteresis $Hysteresis
        }
        if ($target -ne $Ctl.Commanded) {
            $Ctl.TargetSince = Get-Date
            $Ctl.WarnedMismatch = $false
        }
        try {
            Set-FanDuty $target
            $Ctl.Commanded = $target
        }
        catch {
            $Ctl.Failures++
            Write-FanLog "Setting the fan speed failed: $(Get-ErrorText $_)" 'Yellow'
        }

        # The EC glides toward the target, so only judge after half a minute.
        if (-not $Ctl.WarnedMismatch -and $state -and ((Get-Date) - $Ctl.TargetSince).TotalSeconds -ge 30) {
            $actual = [math]::Max($state.Fan1Duty, $state.Fan2Duty)
            if ([math]::Abs($actual - $target) -gt 12) {
                Write-FanLog "The EC reports $actual% although $target% was requested. The firmware may enforce a minimum, or GIGABYTE Control Center is overriding the fans." 'Yellow'
                $Ctl.WarnedMismatch = $true
            }
        }
    }

    if ($Ctl.Failures -ge 5) { throw 'Lost contact with the fan controller five times in a row.' }
}

function Stop-FanController {
    try {
        Restore-FanAuto
        Write-FanLog 'Fans returned to automatic (firmware) control.' 'Green'
    }
    catch {
        Write-FanLog "Could not return the fans to automatic: $(Get-ErrorText $_). Reboot to reset the EC." 'Red'
    }
}

# Console controller: runs until Q/Esc/Ctrl+C or until another instance takes over.
function Start-FanController {
    param(
        [ValidateSet('set', 'quiet')]
        [string]$Mode,
        [int]$FixedPercent = 0,
        [object[]]$CurvePoints,
        [switch]$NoGuard
    )

    Enter-ControllerLock
    try { $ctl = New-FanController -Mode $Mode -FixedPercent $FixedPercent -CurvePoints $CurvePoints -NoGuard:$NoGuard }
    catch {
        Exit-ControllerLock
        throw
    }
    try {
        while ($true) {
            Invoke-FanControllerStep $ctl
            Write-StatusLine $ctl
            if (Wait-NextTick) {
                Write-FanLog 'Stopping.'
                break
            }
        }
    }
    finally {
        Stop-FanController
        Exit-ControllerLock
    }
}

# ---------------------------------------------------------------- commands

function Show-Status {
    $system = Get-CimInstance -ClassName Win32_ComputerSystem
    $state = Get-FanState
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host "Laptop      : $($system.Manufacturer) $($system.Model)"
    Write-Host "Backend     : $script:BackendName"
    Write-Host "CPU temp    : $(if (Test-ValidTemp $state.CpuTemp) { "$($state.CpuTemp)$DegC" } else { "-- (raw $($state.CpuTemp))" })"
    Write-Host "GPU temp    : $(if (Test-ValidTemp $state.GpuTemp) { "$($state.GpuTemp)$DegC" } else { '-- (dGPU asleep)' })"
    Write-Host "Fan 1 (CPU) : $($state.Fan1Duty)%$(if ($null -ne $state.Fan1Rpm) { "  $($state.Fan1Rpm) rpm" })"
    Write-Host "Fan 2 (GPU) : $($state.Fan2Duty)%$(if ($null -ne $state.Fan2Rpm) { "  $($state.Fan2Rpm) rpm" })"
    Write-Host "Controller  : $(if (Test-ControllerRunning) { 'running' } else { 'not running (firmware control)' })"
    Write-Host "Logon task  : $(if ($task) { "installed ($($task.State))" } else { 'not installed' })"
}

function Install-LogonTask([string]$What) {
    if (-not $What -or $What -eq 'quiet') {
        $modeArgs = 'quiet'
    }
    else {
        $modeArgs = "set $(ConvertTo-Percent $What)"
    }
    $arguments = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$PSCommandPath`"", $modeArgs,
        '-Curve', "`"$Curve`"", '-ReleaseTemp', $ReleaseTemp, '-ResumeTemp', $ResumeTemp,
        '-Hysteresis', $Hysteresis, '-Interval', $Interval, '-Backend', $Backend,
        '-PawnIOModule', "`"$PawnIOModule`""
    )
    if ($Force) { $arguments += '-Force' }
    if ($NoGuard) { $arguments += '-NoGuard' }

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute (Get-Process -Id $PID).Path -Argument ($arguments -join ' ')
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName $TaskName -Description 'Gigabyte G5 fan control (G5FanControl.ps1)' `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
    Write-FanLog "Logon task installed and started: $modeArgs$(if ($NoGuard) { ' (no limits)' }). Run 'remove-task' to undo." 'Green'
}

function Remove-LogonTask {
    # Stop the controller politely first; it puts the fans back to automatic on its way out.
    Enter-ControllerLock
    try { if ($script:BackendName) { Set-FanAuto } }
    finally { Exit-ControllerLock }
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-FanLog 'Logon task removed.' 'Green'
    }
    else {
        Write-FanLog 'No logon task was installed.'
    }
}

function Show-Menu {
    $curvePoints = ConvertFrom-CurveText $Curve
    while ($true) {
        Clear-Host
        Write-Host "Gigabyte G5 fan control  (backend: $script:BackendName)" -ForegroundColor Green
        try { $reading = Format-FanState (Get-FanState) }
        catch { $reading = "reading failed: $(Get-ErrorText $_)" }
        Write-Host "  $reading"
        Write-Host ''
        Write-Host '1. Fans OFF (0%)'
        Write-Host '2. Fans at 10%'
        Write-Host '3. Fans at a custom speed'
        Write-Host '4. Quiet curve (off while cool, gentle ramp when warm)'
        Write-Host '5. NO LIMITS: fixed speed, the firmware never takes over'
        Write-Host '6. Back to automatic (firmware)'
        Write-Host '7. Status'
        Write-Host '8. Run the quiet curve automatically at logon'
        Write-Host '9. Remove the logon task'
        Write-Host '0. Exit'
        Write-Host ''
        Write-Host "Options 1-4 hand the fans back to the firmware at $ReleaseTemp$DegC. Q stops any mode." -ForegroundColor DarkGray
        $choice = Read-Host 'Please make a selection'
        try {
            switch ($choice) {
                '1' { Start-FanController -Mode set -FixedPercent 0 -NoGuard:$NoGuard }
                '2' { Start-FanController -Mode set -FixedPercent 10 -NoGuard:$NoGuard }
                '3' { Start-FanController -Mode set -FixedPercent (ConvertTo-Percent (Read-Host 'Fan speed in % (0-100)')) -NoGuard:$NoGuard }
                '4' { Start-FanController -Mode quiet -CurvePoints $curvePoints -NoGuard:$NoGuard }
                '5' { Start-FanController -Mode set -FixedPercent (ConvertTo-Percent (Read-Host 'Fan speed in % (0-100), held whatever the temperature')) -NoGuard }
                '6' { Set-FirmwareControl }
                '7' { Show-Status }
                '8' { Install-LogonTask 'quiet' }
                '9' { Remove-LogonTask }
                '0' { return }
                default { Write-Host 'Invalid selection. Please try again.' -ForegroundColor Red }
            }
        }
        catch {
            Write-Host (Get-ErrorText $_) -ForegroundColor Red
        }
        Read-Host 'Press Enter to continue' | Out-Null
    }
}

function Invoke-Main {
    if ($Command -eq 'help') {
        Write-Host (Get-Help $PSCommandPath -Detailed | Out-String)
        return
    }
    if (-not (Test-IsAdmin)) {
        Restart-Elevated
        return
    }
    if ($ResumeTemp -ge $ReleaseTemp) { throw '-ResumeTemp must be lower than -ReleaseTemp.' }
    $curvePoints = ConvertFrom-CurveText $Curve
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null

    switch ($Command) {
        'status' {
            Initialize-Backend
            Show-Status
        }
        'set' {
            if (-not $Value) { throw "Usage: G5FanControl.ps1 set <0-100>" }
            $percent = ConvertTo-Percent $Value
            Assert-SupportedModel
            Initialize-Backend
            Start-FanController -Mode set -FixedPercent $percent -NoGuard:$NoGuard
        }
        'quiet' {
            Assert-SupportedModel
            Initialize-Backend
            Start-FanController -Mode quiet -CurvePoints $curvePoints -NoGuard:$NoGuard
        }
        'auto' {
            Initialize-Backend
            Set-FirmwareControl
        }
        'install-task' {
            Assert-SupportedModel
            Initialize-Backend
            Install-LogonTask $Value
        }
        'remove-task' {
            try { Initialize-Backend } catch { Write-Warning (Get-ErrorText $_) }
            Remove-LogonTask
        }
        'uninstall' {
            try { Initialize-Backend } catch { Write-Warning (Get-ErrorText $_) }
            Remove-LogonTask
            Unregister-ClevoWmiClass
            Remove-Item -LiteralPath $DataDir -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host 'Removed the logon task, the WMI class and the log folder.' -ForegroundColor Green
        }
        'menu' {
            Assert-SupportedModel
            Initialize-Backend
            Show-Menu
        }
    }
}

# Dot-sourcing (". .\G5FanControl.ps1") only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-Main
    }
    catch {
        Write-FanLog (Get-ErrorText $_) 'Red'
        # The elevated menu window would otherwise close before the error can be read.
        if ($Command -eq 'menu') { Read-Host 'Press Enter to close' | Out-Null }
    }
}
