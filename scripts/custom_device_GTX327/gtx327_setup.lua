-- Garmin GTX 327 installation configuration (Installation Manual
-- 190-00187-02 Rev N, section 5.2): gtx327_config.ini read and write-back,
-- master_reset, and the unit's own configuration mode (FUNC held while a
-- power key turns the unit on).
--
-- Loaded by custom_device_GTX327.lua with loadfile + setfenv. init() hands
-- over the log function, the ini's path and the main script's s_config, which
-- this module fills: load() at start, configuration mode when a field is saved.
--
-- Two states only: the factory text below and the user's file. Whatever the
-- configuration mode saves replaces just the value of that key's line, so
-- the comments and the rest of the file stay as written.

local M = {}

local CONFIG_FILE = "gtx327_config.ini"

-- The shipped gtx327_config.ini, byte for byte once its line ends are CRLF.
M.FACTORY_INI = [==[
# ============================================================================
# MASTER RESET
# master_reset = 1 puts EVERY setting in this file back to Garmin's factory
# values the next time the aircraft loads: the unit saves this file as
# gtx327_config.ini.bak, writes a fresh factory copy here (with master_reset
# back at 0) and notes it in X-Plane's Log.txt.
# ============================================================================
master_reset = 0

# Garmin GTX 327 - installation configuration
#
# These settings are the unit's configuration pages (GTX 327 Installation
# Manual 190-00187-02 Rev N, section 5.2) plus a few X-Plane options. They are
# read when the aircraft loads. Format: key = value. Lines starting with # are
# comments; section headers are only for reading. Numbers are whole numbers
# unless the comment says decimals; on / off keys also take yes / no and 1 / 0.
# A value that is not valid is reported in X-Plane's Log.txt and ignored: the
# factory value stays, or, for a key written more than once, the last valid
# value above it (the last valid line of a key is the one in force).
#
# Configuration mode, as on the real unit: with the unit off, hold FUNC and
# press STBY, ON or ALT. With the mouse: click FUNC, then STBY, ON or ALT
# within 3 seconds. The pages appear after the self test.
#   FUNC / START-STOP  next / previous page; a change not yet saved with CRSR
#                      is dropped (so is one still open when you leave)
#   CRSR               select the first setting; press again to save it and
#                      go to the next one
#   0-9                type a number        8 / 9  step through the choices
#   CLR                cancel the change    OFF    (hold) leave
# A setting saved there is written into this file at once; the comments and
# everything else in the file stay as they are.
#
# The levels the pilot sets on the DISPLAY and CONTRAST pages are kept in
# gtx327_pilot.ini next to this file and replace backlight_level,
# key_light_level or contrast_level below at the next load (Log.txt says so).
# Delete that file to go back to the levels here; master_reset deletes it too.
# The same file keeps the unit's last active code, which it powers on with,
# the mode it was last in, which the bus (power_source) powers it on in (ON
# the first time), and the ACCUMULATE flight time.
#
# This file ships with Garmin's factory values. Aircraft authors and pilots use
# the same file and the same rules: change what your installation needs, by
# hand or in configuration mode. A key you delete falls back to its factory
# value. To suggest a different factory value, open an Issue on GitHub.

[Power]
# The unit runs from electrical bus power_bus (0-5, sim/cockpit2/electrical/
# bus_volts) at 10 V or more and draws its current from that bus (IM 1.5.3:
# 0.50 A at 27.5 V, 0.90 A at 13.75 V). power_source:
#   avionics = also needs the avionics master switch
#              (sim/cockpit2/switches/avionics_power_on)
#   bus      = on whenever the bus has power
#   keys     = only the STBY / ON / ALT keys turn it on, the bus live (the
#              avionics master turn-on input, IM pin 1, not wired); off
#              when the bus goes, and it stays off when the bus is back
power_source = avionics
power_bus = 0

# Development only. on = ignore aircraft power, open the popup on load and enable
# the laminar/gtx327/debug_airborne_* commands. Keep it off in a release.
debug_mode = off

[Popup]
# off = pure bezel with no window frame, like X-Plane's stock Garmin popups.
# on  = X-Plane window frame with a title bar and pop-out button.
popup_frame = off

[Display]
# DISPLAY MODE page (5.2.1).
# auto     = positive by day, negative at night, from the photocell (factory)
# positive = always dark characters on a light background
# negative = always light characters on a dark background
display_mode = auto

# LEVEL: ambient light (0-99) below which AUTO switches to negative. Higher
# means it switches earlier in the evening. Factory 75.
# The real unit has one photocell for this switch, the backlight and the key
# lighting. X-Plane has no one value that does all three jobs, so the plugin
# reads three: the time of day (sim/graphics/scenery/percent_lights_on; 75
# switches at about sunset) here, the brightness X-Plane gives its own avionics
# for the backlight, and the camera's exposure
# (sim/graphics/misc/photo_auto_atten) for the key lighting. So under an
# overcast the keys and the 3D screen dim a little while the display stays
# positive.
display_change_level = 75

[Contrast]
# CONTRAST CONFIGURATION page (5.2.4).
# manual = the pilot adjusts it on the CONTRAST page with 8 / 9
# auto   = no CONTRAST page (factory)
contrast = auto
# Contrast in percent, 0-100. Factory 50. The configuration page shows it as
# 1-63 in MAN and 0-99 in AUTO. In MAN it is the contrast; in AUTO it is the
# offset to the automatically compensated contrast (50 = none). X-Plane has no
# display temperature to compensate for, so AUTO stays at the look of 50 and
# the offset moves it lighter or darker.
contrast_level = 50

[Backlight]
# DISPLAY BACKLIGHT page (5.2.2), for the screen. The mode is also the key
# lighting's mode ([Key lighting] below).
# manual = the pilot sets it on the DISPLAY page with 8 / 9; nothing else dims it
# auto   = no DISPLAY page; follows backlight_source (factory)
backlight = auto

# Manual-mode level in percent, 0-100 (LVL 000-999 on the configuration page).
# It drives the backlight only: at 0 the screen still reads by daylight, as an
# LCD does, and is dark at night.
backlight_level = 100

# AUTO source (BKLT SRCE):
#   photo        = the unit's photocell (factory)
#   14v, 28v, 5v = the aircraft's lighting bus: the instrument dimmer named
#                  by lighting_dimmer below (X-Plane gives a ratio, not a
#                  voltage, so the three behave the same). With the dimmer
#                  at its minimum, the photocell takes over.
#                  (bus, from earlier versions of this file, reads as 14v.)
backlight_source = photo

# The lighting bus, for the backlight and the key lighting alike (the unit has
# one lighting bus input, IM 4.1.2): which X-Plane instrument dimmer,
# sim/cockpit2/switches/instrument_brightness_ratio[0-31]. 0 = the pilot's
# (factory), 1 = the copilot's, 2-15 = the aircraft's own.
lighting_dimmer = 0

# AUTO tuning, 0-99 each (factory 8 / 50 / 50). MIN is the floor, SLOPE the
# sensitivity, OFFSET shifts the whole curve. On the photocell, the 3D screen
# takes them relative to the factory values: as shipped it shows X-Plane's
# own ambient level (dim at night, like X-Plane's other avionics); a higher
# MIN or OFFSET makes it brighter in proportion.
backlight_min = 8
backlight_slope = 50
backlight_offset = 50
# RSP TIME, 3-7: how slowly the level follows a change. Factory 4.
backlight_response = 4

# Not a Garmin option. X-Plane's camera opens up under clouds, so a self-lit
# 3D screen glares by day under an overcast or in rain. 1 = in AUTO, the 3D
# screen's photocell reading is lowered by the cloud layers above the aircraft
# and the rain (down to a fifth under thick storm cloud); 0 = off; decimals in
# between. MAN levels, the lighting bus and the popup are not affected.
backlight_cloud_dim = 1

[Key lighting]
# KEY LIGHTING page (5.2.3): the key legends glow warm white, plain at dusk
# and at night, not seen in sunshine, dark with the unit. They run in the
# backlight mode above (manual or auto) with settings of their own, the same
# kinds as the backlight's. Factory values are the backlight's.
# Manual-mode level in percent, 0-100 (LVL 000-999). The pilot's DISPLAY page
# moves it by as much as it moves backlight_level.
key_light_level = 100
# AUTO source (KEY SRCE): photo (factory), 14v, 28v or 5v, as backlight_source.
key_light_source = photo
# AUTO tuning: MIN, SLOPE, OFFSET 0-99 each (factory 8 / 50 / 50); RSP TIME
# 3-7 (factory 4).
key_light_min = 8
key_light_slope = 50
key_light_offset = 50
key_light_response = 4

[VFR]
# VFR KEY CONFIGURATION page (5.2.5). on (factory) or off; when off, pressing
# VFR shows "VFR Key Disabled" for 5 seconds.
vfr_key = on
# VFR ID (5.2.7.1): the code the VFR key selects, digits 0-7. Factory 1200;
# many European countries use 7000.
vfr_code = 1200

[Operation]
# First configuration page (5.2.7.1).
# VS RATE: climb / descent rate in ft/min that shows the trend arrow on the
# PRESSURE ALT page, 0-9999. Factory 500. Garmin gives only this one rate; in
# this simulation twice it shows the large arrow and 0 shows no arrows. An
# arrow goes again only below 80 % of the rate that brought it.
vs_rate = 500

# FLT TMR:
#   manual     = START/STOP and CLR only
#   clear      = starts from zero at every lift-off, pauses on the ground (factory)
#   accumulate = starts at lift-off and keeps adding, pauses on the ground;
#                kept through power off and reloads until CLR
flight_timer = clear

# FORMAT of the PRESSURE ALT page: feet, flight_level (factory) or meters.
altitude_format = flight_level

[Airborne]
# Second configuration page (5.2.7.2) and AIRCRAFT TYPE page (5.2.8).
# AUTO STANDBY: off (default) = the pilot selects every mode. on (Garmin's
# factory setting) = STBY on the ground whatever key is pressed and ALT once
# airborne.
auto_standby = off

# Delay Time: seconds on the ground before AUTO STBY returns to STBY after a
# landing, 0-99. Factory 24. The aircraft type below adds its air-state time.
delay_time = 24

# rotor (adds 1 s), under_15500_lb, 15500_lb_or_more or unknown (all add 4.5 s).
# Factory under_15500_lb.
aircraft_type = under_15500_lb

[Clicks]
# Not Garmin options. Mouse clicks on the 3D unit (3D/GTX327.obj).
# X-Plane only clicks manipulators in the aircraft's own cockpit object, so the
# plugin picks the keys itself:
#   auto   = pick, unless the aircraft's cockpit object already has GTX click
#            regions (any laminar/gtx327 command); then X-Plane clicks them
#   plugin = always pick
#   off    = no 3D clicks (popup and joystick bindings still work)
clicks = auto
# on = log the click windows, a self-test and every hit to Log.txt.
click_debug = off
# Clicks that land inside the unit's click window but miss every key:
# off = swallowed (nothing behind the unit fires), on = passed to X-Plane.
click_pass_misses = off

[Extras]
# Not Garmin options.
# Count Down time shown before the pilot enters one, in seconds (0 = 00:00:00,
# as the manual describes; 3600 = 01:00:00).
countdown_preset = 0

# on = a MANUAL flight timer starts by itself when the self test ends, as seen
# in footage of one real unit. off = strictly pilot-controlled.
flight_timer_power_on_start = off

# START/STOP and CLR are the unit's own commands (laminar/gtx327_startstop,
# laminar/gtx327_clr). on = also take over X-Plane's clock commands
# sim/instruments/timer_start_stop and timer_reset; leave it off when the
# aircraft has its own clock.
sim_timer_commands = off

[Budget]
# Not Garmin options. XLua 2.0.0-r1 and later do not limit the callbacks a
# script registers; the numbers here are for reference. The unit's core uses 30
# (the installed and key_light datarefs, the 20 key commands and popup_toggle,
# the screen device, the flight loop, the 3D click window); the popup adds 5
# each time it opens (closing it removes it). The extras below are optional;
# the unit works without them.
#   alias_commands      = on: laminar/gtx327_popup and the laminar/gtx327_<key>
#                         compatibility aliases for older panels and bindings (16).
#   diagnostic_datarefs = on: the laminar/gtx327/* state datarefs that
#                         DataRefTool can show (55).
# debug_mode = on also registers the 3 debug_airborne commands.
alias_commands = off
diagnostic_datarefs = off
]==]

local s_host = nil        -- { log = function, path = ini path }
local s_config = nil      -- the main script's s_config
local s_current = {}      -- key -> value text in force (normalised)
local s_write_failed = false

-- Same numbers as the constants in custom_device_GTX327.lua.
local BACKLIGHT_SOURCE = { photo = 0, ["14v"] = 1, ["28v"] = 1, ["5v"] = 1 }
-- Installation manual 5.2.7.2: air-state allowance 1 s rotorcraft, 4.5 s
-- fixed-wing (every other AIRCRAFT TYPE).
local AIR_STATE_DELAY = { rotor = 1.0, under_15500_lb = 4.5, ["15500_lb_or_more"] = 4.5, unknown = 4.5 }
local TIMER_MAX_SEC = 99 * 3600 + 59 * 60 + 59

local FLAGS = { on = true, yes = true, ["1"] = true, off = false, no = false, ["0"] = false }
-- key = { s_config field, kind, choices or min, max }
local SPEC = {
    master_reset = { nil, "flag" },
    debug_mode = { "debug_mode", "flag" },
    power_source = { "power_source", "choice", { avionics = 0, bus = 1, keys = 2 } },
    power_bus = { "power_bus", "number", 0, 5 },
    popup_frame = { "popup_frame", "flag" },
    display_mode = { "display_mode", "choice", { auto = 0, positive = 1, negative = 2 } },
    display_change_level = { "photo_sensor_threshold", "percent", 0, 99 },
    contrast = { "manual_contrast_page", "choice", { auto = false, manual = true } },
    contrast_level = { "contrast_level", "percent", 0, 100 },
    backlight = { "manual_display_page", "choice", { auto = false, manual = true } },
    -- a name; backlight_source itself is derived (see derive)
    backlight_source = { "backlight_source_name", "choice",
        { photo = "photo", ["14v"] = "14v", ["28v"] = "28v", ["5v"] = "5v", bus = "14v" } },
    backlight_level = { "display_level", "percent", 0, 100 },
    backlight_min = { "backlight_min", "number", 0, 99 },
    backlight_slope = { "backlight_slope", "number", 0, 99 },
    backlight_offset = { "backlight_offset", "number", 0, 99 },
    backlight_response = { "backlight_response", "number", 3, 7 },
    backlight_cloud_dim = { "backlight_cloud_dim", "decimal", 0, 1 },
    lighting_dimmer = { "lighting_dimmer", "number", 0, 31 },
    key_light_level = { "key_light_level", "percent", 0, 100 },
    -- a name; key_light_source is derived
    key_light_source = { "key_light_source_name", "choice",
        { photo = "photo", ["14v"] = "14v", ["28v"] = "28v", ["5v"] = "5v", bus = "14v" } },
    key_light_min = { "key_light_min", "number", 0, 99 },
    key_light_slope = { "key_light_slope", "number", 0, 99 },
    key_light_offset = { "key_light_offset", "number", 0, 99 },
    key_light_response = { "key_light_response", "number", 3, 7 },
    vfr_key = { "vfr_key_enabled", "flag" },
    vfr_code = { "vfr_code", "squawk" },
    vs_rate = { "altitude_trend_fpm", "number", 0, 9999 },
    flight_timer = { "flight_timer_mode", "choice", { manual = 0, clear = 1, accumulate = 2 } },
    altitude_format = { "altitude_format", "choice", { feet = 0, flight_level = 1, meters = 2 } },
    auto_standby = { "auto_standby_enabled", "flag" },
    delay_time = { "ground_delay_seconds", "number", 0, 99 },
    -- a name; air_state_delay is derived
    aircraft_type = { "aircraft_type", "choice",
        { rotor = "rotor", under_15500_lb = "under_15500_lb", ["15500_lb_or_more"] = "15500_lb_or_more",
          unknown = "unknown" } },
    countdown_preset = { "countdown_default_seconds", "number", 0, TIMER_MAX_SEC },
    flight_timer_power_on_start = { "flight_timer_power_on_start", "flag" },
    sim_timer_commands = { "sim_timer_commands", "flag" },
    alias_commands = { "alias_commands", "flag" },
    diagnostic_datarefs = { "diagnostic_datarefs", "flag" },
    clicks = { "pick_mode", "choice", { off = 0, auto = 1, plugin = 2 } },
    -- the same words as the other on / off keys
    click_debug = { "pick_debug", "choice", { off = 0, on = 1, no = 0, yes = 1, ["0"] = 0, ["1"] = 1 } },
    click_pass_misses = { "pick_pass_misses", "choice", { off = 0, on = 1, no = 0, yes = 1, ["0"] = 0, ["1"] = 1 } },
}

local function log(message)
    if s_host ~= nil then s_host.log(message) end
end

local function factory_text()
    return (string.gsub(M.FACTORY_INI, "\r?\n", "\r\n"))
end

local UTF8_MARK = "\239\187\191"

-- The text without Notepad's UTF-8 mark (it would hide the first line's key)
-- and whether it had one; nil and whether the file is simply not there (a
-- file that is there but cannot be read is not rewritten from scratch).
local function read_file(path)
    local file, message, code = io.open(path, "rb")
    if file == nil then
        return nil, code == 2 or (code == nil and string.find(tostring(message), "No such file", 1, true) ~= nil)
    end
    local text = file:read("*a")
    file:close()
    if text == nil then return nil, false end
    if string.sub(text, 1, 3) == UTF8_MARK then return string.sub(text, 4), true end
    return text, false
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file == nil then return false end
    file:close()
    return true
end

local function write_whole(path, text)
    local file = io.open(path, "wb")
    if file == nil then return false end
    local ok = file:write(text) ~= nil
    return (file:close() and ok) == true
end

-- Writes path.tmp first and renames it over path, so a crash or a full disk
-- mid-write leaves the old file whole. Writes in place only where no .tmp file
-- can be created, or the old file cannot be replaced (then it fails as before).
local function write_file(path, text)
    local tmp = path .. ".tmp"
    local file = (os ~= nil and os.rename ~= nil and os.remove ~= nil) and io.open(tmp, "wb") or nil
    if file == nil then return write_whole(path, text) end
    local ok = file:write(text) ~= nil
    if not ((file:close() and ok) == true) then
        os.remove(tmp)          -- disk full: the old file stays as it was
        return false
    end
    if os.rename(tmp, path) then return true end
    -- Windows renames only onto a free name
    if os.remove(path) then
        if os.rename(tmp, path) then return true end
        if write_whole(path, text) then os.remove(tmp); return true end
        return false            -- the text is still in the .tmp file
    end
    os.remove(tmp)
    return write_whole(path, text)
end

local function split_lines(text)
    local lines, start = {}, 1
    while true do
        local stop = string.find(text, "\n", start, true)
        if stop == nil then
            lines[#lines + 1] = string.sub(text, start)
            return lines
        end
        lines[#lines + 1] = string.sub(text, start, stop - 1)
        start = stop + 1
    end
end

-- value text -> s_config value and the text kept for configuration mode, or nil
local function convert(entry, value)
    local kind = entry[2]
    if kind == "flag" then
        local flag = FLAGS[value]
        if flag == nil then return nil end
        return flag, flag and "on" or "off"
    elseif kind == "choice" then
        local result = entry[3][value]
        if result == nil then return nil end
        return result, type(result) == "string" and result or value
    elseif kind == "squawk" then
        if not string.match(value, "^[0-7][0-7][0-7][0-7]$") then return nil end
        return tonumber(value), value
    end
    -- whole numbers, as on the configuration pages; plain decimals only where
    -- a key takes them (tonumber also takes "nan", "inf" and "0x10")
    if not string.match(value, kind == "decimal" and "^%-?%d*%.?%d*$" or "^%-?%d+$") then return nil end
    local number = tonumber(value)
    if number == nil or number ~= number or number < entry[3] or number > entry[4] then return nil end
    return kind == "percent" and number / 100.0 or number, value
end

local function derive()
    s_config.backlight_source = BACKLIGHT_SOURCE[s_config.backlight_source_name] or 0
    s_config.key_light_source = BACKLIGHT_SOURCE[s_config.key_light_source_name] or 0
    s_config.air_state_delay = AIR_STATE_DELAY[s_config.aircraft_type] or 4.5
end

-- Sets s_config from one key; false when the value is not valid.
local function apply(key, value)
    local entry = SPEC[key]
    local result, text = convert(entry, value)
    if result == nil then return false end
    if entry[1] ~= nil then
        s_config[entry[1]] = result
        derive()
    end
    s_current[key] = text
    return true
end

-- calls fn(line_number, key, value) for every "key = value" line
local function each_setting(text, fn)
    for line_number, line in ipairs(split_lines(text)) do
        local key, raw = string.match(line, "^%s*([%w_]+)%s*=%s*([^#;]*)")
        if key ~= nil then
            fn(line_number, string.lower(key), string.lower(string.match(raw, "^%s*(.-)%s*$")))
        end
    end
end

-- Applies a whole ini text. report = false: silently (the factory text).
function M.parse(text, report)
    local set_on = {}       -- key -> the line whose value is in force
    local count = 0
    each_setting(text, function(line_number, key, value)
        count = count + 1
        if SPEC[key] == nil then
            if report then
                log("CONFIG " .. CONFIG_FILE .. " line " .. line_number .. ": unknown key '" .. key .. "' ignored. Local fix: correct or delete that line.")
            end
        elseif apply(key, value) then
            set_on[key] = line_number
        elseif report then
            local kept = set_on[key] and ("the value on line " .. set_on[key] .. " kept") or "factory value kept"
            log("CONFIG " .. CONFIG_FILE .. " line " .. line_number .. ": " .. key .. " = '" .. value .. "' is not valid; " .. kept .. ". Local fix: use a value listed in the comment above that key.")
        end
    end)
    if not report then return end
    -- a plain find: "%z" is Lua 5.1 only
    if string.find(text, "\0", 1, true) then
        if count == 0 then
            log("CONFIG " .. CONFIG_FILE .. ": no setting found in the file (saved as UTF-16 / Unicode?); Garmin factory values in use. Local fix: save it as UTF-8 or ANSI.")
        end
        return
    end
    -- A line that is not a comment, a [section] or "key = value" (a space
    -- or hyphen in the key, a colon for "=") is reported, not dropped silently;
    -- the first 20, then how many more
    local LIMIT, bad = 20, 0
    for line_number, line in ipairs(split_lines(text)) do
        -- a UTF-8 BOM before a first-line comment is fine; before a setting
        -- that line is not read (each_setting), so it is reported
        local trimmed = string.match(line_number == 1 and string.gsub(line, "^\239\187\191", "") or line, "^%s*(.-)%s*$")
        if trimmed ~= "" and not string.find(trimmed, "^[#;%[]")
            and not string.match(line, "^%s*[%w_]+%s*=")
        then
            bad = bad + 1
            if bad <= LIMIT then
                log("CONFIG " .. CONFIG_FILE .. " line " .. line_number .. ": '" .. trimmed .. "' is not a setting (key = value) and is ignored. Local fix: write it as key = value, or start it with #.")
            end
        end
    end
    if bad > LIMIT then
        log("CONFIG " .. CONFIG_FILE .. ": and " .. (bad - LIMIT) .. " more lines that are not settings, ignored. Local fix: check the file is a gtx327_config.ini.")
    end
    -- every setting commented out is a valid all-factory file; only an empty
    -- one is reported
    if count == 0 and not string.find(text, "%S") then
        log("CONFIG " .. CONFIG_FILE .. ": the file is empty; Garmin factory values in use. Local fix: put the package's gtx327_config.ini back.")
    end
end

function M.init(host, config)
    s_host = host
    s_config = config
end

---------------------------------------------------------------------------
-- gtx327_pilot.ini: the levels the pilot set on the DISPLAY and CONTRAST pages,
-- so a reload keeps them. A file of its own, so the author's
-- gtx327_config.ini is never rewritten behind their back. It holds only the
-- levels that differ from gtx327_config.ini, the last active code (the
-- pilot's guide: the unit powers on with the last active code) once it has
-- differed from the aircraft's at a load, and from then on always, even when
-- X-Plane has the same code (a reload in the same session), the last mode
-- where it is not ON, and the ACCUMULATE flight time where it is not zero;
-- none: no file. Written once these have stayed put for a few seconds, and
-- when the script stops.

local PILOT_FILE = "gtx327_pilot.ini"
local PILOT_DELAY_SEC = 5.0
-- after a failed write (a sync tool or virus scanner holding the file), the
-- next try waits this long; the unload always tries
local PILOT_RETRY_SEC = 60.0
local PILOT_KEYS = { "backlight_level", "key_light_level", "contrast_level" }
local PILOT_MODES = { stby = 1, on = 2, alt = 3 }
-- base: gtx327_config.ini's levels; saved: the levels on disk (or in force at
-- load); pending / since: a change waiting for the levels to settle. Levels
-- are whole percents, one number per PILOT_KEYS entry; entry 4 is the code
-- (base: the aircraft's at load; code set = kept), 5 the mode (base ON), 6 the ACCUMULATE
-- flight time in whole seconds (base 0). code, mode, flight: the file's;
-- code_now, mode_now, flight_now: the unit's.
-- retry_at: XPLMGetElapsedTime of the next try after a failed write;
-- failed_noted / recovered_noted: the CONFIG / NOTE lines, once per load.
local s_pilot = { base = {}, saved = nil, pending = {}, current = {}, since = nil,
    retry_at = nil, failed_noted = false, recovered_noted = false,
    code = nil, code_now = nil, mode = nil, mode_now = 2, flight = nil, flight_now = 0 }

local function pilot_path()
    return (string.match(s_host.path, "^(.*[/\\])") or "") .. PILOT_FILE
end

local function level_of(key)
    return math.floor(s_config[SPEC[key][1]] * 100 + 0.5)
end

-- the levels in force into into; true when they differ from compare (or
-- compare is nil)
local function read_levels(into, compare)
    local differs = false
    for index, key in ipairs(PILOT_KEYS) do
        into[index] = level_of(key)
        if compare == nil or compare[index] ~= into[index] then differs = true end
    end
    into[4], into[5], into[6] = s_pilot.code_now, s_pilot.mode_now, s_pilot.flight_now
    for index = 4, 6 do
        if compare ~= nil and compare[index] ~= into[index] then differs = true end
    end
    return differs
end

local function load_pilot()
    local text = read_file(pilot_path())
    if text == nil then return end
    -- the unit writes it as plain text: a NUL is UTF-16 or a damaged file
    -- (a plain find: "%z" is Lua 5.1 only)
    if string.find(text, "\0", 1, true) then
        log("CONFIG " .. PILOT_FILE .. " is not plain text (UTF-16, or damaged) and is ignored; the unit's next save replaces it. Local fix: delete " .. PILOT_FILE .. ".")
        return
    end
    local allowed, replaced = {}, {}
    for index, key in ipairs(PILOT_KEYS) do allowed[key] = index end
    each_setting(text, function(line_number, key, value)
        local code = key == "code" and convert(SPEC.vfr_code, value) or nil
        local mode = key == "mode" and PILOT_MODES[value] or nil
        local flight = key == "flight_time_sec" and convert({ nil, "number", 0, TIMER_MAX_SEC }, value) or nil
        if code ~= nil then
            s_pilot.code = code
        elseif mode ~= nil then
            s_pilot.mode = mode
        elseif flight ~= nil then
            s_pilot.flight = flight
        elseif allowed[key] ~= nil and apply(key, value) then
            local level = level_of(key)
            if level ~= s_pilot.base[allowed[key]] then replaced[#replaced + 1] = key .. " " .. level end
        else
            log("CONFIG " .. PILOT_FILE .. " line " .. line_number .. ": '" .. key .. " = " .. value .. "' ignored. Local fix: delete " .. PILOT_FILE .. ".")
        end
    end)
    -- the unit writes only comments and "key = value" lines: anything else
    -- is damage (one line for the first)
    for line_number, line in ipairs(split_lines(text)) do
        if string.find(line, "%S") and not string.match(line, "^%s*[#;]") and not string.match(line, "^%s*[%w_]+%s*=") then
            log("CONFIG " .. PILOT_FILE .. " line " .. line_number .. " is not 'key = value' and is ignored (a damaged file?). Local fix: delete " .. PILOT_FILE .. ".")
            break
        end
    end
    if #replaced > 0 then
        log("NOTE " .. PILOT_FILE .. ": the pilot's " .. table.concat(replaced, ", ") .. " in use instead of " .. CONFIG_FILE .. "'s. Delete " .. PILOT_FILE .. " to use " .. CONFIG_FILE .. ".")
    end
end

local function write_pilot(levels, now)
    local lines = {
        "# GTX 327 pilot memory, written by the unit: the DISPLAY and CONTRAST levels",
        "# (percent) that differ from gtx327_config.ini, the last code and mode, and the",
        "# ACCUMULATE flight time (seconds). Used at load. Delete this file to go back.",
    }
    for index, key in ipairs(PILOT_KEYS) do
        if levels[index] ~= s_pilot.base[index] then lines[#lines + 1] = key .. " = " .. levels[index] end
    end
    if levels[4] ~= nil and (s_pilot.code ~= nil or levels[4] ~= s_pilot.base[4]) then
        -- remembered: kept from now on, whatever X-Plane's code
        s_pilot.code = levels[4]
        lines[#lines + 1] = string.format("code = %04d", levels[4])
    end
    if levels[5] ~= s_pilot.base[5] then
        for name, mode in pairs(PILOT_MODES) do
            if mode == levels[5] then lines[#lines + 1] = "mode = " .. name end
        end
    end
    if levels[6] ~= s_pilot.base[6] then lines[#lines + 1] = "flight_time_sec = " .. levels[6] end
    local ok = true
    if #lines == 3 then
        -- back to gtx327_config.ini's levels: no file
        local file = io.open(pilot_path(), "rb")
        if file ~= nil then
            file:close()
            ok = os ~= nil and os.remove ~= nil and os.remove(pilot_path()) ~= nil
        end
    else
        ok = write_file(pilot_path(), table.concat(lines, "\r\n") .. "\r\n")
    end
    if ok then
        s_pilot.saved = { levels[1], levels[2], levels[3], levels[4], levels[5], levels[6] }
        if s_pilot.retry_at ~= nil and not s_pilot.recovered_noted then
            s_pilot.recovered_noted = true
            log("NOTE " .. PILOT_FILE .. " written again after a failed try.")
        end
        s_pilot.retry_at = nil
    else
        s_pilot.retry_at = (now or 0.0) + PILOT_RETRY_SEC
        if not s_pilot.failed_noted then
            s_pilot.failed_noted = true
            log("CONFIG " .. PILOT_FILE .. " could not be written (" .. pilot_path() .. "); the unit tries again every minute and when the aircraft unloads, and keeps the pilot's settings meanwhile. Local fix: make the folder writable, or stop whatever holds the file.")
        end
    end
end

-- A configuration-mode level being changed is not the pilot's yet (CRSR
-- saves it into gtx327_config.ini, CLR undoes it).
local function live_edit()
    return M.edit ~= nil and M.edit.live
end

-- The code the unit starts with: the file's, else the aircraft's (code).
function M.pilot_code(code)
    s_pilot.base[4] = code
    s_pilot.code_now = s_pilot.code or code
    if s_pilot.saved ~= nil then s_pilot.saved[4] = s_pilot.code_now end
    return s_pilot.code_now
end

-- The mode a power-up by the bus starts in: the file's, else ON.
function M.pilot_mode()
    return s_pilot.mode_now
end

-- The ACCUMULATE flight time at load, in seconds: the file's, else 0.
function M.pilot_flight_time()
    return s_pilot.flight_now
end

-- The unit's state into s_pilot; nil leaves an entry as it is (the mode while
-- the unit is not on).
local function pilot_state(code, mode, flight)
    if s_pilot.code_now ~= nil and code ~= nil then s_pilot.code_now = code end
    if mode ~= nil then s_pilot.mode_now = mode end
    if flight ~= nil then s_pilot.flight_now = math.min(math.max(math.floor(flight), 0), TIMER_MAX_SEC) end
end

-- Every frame: writes the levels, the code (the unit's last active code), the
-- mode and the flight time once they have stayed the same for a while.
function M.pilot_tick(now, code, mode, flight)
    pilot_state(code, mode, flight)
    if s_pilot.saved == nil or live_edit() then return end
    if s_pilot.retry_at ~= nil and now < s_pilot.retry_at then return end
    local current, pending = s_pilot.current, s_pilot.pending
    if not read_levels(current, s_pilot.saved) then
        s_pilot.since = nil
    else
        local moved = s_pilot.since == nil
        for index = 1, 6 do
            if current[index] ~= pending[index] then moved = true end
            pending[index] = current[index]
        end
        if moved then
            s_pilot.since = now
        elseif now - s_pilot.since >= PILOT_DELAY_SEC then
            write_pilot(current, now)
            s_pilot.since = nil
        end
    end
end

-- When the script stops or is disabled: writes a change not yet written.
function M.pilot_flush(code, mode, flight)
    pilot_state(code, mode, flight)
    if s_pilot.saved == nil then return end
    if live_edit() then M.exit() end
    local levels = {}
    if read_levels(levels, s_pilot.saved) then write_pilot(levels) end
end

-- Factory values, then the file; true when master_reset = 1 (which first
-- saves the file as .bak and writes the factory text in its place).
local function load_config()
    M.parse(M.FACTORY_INI, false)
    local path = s_host.path
    local text, marked = read_file(path)
    if text == nil then
        if marked then
            log("CONFIG " .. CONFIG_FILE .. " not found (" .. path .. "); Garmin factory values in use. Local fix: put the package's gtx327_config.ini back next to the script.")
        else
            log("CONFIG " .. CONFIG_FILE .. " could not be read (" .. path .. "); Garmin factory values in use, and configuration mode will not write to it. Local fix: close whatever holds the file, or make it readable.")
        end
        return false
    end
    local reset = false
    each_setting(text, function(_, key, value)
        if key == "master_reset" and FLAGS[value] ~= nil then reset = FLAGS[value] end
    end)
    if reset then
        -- the previous file byte for byte; an earlier reset's backup is kept
        local bak = CONFIG_FILE .. ".bak"
        for number = 2, 9 do
            if not file_exists(path .. string.sub(bak, #CONFIG_FILE + 1)) then break end
            bak = CONFIG_FILE .. ".bak" .. number
        end
        if write_file(path .. string.sub(bak, #CONFIG_FILE + 1), (marked and UTF8_MARK or "") .. text)
            and write_file(path, factory_text())
        then
            log("NOTE " .. CONFIG_FILE .. " master_reset = 1: Garmin factory values restored; the previous file is saved as " .. bak .. ".")
        else
            log("CONFIG " .. CONFIG_FILE .. " master_reset = 1 but the file could not be rewritten (" .. path .. "); Garmin factory values in use for this session. Local fix: make the file writable.")
        end
        return true
    end
    M.parse(text, true)
    return false
end

-- Start: gtx327_config.ini, then the pilot's levels (master_reset deletes them).
function M.load()
    local reset = load_config()
    read_levels(s_pilot.base)
    if reset then
        local file = io.open(pilot_path(), "rb")
        if file ~= nil then
            file:close()
            if not (os ~= nil and os.remove ~= nil and os.remove(pilot_path())) then
                log("CONFIG " .. PILOT_FILE .. " could not be deleted by master_reset (" .. pilot_path() .. "); it will replace the factory levels at the next load. Local fix: delete it.")
            end
        end
    else
        load_pilot()
    end
    s_pilot.base[5], s_pilot.base[6] = 2, 0
    s_pilot.mode_now, s_pilot.flight_now = s_pilot.mode or 2, s_pilot.flight or 0
    s_pilot.saved = {}
    read_levels(s_pilot.saved)
end

-- The [section] line a key sits under in the factory text, or nil.
local function factory_section(key)
    local section = nil
    for _, line in ipairs(split_lines(M.FACTORY_INI)) do
        if string.match(line, "^%[") then section = string.match(line, "^(%[[^%]]*%])") end
        if string.match(line, "^" .. key .. " =") then return section end
    end
    return nil
end

local function save_failed(path, why)
    if s_write_failed then return end
    s_write_failed = true
    log("CONFIG " .. CONFIG_FILE .. " " .. why .. " (" .. path .. "); configuration-mode changes last until the aircraft is reloaded. Local fix: "
        .. (why == "could not be written" and "make the file writable." or "save it as UTF-8 or ANSI, or close whatever holds it."))
end

-- Writes one value into the file: only the value of the key's active line
-- changes (the last one, which is the one in force); comments, unknown lines,
-- line ends and a UTF-8 mark stay as they are. A missing key goes after its
-- "# key =" comment if there is one, else at the end of its [section], else
-- at the end; a missing file is recreated from the factory text first. A
-- file that is there but cannot be read, or is UTF-16, is left alone.
function M.save(key, value)
    local path = s_host.path
    local text, marked = read_file(path)
    if text == nil and not marked then return save_failed(path, "could not be read") end
    if text ~= nil and string.find(text, "\0", 1, true) then return save_failed(path, "is not UTF-8 (UTF-16?)") end
    if text == nil then text, marked = factory_text(), false end
    local lines = split_lines(text)
    local cr = string.sub(lines[1] or "", -1) == "\r" and "\r" or ""
    local active, commented, header, next_header = nil, nil, nil, nil
    local section = factory_section(key)
    for index, line in ipairs(lines) do
        local name = string.match(line, "^%s*([%w_]+)%s*=")
        if name ~= nil and string.lower(name) == key then active = index end
        -- "# key = value", not a "#   key = ..." bullet inside a comment block
        if commented == nil and string.match(line, "^# ?" .. key .. "%s*=") then commented = index end
        local this = string.match(line, "^%s*(%[[^%]]*%])")
        if this ~= nil then
            if header ~= nil and next_header == nil then next_header = index end
            if section ~= nil and header == nil and string.lower(this) == string.lower(section) then header = index end
        end
    end
    if active ~= nil then
        -- the line end apart: a CRLF line with no value keeps its CR at the end
        local body, eol = string.match(lines[active], "^(.-)(\r?)$")
        local head, rest = string.match(body, "^(%s*[%w_]+%s*=%s*)(.*)$")
        local old, after = string.match(rest, "^([^#;]*)(.*)$")
        local gap = string.match(old, "%s*$")
        if gap == "" and string.match(after, "^[#;]") then gap = " " end
        lines[active] = head .. value .. gap .. after .. eol
    else
        local at = commented
        if at == nil then
            -- after the last line of its section that is not blank
            local floor = header or 0
            at = header ~= nil and (next_header or #lines + 1) - 1 or #lines
            while at > floor and string.match(lines[at], "^%s*$") do at = at - 1 end
        end
        if at == #lines then
            -- the file's last line has no line end yet
            lines[at] = lines[at] .. cr
            lines[#lines + 1] = ""
        end
        table.insert(lines, at + 1, key .. " = " .. value .. cr)
    end
    if not write_file(path, (marked and UTF8_MARK or "") .. table.concat(lines, "\n")) then
        save_failed(path, "could not be written")
    end
end

---------------------------------------------------------------------------
-- Configuration mode (IM 5.2). Eight pages; a field is a key of the ini.
-- Lists step with 8 / 9, numbers are typed digit by digit, the backlight
-- level and contrast step with 8 / 9 and apply at once (CLR restores).

local function value_of(key)
    local edit = M.edit
    if edit ~= nil and edit.key == key then return edit.text end
    return s_current[key]
end

local function manual_backlight() return s_current.backlight == "manual" end
local function auto_backlight() return s_current.backlight ~= "manual" end
local function never() return false end

-- contrast_level percent <-> the page's number: MAN 1-63, AUTO offset 0-99
local function contrast_number(percent)
    if value_of("contrast") == "manual" then return math.floor(percent * 62 / 100 + 0.5) + 1 end
    return math.min(percent, 99)
end

local function contrast_percent(number)
    if value_of("contrast") == "manual" then return math.floor((number - 1) * 100 / 62 + 0.5) end
    return number
end

-- Coordinates are dots on the 200 x 33 grid (positions measured from the manuals' page pictures).
local PAGES = {
    { -- 5.2.1 DISPLAY MODE
        texts = { { "DISPLAY MODE", 15, 13 }, { "LEVEL", 132, 13 } },
        fields = {
            { key = "display_mode", x = 94, y = 11,
              list = { { "AUTO", "auto" }, { "NGTV", "negative" }, { "PSTV", "positive" } } },
            { key = "display_change_level", x = 174, y = 11, digits = 2, min = 0, max = 99 },
        } },
    { -- 5.2.2 DISPLAY BACKLIGHT: MAN offers only BKLT and LVL
        texts = { { "BKLT", 2, 5 }, { "LVL", 61, 5 }, { "RSP TIME", 107, 5 }, { "MIN", 164, 5 },
                  { "BKLT SRCE", 2, 23 }, { "SLOPE", 97, 23 }, { "OFFSET", 147, 23 } },
        fields = {
            { key = "backlight", x = 28, y = 3, list = { { "MAN", "manual" }, { "AUTO", "auto" } } },
            { key = "backlight_level", x = 83, y = 3, level = true, when = manual_backlight },
            { key = "backlight_response", x = 155, y = 3, digits = 1, min = 3, max = 7, when = auto_backlight },
            { key = "backlight_min", x = 185, y = 3, digits = 2, min = 0, max = 99, when = auto_backlight },
            { key = "backlight_source", x = 54, y = 21, when = auto_backlight,
              list = { { "PHOTO", "photo" }, { "14V", "14v" }, { "28V", "28v" }, { "5V", "5v" } } },
            { key = "backlight_slope", x = 130, y = 21, digits = 2, min = 0, max = 99, when = auto_backlight },
            { key = "backlight_offset", x = 185, y = 21, digits = 2, min = 0, max = 99, when = auto_backlight },
        } },
    { -- 5.2.3 KEY LIGHTING: the same grid. KEY only shows the mode, which is
      -- changed on the page before; MAN offers only LVL
        texts = { { "KEY", 2, 5 }, { "LVL", 61, 5 }, { "RSP TIME", 107, 5 }, { "MIN", 164, 5 },
                  { "KEY SRCE", 2, 23 }, { "SLOPE", 97, 23 }, { "OFFSET", 147, 23 } },
        fields = {
            { key = "backlight", x = 24, y = 3, list = { { "MAN", "manual" }, { "AUTO", "auto" } }, when = never },
            { key = "key_light_level", x = 83, y = 3, level = true, when = manual_backlight },
            { key = "key_light_response", x = 155, y = 3, digits = 1, min = 3, max = 7, when = auto_backlight },
            { key = "key_light_min", x = 185, y = 3, digits = 2, min = 0, max = 99, when = auto_backlight },
            { key = "key_light_source", x = 54, y = 21, when = auto_backlight,
              list = { { "PHOTO", "photo" }, { "14V", "14v" }, { "28V", "28v" }, { "5V", "5v" } } },
            { key = "key_light_slope", x = 130, y = 21, digits = 2, min = 0, max = 99, when = auto_backlight },
            { key = "key_light_offset", x = 185, y = 21, digits = 2, min = 0, max = 99, when = auto_backlight },
        } },
    { -- 5.2.4 CONTRAST CONFIGURATION
        texts = { { "CONTRAST MODE", 5, 11, "bold" } },
        fields = {
            { key = "contrast", x = 99, y = 11, list = { { "MAN", "manual" }, { "AUTO", "auto" } } },
            { key = "contrast_level", x = 158, y = 23, contrast = true },
        } },
    { -- 5.2.5 VFR KEY CONFIGURATION
        texts = { { "VFR KEY", 60, 13 } },
        fields = {
            { key = "vfr_key", x = 110, y = 11, list = { { "DISABLE", "off" }, { "ENABLE", "on" } } },
        } },
    { -- 5.2.7.1 FIRST CONFIGURATION
        texts = { { "VS RATE", 2, 5 }, { "FLT TMR", 85, 5 }, { "VFR ID", 2, 22 }, { "FORMAT", 85, 22 } },
        symbols = { { "fpm", 71, 3 } },
        fields = {
            { key = "vs_rate", x = 43, y = 4, digits = 4, min = 0, max = 9999 },
            { key = "flight_timer", x = 127, y = 4,
              list = { { "MANUAL", "manual" }, { "CLEAR", "clear" }, { "ACCUMULATE", "accumulate" } } },
            { key = "vfr_code", x = 43, y = 20, digits = 4, octal = true },
            { key = "altitude_format", x = 127, y = 20,
              list = { { "FLIGHT LVL", "flight_level" }, { "FEET", "feet" }, { "METERS", "meters" } } },
        } },
    { -- 5.2.7.2 SECOND CONFIGURATION: static. X-Plane's on-ground flag is the
      -- squat switch, with the air-state delay it adds
        texts = { { "SQUAT SWITCH?", 2, 5 }, { "SENSE", 136, 5 }, { "YES", 88, 3, "bold" }, { "LOW", 171, 3, "bold" },
                  { "AUTO STANDBY?", 2, 23 }, { "DELAY TIME", 120, 23 } },
        fields = {
            { key = "auto_standby", x = 88, y = 21, list = { { "OFF", "off" }, { "ON", "on" } } },
            { key = "delay_time", x = 183, y = 21, digits = 2, min = 0, max = 99 },
        } },
    { -- 5.2.8 AIRCRAFT TYPE ("@" is the bold font's >=)
        texts = { { "AC TYPE", 54, 13 } },
        fields = {
            { key = "aircraft_type", x = 101, y = 11,
              list = { { "UNKNOWN", "unknown" }, { "<15.5K", "under_15500_lb" },
                       { "@15.5K", "15500_lb_or_more" }, { "ROTOR", "rotor" } } },
        } },
}

M.page = 1
M.field = nil    -- index into the page's fields, nil = nothing highlighted
M.edit = nil     -- { key, original, text, cursor, live }

local function list_index(field, text)
    for index, option in ipairs(field.list) do
        if option[2] == text then return index end
    end
    return 1
end

local function number_text(field, text)
    return string.format("%0" .. field.digits .. "d", math.floor(tonumber(text) or 0))
end

local function discard()
    local edit = M.edit
    if edit ~= nil and edit.live and edit.text ~= edit.original then apply(edit.key, edit.original) end
    M.edit = nil
    M.field = nil
end

local function accept()
    local edit = M.edit
    M.edit = nil
    if edit == nil or edit.text == edit.original then return end
    if apply(edit.key, edit.text) then
        M.save(edit.key, s_current[edit.key])
        -- a level saved here is gtx327_config.ini's now, not the pilot's
        for index, key in ipairs(PILOT_KEYS) do
            if key == edit.key then s_pilot.base[index] = level_of(key) end
        end
    end
end

local function select_from(first)
    local fields = PAGES[M.page].fields
    M.field = nil
    for index = first, #fields do
        local field = fields[index]
        if field.when == nil or field.when() then
            M.field = index
            local text = s_current[field.key]
            M.edit = { key = field.key, original = text, text = text,
                       live = field.level or field.contrast }
            return
        end
    end
end

local function step_value(field, delta)
    local edit = M.edit
    if field.list ~= nil then
        local index = math.min(math.max(list_index(field, edit.text) + delta, 1), #field.list)
        edit.text = field.list[index][2]
        return
    end
    local percent = tonumber(edit.text) or 0
    if field.level then
        percent = math.min(math.max(percent + delta, 0), 100)
    else
        local number = contrast_number(percent)
        local stepped = value_of("contrast") == "manual" and math.min(math.max(number + delta, 1), 63)
            or math.min(math.max(number + delta, 0), 99)
        -- at either end of the range a key does nothing (AUTO shows 100 % as
        -- 99: 9 there must not lower it)
        if stepped == number then return end
        percent = math.min(contrast_percent(stepped), 100)
    end
    edit.text = tostring(percent)
    apply(edit.key, edit.text)
end

local function type_digit(field, digit)
    local edit = M.edit
    if field.octal and digit > 7 then return end
    local position = edit.cursor or 1
    local text = number_text(field, edit.text)
    text = string.sub(text, 1, position - 1) .. digit .. string.sub(text, position + 1)
    if field.octal then
        edit.text = text
    else
        edit.text = tostring(math.min(math.max(tonumber(text), field.min), field.max))
    end
    edit.cursor = position < field.digits and position + 1 or nil
end

function M.enter()
    -- The pilot's CONTRAST / DISPLAY pages change the same two values (IM
    -- 5.2.2, 5.2.4): show what is in force now, not what the file says.
    s_current.contrast_level = tostring(math.floor(s_config.contrast_level * 100 + 0.5))
    s_current.backlight_level = tostring(math.floor(s_config.display_level * 100 + 0.5))
    s_current.key_light_level = tostring(math.floor(s_config.key_light_level * 100 + 0.5))
    M.page = 1
    M.field = nil
    M.edit = nil
end

function M.exit()
    discard()
    M.page = 1
end

-- name: the key ("func", "startstop", "clr", "crsr", "0".."9"; others do nothing)
function M.key(name)
    if name == "func" then
        discard()
        M.page = M.page % #PAGES + 1
    elseif name == "startstop" then
        discard()
        M.page = math.max(M.page - 1, 1)
    elseif name == "clr" then
        discard()
    elseif name == "crsr" then
        local next_field = (M.field or 0) + 1
        accept()
        select_from(next_field)
    elseif M.edit ~= nil then
        local digit = tonumber(name)
        local field = PAGES[M.page].fields[M.field]
        if digit == nil then return end
        if field.digits ~= nil then
            type_digit(field, digit)
        elseif digit == 8 or digit == 9 then
            step_value(field, digit == 8 and -1 or 1)
        end
    end
end

-- The page as raster items (gtx327_raster.lua draw_setup). live_backlight,
-- live_key: the backlight and key lighting levels now (0-1), shown by LVL in
-- AUTO.
function M.items(live_backlight, live_key)
    local page = PAGES[M.page]
    local items = {}
    for _, text in ipairs(page.texts) do
        items[#items + 1] = { font = text[4] or "small", text = text[1], x = text[2], y = text[3] }
    end
    for _, symbol in ipairs(page.symbols or {}) do
        items[#items + 1] = { symbol = symbol[1], x = symbol[2], y = symbol[3] }
    end
    for index, field in ipairs(page.fields) do
        local selected = M.field == index and M.edit ~= nil
        local value = value_of(field.key)
        local text, font = nil, "bold"
        if field.list ~= nil then
            text = field.list[list_index(field, value)][1]
        elseif field.digits ~= nil then
            text = number_text(field, value)
        elseif field.level then
            local live = field.key == "key_light_level" and live_key or live_backlight
            local level = value_of("backlight") == "manual" and (tonumber(value) or 0) / 100 or live or 0
            text = string.format("%03d", math.floor(math.min(math.max(level, 0), 1) * 999 + 0.5))
        else
            local number = contrast_number(tonumber(value) or 0)
            local manual = value_of("contrast") == "manual"
            -- The bar is 62 dots with a one-dot outline, so only the 60
            -- columns inside it show the level: the lowest number leaves them
            -- empty, the highest fills them, and the next ones each show a
            -- step (1-63 or 0-99 on 60 columns, 1 + those columns filled).
            local low, high = manual and 1 or 0, manual and 63 or 99
            local inside = math.floor((math.min(math.max(number, low), high) - low) * 60 / (high - low) + 0.5)
            items[#items + 1] = { bar = (1 + inside) / 62, x = 133, y = 10 }
            text, font = string.format("%03d", number), "small"
        end
        items[#items + 1] = { font = font, text = text, x = field.x, y = field.y,
                              highlight = selected, cursor = selected and M.edit.cursor or nil }
    end
    return items
end

return M
