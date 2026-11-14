# Garmin GTX 327 for X-Plane 12

A drop-in Garmin GTX 327 Mode A/C transponder for X-Plane 12 aircraft, built with
XLua 2 and Panel Graphics.

- **Behaviour.** It follows Garmin's Pilot's Guide (190-00187-00 Rev D) and
  Installation Manual (190-00187-02 Rev N):
  - code entry with CLR / CRSR, VFR and IDENT;
  - OFF / STBY / ON / ALT, with AUTO STANDBY and the landing delay;
  - pressure altitude with its trend arrow;
  - flight timer, count up and count down;
  - self test;
  - day / night display polarity;
  - photocell or lighting-bus backlight;
  - the installer's configuration mode (8 pages).
- **Settings.** Installation options are a plain text file with the manual's
  own option names. The configuration mode writes its changes into that file.
- **Screen.** The display is drawn by the plugin on a 200 x 33 dot LCD grid.
- **Use.** The unit works in the 3D cockpit and in a popup window, and drives
  X-Plane's transponder code and mode.

**Manual.** The full manual, for pilots and for aircraft authors, is
[GTX327_Manual.pdf](GTX327_Manual.pdf) in this repository. It covers flying
the unit, every setting, the configuration pages, commands, datarefs and a
first-flight tutorial. This README is the short version: what you need before
you install, and where to look when something goes wrong.

**Ready to use.** This package is meant to be dropped in as it is: you do not
need to edit its scripts or its art, because everything an aircraft needs is set
in `gtx327_config.ini`. The MIT license still lets you change anything. If
something does not work in your aircraft, or you need something it does not
offer, please open an [Issue](../../issues) on this repository.

## Requirements

- X-Plane 12.4.4 or later (Panel Graphics). On an older version the 3D clicks
  switch off, and `Log.txt` says `[GTX327] INSTALL 3D clicks off: X-Plane
  dataref ... not found`.
- XLua 2 in your aircraft, in `plugins/xlua/`. This package does not include
  it, because XLua is updated often. Get the latest XLua 2 release (2.0.0-r1 or
  later; earlier 2.0 betas are not supported) from the
  [XLua repository](https://github.com/X-Plane/XLua) and install it as its
  README describes. XLua 1.x does not work: this unit uses Panel Graphics.
  To see which one you have, start X-Plane with the aircraft and open
  **Plugins > Plugin Admin**: XLua 2 is listed as `XLua 2.0.0-r1` or later,
  XLua 1.x with a 1.x number.
- Windows, macOS or Linux. The package has no platform-specific code, but it
  has only been tested on Windows; macOS and Linux were checked by reading the
  code. If it does not work on yours, open an [Issue](../../issues) with your
  `Log.txt`.
  On macOS, a plugin downloaded from the web can be blocked by the quarantine
  flag: X-Plane then does not load XLua (it is missing from Plugin Admin, or
  macOS says the developer cannot be verified). Clear the flag in Terminal,
  `xattr -dr com.apple.quarantine "/path/to/your/aircraft/plugins/xlua"`, and
  restart X-Plane. If macOS still blocks it, allow it under **System Settings >
  Privacy & Security**.
- One transponder per aircraft. The GTX 327 owns X-Plane's transponder code
  and mode datarefs. If a second copy is installed, the `[GTX327] INSTALL` line
  in `Log.txt` mentions "a second GTX 327".

## Install

The manual's chapter "Installation and Settings (for Aircraft Authors)" has
every step in detail. In short:

1. Copy the folder `scripts/custom_device_GTX327/` from this repository into
   your aircraft's `plugins/xlua/scripts/`. Do not overwrite your other
   scripts. The unit finds its own files wherever it is installed.
2. In Plane Maker, open **Standard > Objects** and add **two** objects with the
   same position and rotation:
   - `../plugins/xlua/scripts/custom_device_GTX327/3D/GTX327.obj` (bezel, keys,
     key animations);
   - `../plugins/xlua/scripts/custom_device_GTX327/3D/GTX327_screen.obj` (the
     display).

   Add them as ordinary objects, not as your cockpit object. The model's origin
   is the screen centre and its face points aft (+Z). For both rows set
   **lighting** to Inside (a new row starts as Outside) and **shadow mode** to
   Interior Only, so the keys cast their own shadows. Set the position and
   pitch in Plane Maker. Save the aircraft and reload it in X-Plane.
3. Set up `gtx327_config.ini` for your installation, in a text editor or in
   the unit's configuration mode. It ships with Garmin's factory values,
   except AUTO STANDBY, which ships off. The setting most aircraft need
   is `[Power]`: the unit runs from `sim/cockpit2/electrical/bus_volts[power_bus]`
   (bus 0 by default) at 10 V or more, and with `power_source = avionics` it also
   needs `sim/cockpit2/switches/avionics_power_on` to be 1. If your avionics are
   on another bus, or your aircraft does not drive that switch, change them.
   `power_source = keys` lets only the STBY, ON and ALT keys start the unit.
4. Optional: to replace a stock transponder, set that object's hide dataref to
   `laminar/gtx327/installed`. It reads 1 while the GTX 327 runs and the stock
   object is hidden while it is not 0, so the stock unit comes back if the
   script ever fails to load.
5. Do not add GTX 327 commands to your `*_vrconfig.txt`.
6. Load the aircraft and switch on the battery and the avionics master. The unit
   runs its self test and powers up by itself in ON (Mode A: no altitude is
   reported; press ALT for that; STBY on the ground if you turned AUTO STANDBY
   on; on later starts, the mode it was last in), and `Log.txt` has a line
   starting `[GTX327] OK`, ending in `3D clicks on: ...`. Click the screen to open
   the popup. If something is wrong, see Troubleshooting. Leave the two
   `xpndr_GTX327_2d*.png` files where they are: the popup needs them.

### Updating

A new version ships its own `gtx327_config.ini`, so copying it over the old
folder loses your settings. On macOS, Finder's **Replace** swaps the whole old
folder for the new one, so `gtx327_pilot.ini` goes too. To keep your settings:
1. Copy `gtx327_config.ini` and, if it is there, `gtx327_pilot.ini` out of
   `plugins/xlua/scripts/custom_device_GTX327/`.
2. Delete that folder and copy in the new one (Install, step 1).
3. Put your two files back, replacing the new `gtx327_config.ini`.

A setting the new version added is not in your old file; the unit uses its
shipped value until you add the line. A setting it no longer knows gives one
`CONFIG` line in `Log.txt`; delete that line from the file.

### Model size

**The 3D model is not true to size.** It is about 8.6 % wider than the real
GTX 327, to line up with the Laminar C172 radio stack. If your panel needs a
different size, open an Issue rather than editing the model. The exact sizes
are in the manual, "Placing the unit and its size".

## Clicking the unit

The plugin picks `GTX327.obj` itself, so you never have to give up your own
cockpit object for it. A click on a key works like a button press (holding OFF
works), clicking the screen opens the popup, and the mouse wheel still zooms
the 3D view. Clicks work in the 3D cockpit view only, not from external
views. **Clicking the 3D unit in VR is not supported in this version.** The
limits, and the `[Clicks]` settings that change them, are
in the manual: "Clicking the unit in the 3D cockpit" and "Clicks in the 3D
cockpit".

**Not for full-screen or sim-hardware use.** The popup and the screen are not
meant to be shown full screen or sent to another monitor or a home-cockpit
display. That use turns the unit into a sim-hardware device, and its
compatibility there cannot be guaranteed.

## Configuration

Every option is explained in `gtx327_config.ini` itself, and in the manual
("The settings file" and the sections after it). Invalid values and unknown
keys are reported in X-Plane's `Log.txt`, and the factory value is used
instead. The unit's own configuration pages (with the unit off and the
aircraft's power on, hold FUNC and press STBY, ON or ALT; with a mouse, click
FUNC and then one of them within 3 seconds) are described in the manual's
chapter "Configuration Mode (for Aircraft Authors)". To suggest a different
factory value, open an [Issue](../../issues).

Aircraft authors: the unit keeps its own memory in a file `gtx327_pilot.ini`
next to the ini: the pilot's DISPLAY and CONTRAST levels, the last code, the
last mode and the ACCUMULATE flight time. The file appears once a level differs
from the ini, or a code, a mode other than ON or a flight time has been
remembered. **Do not ship a `gtx327_pilot.ini` with your aircraft**; check that the
folder has none before you package it.

## Commands, datarefs and callbacks

The GTX 327 takes over X-Plane's own `sim/transponder/*` commands, so existing
transponder bindings drive it. The keys X-Plane has no command for are
`laminar/gtx327_8`, `laminar/gtx327_9`, `laminar/gtx327_func`,
`laminar/gtx327_startstop` and `laminar/gtx327_clr`; the popup is
`laminar/gtx327/popup_toggle`. OFF must be held for 1 s, so bind it to a button
that stays down while pressed. X-Plane's 12 commands that step the code up or
down digit by digit (`sim/transponder/transponder_thousands_up` and so on) are
kept from X-Plane while the unit is installed, because the real unit sets a
code only with its 0-7 keys. The full command table, the datarefs and the
callback numbers are in the manual: "Commands", "Datarefs" and "Callback
budget".

XLua 2.0.0-r1 and later do not limit the callbacks a script can register.
Earlier XLua 2 betas are not supported (see Requirements): they stop at about
500 callbacks per aircraft, shared by every XLua script in it, and count every
popup open again. On those the unit loads if there is room for its core (30
callbacks). When XLua later refuses the popup, the 3D clicks or the optional
extras, only that part is lost: the 3D unit keeps working, and `Log.txt` has
one `[GTX327] INSTALL` line. If there is no room for the core, the unit does
not start, and a stock transponder hidden by `laminar/gtx327/installed` comes
back. Updating XLua fixes both.

## Lighting

The screen backlight and the key lights follow the unit's settings, X-Plane's
ambient light and the instrument dimmer (`[Backlight] lighting_dimmer` chooses
which of X-Plane's dimmers, 0 = the pilot's). How each one
works is in the manual's chapter "Brightness, Contrast and Night" and in
"Lighting inputs".

## FAQ

**I select ALT (or ON) on the ground and the unit still shows STBY.** You have
AUTO STANDBY turned on. It ships **off**: with it off, the unit stays in
whatever mode you select, on the ground as well. On the real unit Garmin's
factory setting is on. To get that behaviour, set `[Airborne] auto_standby = on`
in `gtx327_config.ini`, or turn it on in configuration mode. The manual
explains both choices: "Automatic STBY and ALT (AUTO STANDBY)" and "Appendix
B: A Debate Between AUTO STANDBY ON and OFF".

## Troubleshooting (for you or your AI agent)

The unit writes only a few lines to X-Plane's `Log.txt`, all starting with
`[GTX327]`. The word after the tag says where the problem is and who fixes it.
The manual's "Troubleshooting and Log.txt" has the same table.

| Line starts with | Meaning | What to do |
|---|---|---|
| `[GTX327] OK` | Loaded and running. Shows the version, the folder it runs from, the XLua callbacks it uses and whether 3D clicks are on (and why not). | Nothing. If 3D clicks show `off`, the reason is in brackets. |
| `[GTX327] CONFIG` | A line in your `gtx327_config.ini` is not valid (the factory value is used), or the file could not be written. | Local: fix the named line, or make the file writable. |
| `[GTX327] INSTALL` | The aircraft's setup: a missing package file, an X-Plane that is too old, a second GTX 327 in the aircraft, or XLua or X-Plane refusing one of the unit's registrations. | Local: follow the fix in the line. |
| (in the `OK` line) | If `GTX327.obj` was not added in Plane Maker, the `OK` line says `3D clicks off: gtx327.obj is not attached to the aircraft ...`. If only `GTX327_screen.obj` is missing, nothing is logged and the screen is just invisible. | Local: add the objects (Install, step 2). |
| `[GTX327] NOTE` | An expected state, not a fault. Examples: X-Plane's transponder failure is active; `master_reset` restored the factory values; `avionics master on, bus N at X V: the unit stays off until that bus has 10 V` (check `power_bus`); `3D clicks follow the drawn view (N mm from the pilot's head: ...)` (the G-loaded camera or head tracking moved the view, and the clicks follow it). | Nothing, or clear it in X-Plane. |
| `[GTX327] BUG` | A fault in the unit itself. The line reads `BUG <part> failed (...)` (some say `stopped` or `could not start`), with a note to report it. | [Open an Issue](../../issues) with all `[GTX327]` lines and your X-Plane version. |

No `[GTX327] OK` line at all means the script did not load. Check that the
aircraft has XLua 2 (see Requirements), and look for XLua errors in `Log.txt`.

An `OK` line but a dark unit: the unit is not getting power. It needs
`sim/cockpit2/electrical/bus_volts[power_bus]` of 10 V or more and, with
`power_source = avionics`, `sim/cockpit2/switches/avionics_power_on` = 1. Some
aircraft never set that switch, and then nothing is logged. Watch both in
DataRefTool, then set `[Power] power_source = bus` or the right `power_bus`.

## Repository layout

```
scripts/custom_device_GTX327/   the drop-in folder (install this)
GTX327_Manual.pdf               the manual
```

## Credits

- **3D model and textures:** Massimo Durando.
- **LCD fonts:** [Avionic Fontbook](https://github.com/erix174/Avionic-Fontbook) by erix174.
- **Plugin-side picking:** shared with the G5 and GI 275 packages.
- **Behaviour:** per Garmin's GTX 327 Pilot's Guide 190-00187-00 Rev D and
  Installation Manual 190-00187-02 Rev N. The manuals are not included.

Garmin and GTX are trademarks of Garmin Ltd. or its subsidiaries. This project
is not affiliated with or endorsed by Garmin.

## License

MIT; see [LICENSE](LICENSE). The 3D model and textures are by Massimo Durando
and are released under the same MIT license.
