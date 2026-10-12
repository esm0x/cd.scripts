# Gigabyte G5 KF / KF5 fan control (Windows)

The G5 KF firmware never lets the fans drop below roughly 28-30%, even at idle. GIGABYTE Control Center only switches between preset modes. This tool takes over the fans directly, so you can run them at 10% or switch them off completely, for example while falling asleep to music. It comes as a window (GUI) and as a console script; both use the same engine.

By default a thermal guard runs the whole time:

* at **80 °C** (CPU or GPU) the fans go back to the firmware, which spins them up as usual,
* at **65 °C** the tool takes control again,
* when you stop it, or temperatures cannot be read, the fans go back to automatic.

Switch the guard off for **no-limits mode**: the speed you set is held whatever the temperature, and the firmware does not take over while the tool runs.

Made for the GIGABYTE G5 KF / KF5 (i7-13620H, RTX 4060), which is a Clevo NP50RND chassis. It should also work on other Clevo-based G5/G6/G7 models (G5 MF5, G6 KF). Other laptops are refused unless you pass `-Force`.

## Quick start (window)

1. Copy this folder somewhere permanent, e.g. `C:\Tools\G5FanControl`.
2. Double-click **`G5FanControlGui.cmd`** and accept the administrator prompt.
3. Check the readout at the top. Temperatures should look sane (CPU around 35-60 °C at idle).
4. Click **Fans OFF** or **10%**, or pick any speed with the slider and click **Apply slider speed**. While a fixed speed is running, moving the slider changes it live.
5. For no-limits mode, untick **Thermal guard**. The mode line turns red and shows `NO LIMITS`. You can tick and untick it while a mode is running.

The window drives the fans while it is open. Minimise it, don't close it. **Automatic (firmware)**, or closing the window, gives the fans back to the firmware.

| Control | What it does |
|---|---|
| Fans OFF / 10% / slider | Hold a fixed speed |
| Start quiet curve | Off while cool, gentle ramp when warm (curve editable in the box) |
| Thermal guard | Hand-back and resume temperatures. Untick for no limits |
| Automatic (firmware) | Stop controlling; also stops a console or logon-task controller |
| Run this mode at logon | Runs the current mode hidden at every logon (no window needed) |
| Remove logon task | Undo the above |

The event log at the bottom shows what happened (handed back, resumed, errors).

## Console

`G5FanControl.cmd` opens a text menu. The same things work as commands from a terminal in this folder. `G5FanControl.cmd` works without changing the execution policy; `.\G5FanControl.ps1` works too if your policy allows scripts. Stop a running mode with **Q**, **Esc** or **Ctrl+C**.

| Command | What it does |
|---|---|
| `G5FanControl.cmd` | Interactive menu |
| `G5FanControl.cmd status` | Temperatures, fan duty and rpm, and which interface is used |
| `G5FanControl.cmd set 0` | Fans off, with the thermal guard, until you press Q |
| `G5FanControl.cmd set 10 -NoGuard` | Fans at 10%, no limits: held whatever the temperature |
| `G5FanControl.cmd quiet` | Temperature curve: off while cool, gentle ramp when warm |
| `G5FanControl.cmd auto` | Back to firmware control. Also stops a controller running in another window or the logon task |
| `G5FanControl.cmd install-task quiet` | Run quiet mode hidden at every logon (`install-task 0 -NoGuard` keeps the fans off with no limits) |
| `G5FanControl.cmd remove-task` | Remove the logon task and return the fans to automatic |
| `G5FanControl.cmd uninstall` | Remove the logon task, the WMI class and the log folder |

Options (add to any command):

| Option | Default | Meaning |
|---|---|---|
| `-NoGuard` |  | No-limits mode: never hand the fans back to the firmware |
| `-ReleaseTemp` | `80` | Hand the fans back to the firmware at this temperature (°C) |
| `-ResumeTemp` | `65` | Take control back once cooled to this temperature (°C) |
| `-Curve` | `"60:0,61:20,70:30,76:45"` | Quiet curve as `temperature:percent` pairs, linear in between |
| `-Hysteresis` | `4` | Quiet mode slows the fans only after cooling this many degrees, so they don't flutter |
| `-Interval` | `2` | Seconds between updates. The EC drops manual mode if it is not refreshed |
| `-Backend` | `auto` | `wmi` or `ec` to force one interface |
| `-Force` |  | Skip the model check (works for `G5FanControlGui.cmd` too) |

## No-limits mode

With the guard off, a fixed speed is held through any temperature, unreadable sensors and short read errors. The tool still stops, and returns the fans to automatic, when you stop it, or when it loses contact with the fan controller five times in a row.

What still protects the hardware is outside this tool's reach. The CPU throttles at about 100 °C and the RTX 4060 at about 87 °C, and both shut the laptop down if that is not enough. The EC firmware may have its own emergency limit that these commands cannot switch off. With the fans off, expect more throttling under load, not less.

The quiet curve with the guard off keeps following the curve above 80 °C (it stays at the last point). It still hands back if the temperature cannot be read, because the curve needs one.

## Things to know

* **Below about 25% a fan may not spin at all, or may start and stop.** Linux drivers for this platform treat anything under ~12% as off and raise 12-25% to 25% for that reason. If 10% pulses or whines, use 0 or 25. The rpm readout shows what the fan really does.
* **Only one controller runs at a time.** Starting a mode in the window, in a console, or the logon task stops the one already running, and that one returns the fans to automatic first.
* **Killing the tool skips the cleanup:** ending the process, or closing a console window with X. Run `G5FanControl.cmd auto`, or reboot: the EC resets to automatic at every boot. Closing the GUI window normally does clean up.
* **GIGABYTE Control Center can fight the tool** if it is applying its own fan mode. Leave it on its normal/balanced mode. If the EC keeps reporting a different speed than requested for 30 seconds, a warning appears in the log.
* With the guard on, the tool refuses to start if the "back to automatic" command fails on this firmware. If handing back fails mid-run, it forces 100% instead.
* The logon task points to the script's current location. Don't move the folder after installing it, or install the task again.
* Events (started, handed back, resumed, errors) are logged to `C:\ProgramData\G5FanControl\G5FanControl.log`.

## How it works

The G5 KF is a Clevo design, and its firmware speaks Clevo's fan command set, the same one TUXEDO's Linux drivers use:

| Command | Meaning |
|---|---|
| `0x63` / `0x64` | Fan 1 / fan 2 info: duty in bits 0-7 (0-255), temperature in bits 16-23 |
| `0x68` | Set duty: one byte per fan, `percent × 255 / 100` |
| `0x69` | Return fans to automatic: bitmask `0xF` = all fans |
| `0x70` | Fan 1 and 2 tachometer periods (rpm ≈ 2156220 / period) |

The script reaches them through one of two backends. It picks the first that works:

1. **WMI (default, nothing to install).** The BIOS exposes these commands as the Clevo ACPI-WMI method `WMBB` (GUID `ABBC0F6D-8EA1-11D1-00A0-C90629100000`). Windows only lets you call a WMI method once a class describes it. On first run the script therefore registers a small class, `G5FanControl_ClevoWmbb` in `root\wmi`, with the built-in `mofcomp.exe`. `uninstall` removes it again.
2. **EC mailbox (fallback).** If the WMI route is unavailable, the script can write the embedded controller's command mailbox directly: parameters to `0xF9`/`0xFA`, then the doorbell `0xC1` to `0xF8`. It reads temperatures from `0x07`/`0x0A`, duty from `0xCE`/`0xCF` and tachometers from `0xD0`-`0xD3`. Port access goes through the signed [PawnIO](https://pawnio.eu) driver; see below.

### Setting up the EC fallback

Only needed if `status` says the WMI interface is not available.

1. Install PawnIO from <https://pawnio.eu>. It is a signed driver that LibreHardwareMonitor and FanControl also use.
2. Download `release_0_2_11.zip` (or newer) from <https://github.com/namazso/PawnIO.Modules/releases> and copy `LpcACPIEC.bin` from it into this folder.
3. Run `G5FanControl.cmd status -Backend ec`.

Direct EC access can collide with Windows' own EC driver. This is rare and it serialises with other monitoring tools through the shared `Global\Access_EC` mutex, but the WMI route has no such risk, so prefer it.

## Troubleshooting

* **"No working fan interface found"**: the message lists why each backend failed. If WMI reports that the firmware does not expose the interface, set up the EC fallback.
* **Speeds don't change**: check that GIGABYTE Control Center is not in a custom fan mode, then compare `status` before and after `set`. The EC glides towards a new duty over a few seconds; it does not jump.
* **Fan 1 / Fan 2 look swapped**: one G5 KF owner reported the two fans the other way round. The script always drives both fans together, so this only affects the labels.

## Status and credits

The command set and registers come from Linux projects verified on this hardware:

* [Rodsantos1337/fans-g5-kf](https://github.com/Rodsantos1337/fans-g5-kf) (G5 KF, i7-13620H + RTX 4060: commands `0x63`, `0x68`, `0x69`, duty packing, refresh interval)
* [smairio/gigactl](https://github.com/smairio/gigactl) (EC mailbox protocol, verified on the G6 KF and reported working on the G5 KF)
* [TUXEDO drivers](https://gitlab.com/tuxedocomputers/development/packages/tuxedo-drivers) (Clevo WMI GUID and command ids)

The Windows side follows Microsoft's WMI-ACPI class mapping, and [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) for the PawnIO calls. The control logic and the window's logic were unit-tested against a simulated EC, but nothing here has been run on a real G5 KF yet, and the window itself has not been displayed (WinForms needs Windows). On the first run, open the window, click **Fans OFF**, and watch temperatures and rpm for a few minutes before leaving it alone overnight.
