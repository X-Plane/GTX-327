--[[ XLua 2.0 ]]

-- Garmin GTX 327 Mode A/C transponder for X-Plane 12 (XLua 2 + Panel Graphics).
-- Behaviour follows Garmin's Pilot's Guide 190-00187-00 Rev D and Installation
-- Manual 190-00187-02 Rev N; installation options live in gtx327_config.ini.
-- 3D model: Massimo Durando.
--
-- xLua callback budget (XLua before 2.0.0-r1 only; r1 has none): ~500 per aircraft, shared by every script, counted per
-- registration (measured with earlier xLua instruments). The core uses 30: the installed
-- and key_light datarefs 2, the 21 key and popup commands 21, the screen device 2 (draw and
-- brightness), the flight loop 1 and the click window 4; the popup adds 5 each
-- time it opens (it is destroyed on close). Compatibility aliases and the state datarefs
-- ([Budget] in gtx327_config.ini), the debug commands (debug_mode), and the 12 handlers that keep X-Plane's code
-- up / down commands from X-Plane, are optional: registered last and
-- dropped quietly when the budget is gone. Start and Enable are transactional:
-- on a failure everything already registered is released, so the instrument
-- hidden by laminar/gtx327/installed comes back.

require("XPLMDataAccess")
require("XPLMDisplay")
require("XPLMPanelGraphics")
require("XPLMPlanes")
require("XPLMProcessing")
require("XPLMUtilities")

local BASELINE_VERSION = 18
local RASTER_PIPELINE_REVISION = 13

local POWER_OFF = 0
local POWER_SELF_TEST = 1
local POWER_OPERATING = 2
-- configuration mode (IM 5.2, gtx327_setup.lua): FUNC held while a power key
-- turns the unit on; OFF leaves it
local POWER_CONFIG = 3
local SELF_TEST_BLANK_SEC = 1.0
local SELF_TEST_DURATION_SEC = 7.0
local OFF_HOLD_DURATION_SEC = 1.0
local OFF_FADE_DURATION_SEC = 0.3
local THEME_TRANSITION_SEC = 1.0
local POST_ENTRY_RECALL_SEC = 5.0
local IDENT_DURATION_SEC = 18.0
local ADVISORY_DURATION_SEC = 5.0
local FUNC_PAGE_COUNT = 6
local TIMER_MAX_SEC = 99 * 3600 + 59 * 60 + 59
local EXPIRED_BLINK_HZ = 2.0

-- Installation configuration values (gtx327_config.ini, read and written by
-- gtx327_setup.lua with the same numbers).
local FLIGHT_TIMER_MANUAL = 0
local FLIGHT_TIMER_CLEAR = 1
-- 2 = ACCUMULATE: neither MANUAL nor CLEAR
local ALTITUDE_FORMAT_FEET = 0
local ALTITUDE_FORMAT_FLIGHT_LEVEL = 1
local ALTITUDE_FORMAT_METERS = 2
local ENCODER_MIN_FT = -1000
local ENCODER_MAX_FT = 62700
local LEVEL_STEP = 0.05
-- Installation manual 5.2.2 BKLT SRCE. An instrument rheostat
-- (instrument_brightness_ratio[lighting_dimmer], factory 0) stands in for the
-- 14 / 28 / 5 V lighting bus: the unit has one lighting bus input (IM 4.1.2).
local BACKLIGHT_PHOTO = 0
local BACKLIGHT_BUS = 1
-- "Lighting bus control turned to its minimum (daytime) setting".
local BACKLIGHT_BUS_MINIMUM = 0.02

local DEVICE_ID_3D = "XPNDR_GTX327"
local DEVICE_ID_POPUP = "XPNDR_GTX327_popup"
local DREF_PREFIX = "laminar/gtx327/"

-- The popup bezel is a straight-on render of the 3D model (3D/GTX327.obj) at
-- the screen device's scale (4.29 x 4.34 px per mm), so the popup has the 3D
-- unit's proportions. The images are four times this size for a sharper enlarged
-- popup; BUTTONS below are the model's own click boxes on the same scale.
local BEZEL_W = 760
local BEZEL_H = 197
local POPUP_NATIVE_ASPECT = BEZEL_W / BEZEL_H
local POPUP_ASPECT_TOLERANCE_PX = 2
-- Popup face brightness (1 = the image as drawn) by day and at full night.
-- By day as X-Plane's own 530 popup open beside it (face and keys average
-- 53 there against 62 for this image at 1.0).
local POPUP_DAY_SHADE = 0.85
local POPUP_NIGHT_SHADE = 0.18
local SCREEN_W = 407
local SCREEN_H = 95
local SCREEN_OFFSET_X = 201
local SCREEN_OFFSET_Y = 77
-- The numbers above and BUTTONS are bezel units (the popup art's layout). The
-- devices work in pixels 4 times finer, the bezel images' own pixels, so the
-- LCD can be drawn at the real unit's size in whole pixels per cell:
-- clicks are divided by this, everything drawn is multiplied by it.
local DEVICE_PX = 4

-- The real unit's lit area is the whole 200 x 33 grid, set in from the black
-- window: 0.52 x 0.087 of the 0-key to 9-key span in three photos of real
-- units. 7 px a cell gives 0.528 x 0.087, and every lit
-- cell stays a hard-edged rectangle. Centred in the visible window, which
-- reaches 6 bezel units (the model's dark glass) above the screen.
local LCD_W = 200
local LCD_H = 33
local LCD_SCALE = 7
local LCD_ORIGIN_X = math.floor((SCREEN_W * DEVICE_PX - LCD_W * LCD_SCALE) / 2)
local LCD_ORIGIN_Y = math.floor(((SCREEN_H + 6) * DEVICE_PX - LCD_H * LCD_SCALE) / 2)

local SCRIPT_FOLDER = "custom_device_GTX327"
local BASE_IMAGE = "xpndr_GTX327_2d.png"
local LIT_IMAGE = "xpndr_GTX327_2d-1.png"
local RASTER_DATA_FILE = "gtx327_raster.lua"
local CONFIG_FILE = "gtx327_config.ini"
local PLUGIN_MASTER_BRIGHTNESS = 1.0

local MODE_LABELS = {
    [0] = "OFF",
    [1] = "STBY",
    [2] = "ON",
    [3] = "ALT",
    [4] = "TEST",
    [5] = "GND",
    [6] = "----",
    [7] = "----"
}


local COMMAND_PREFIX = "laminar/gtx327_"

local BUTTONS = {
    { name = "ident", command = "sim/transponder/transponder_ident", passthrough = true, left = 24, top = 164, right = 74, bottom = 125 },
    { name = "vfr", command = "sim/transponder/transponder_vfr", passthrough = false, left = 24, top = 118, right = 74, bottom = 79 },
    { name = "on", command = "sim/transponder/transponder_on", passthrough = false, left = 106, top = 176, right = 158, bottom = 144,
      outline = { 106, 165, 114, 146.5, 117.5, 144.5, 146.5, 144.5, 150, 146.5, 157.5, 165, 156, 168.5, 144.5, 173.5, 132, 175.5, 119.5, 173.5, 108, 168.5 } },
    { name = "stby", command = "sim/transponder/transponder_standby", passthrough = false, left = 79, top = 126, right = 121, bottom = 77,
      outline = { 79.5, 120.5, 81, 107.5, 86, 95.5, 94.5, 85, 105, 77, 109, 77, 120.5, 93, 120, 97.5, 105, 123.5, 101.5, 126, 81.5, 124 } },
    { name = "alt", command = "sim/transponder/transponder_alt", passthrough = false, left = 110, top = 145, right = 155, bottom = 99,
      outline = { 110, 122, 110.5, 116, 113, 110.5, 116.5, 106, 121, 102.5, 126.5, 100, 132.5, 99.5, 138.5, 100, 144, 102.5, 148.5, 106, 152, 110.5, 154.5, 116, 155, 122, 154.5, 128, 152, 133.5, 148.5, 138, 144, 141.5, 138.5, 144, 132.5, 144.5, 126.5, 144, 121, 141.5, 116.5, 138, 113, 133.5, 110.5, 128 } },
    { name = "off", command = "sim/transponder/transponder_off", passthrough = false, left = 144, top = 125, right = 185, bottom = 76,
      outline = { 144.5, 92.5, 156, 76.5, 160, 77, 170, 84.5, 178, 95, 183, 107, 184.5, 120, 182.5, 123, 163, 125, 160, 122.5, 145, 97 } },
    { name = "0", command = "sim/transponder/transponder_digit_0", passthrough = false, left = 24, top = 56, right = 74, bottom = 17 },
    { name = "1", command = "sim/transponder/transponder_digit_1", passthrough = false, left = 91, top = 56, right = 140, bottom = 17 },
    { name = "2", command = "sim/transponder/transponder_digit_2", passthrough = false, left = 158, top = 56, right = 207, bottom = 17 },
    { name = "3", command = "sim/transponder/transponder_digit_3", passthrough = false, left = 225, top = 56, right = 274, bottom = 17 },
    { name = "4", command = "sim/transponder/transponder_digit_4", passthrough = false, left = 291, top = 56, right = 340, bottom = 17 },
    { name = "5", command = "sim/transponder/transponder_digit_5", passthrough = false, left = 374, top = 56, right = 422, bottom = 17 },
    { name = "6", command = "sim/transponder/transponder_digit_6", passthrough = false, left = 441, top = 56, right = 490, bottom = 17 },
    { name = "7", command = "sim/transponder/transponder_digit_7", passthrough = false, left = 509, top = 56, right = 558, bottom = 17 },
    -- 8 and 9 are never squawk digits, so they have no sim/transponder command.
    -- START/STOP and CLR are the unit's own keys. sim/instruments/timer_* belong
    -- to the aircraft clock and are taken over only with sim_timer_commands = on.
    { name = "8", command = "laminar/gtx327_8", passthrough = false, left = 624, top = 56, right = 674, bottom = 17 },
    { name = "9", command = "laminar/gtx327_9", passthrough = false, left = 688, top = 56, right = 737, bottom = 17 },
    { name = "func", command = "laminar/gtx327_func", passthrough = false, left = 624, top = 164, right = 673, bottom = 125 },
    { name = "crsr", command = "sim/transponder/transponder_CLR", passthrough = false, left = 687, top = 164, right = 737, bottom = 125 },
    { name = "startstop", command = "laminar/gtx327_startstop", sim_alias = "sim/instruments/timer_start_stop", passthrough = false, left = 624, top = 118, right = 673, bottom = 79 },
    { name = "clr", command = "laminar/gtx327_clr", sim_alias = "sim/instruments/timer_reset", passthrough = false, left = 687, top = 117, right = 737, bottom = 78 }
}

local DEBUG_AIRBORNE_COMMANDS = {
    { name = "live", value = -1 },
    { name = "ground", value = 0 },
    { name = "airborne", value = 1 }
}

-- The values of the shipped gtx327_config.ini (Garmin's factory values, IM 5.2,
-- except AUTO STANDBY off, plus the X-Plane options), used for every key the
-- file leaves out or when it is missing.
local s_config = {
    altitude_format = ALTITUDE_FORMAT_FLIGHT_LEVEL,
    display_mode = 0,
    photo_sensor_threshold = 0.75,
    countdown_default_seconds = 0,
    manual_contrast_page = false,
    manual_display_page = false,
    contrast_level = 0.50,
    display_level = 1.0,
    backlight_source_name = "photo",
    backlight_source = BACKLIGHT_PHOTO,
    backlight_min = 8,
    backlight_slope = 50,
    backlight_offset = 50,
    backlight_response = 4,
    backlight_cloud_dim = 1.0,
    key_light_level = 1.0,
    key_light_source_name = "photo",
    key_light_source = BACKLIGHT_PHOTO,
    key_light_min = 8,
    key_light_slope = 50,
    key_light_offset = 50,
    key_light_response = 4,
    lighting_dimmer = 0,
    altitude_trend_fpm = 500.0,
    auto_standby_enabled = false, -- off by default (Garmin ships on)
    ground_delay_seconds = 24.0,
    flight_timer_mode = FLIGHT_TIMER_CLEAR,
    flight_timer_power_on_start = false,
    vfr_key_enabled = true,
    vfr_code = 1200,
    aircraft_type = "under_15500_lb",
    air_state_delay = 4.5,
    power_source = 0,
    power_bus = 0,
    debug_mode = false,
    popup_frame = false,
    -- Not Garmin options: X-Plane integration.
    sim_timer_commands = false,
    -- [Budget]: optional registrations (each costs xLua callbacks).
    alias_commands = false,
    diagnostic_datarefs = false,
    -- gtx327_pick.lua: 0 off, 1 auto (yields to native clicks), 2 always.
    pick_mode = 1,
    pick_pass_misses = 0,
    pick_debug = 0,
    pick_inject_marker = "laminar/gtx327"
}

local s_raster = nil
local s_pick = nil
local s_setup = nil
local s_lcd_foreground = nil
local s_lcd_background = nil
local s_clear_black = nil
local s_atlas = nil
local s_base_image = nil
local s_lit_image = nil
local s_device_3d = nil
local s_device_popup = nil
local s_flight_loop = nil

local s_button_commands = {}
-- popup bezel callbacks (click, cursor), assigned with the key handling below
local s_bezel_cb = {}
local s_diag_read = {}
-- What this script has handed to the SDK (see "Registration"). entries: id ->
-- getter or command function; datarefs / commands: { handle or command, id,
-- stage }; devices: callbacks per live device; windows: click windows.
local s_reg = { entries = {}, next_id = 0, datarefs = {}, commands = {}, devices = {}, windows = 0 }

local s_xlua_loaded = 0
local s_heartbeat = 0

local s_dr = {
    master_power = nil,
    bus_volts = nil,
    bus_load = nil,
    instrument_brightness = nil,
    photocell = nil,
    elevation = nil,
    cloud_cover = nil,
    cloud_type = nil,
    cloud_base = nil,
    cloud_top = nil,
    rain = nil,
    transponder_code = nil,
    transponder_mode = nil,
    transponder_ident = nil,
    transponder_reply = nil,
    pressure_altitude = nil,
    onground_any = nil,
    groundspeed = nil,
    radio_altitude = nil,
    vertical_speed = nil,
    scene_night_factor = nil,
    cockpit_light_r = nil,
    cockpit_light_g = nil,
    cockpit_light_b = nil,
    transponder_failure = nil,
    static_failure = nil,
    run_time = nil,
    paused = nil,
    replay = nil
}

-- One immutable-per-frame snapshot feeds both the cockpit and popup draw paths.
local s_render = {
    debug_mode = 0,
    powered = false,
    power_state = POWER_OFF,
    self_test_text_visible = false,
    instrument_brightness = 1.0,
    effective_brightness = 0.0,
    effective_brightness_3d = 0.0,
    bezel_lit_alpha = 0.0,
    bezel_shade = 1.0,
    popup_aspect_milli = 0,
    popup_geometry_status = 0,
    code = 1200,
    code_text = "1200",
    code_entry_active = false,
    code_entry_count = 0,
    code_entry_cursor_slot = 0,
    mode = 2,
    mode_text = "ON",
    ident = false,
    reply = false,
    pressure_altitude = 0.0,
    pressure_altitude_valid = false,
    pressure_prefix = "FL",
    pressure_value = "000",
    pressure_suffix = "",
    altitude_trend = 0,
    airborne = false,
    flight_time = 0.0,
    flight_timer_running = false,
    count_up_elapsed = 0.0,
    count_up_running = false,
    count_down_value = 0.0,
    count_down_initial = 0.0,
    count_down_running = false,
    count_down_expired = false,
    count_down_entry_text = nil,
    count_down_entry_active = false,
    count_down_entry_count = 0,
    count_down_entry_cursor_position = 0,
    expired_visible = false,
    advisory_text = nil,
    shutdown_message = false,
    shutdown_fade = 0.0,
    ambient_light = 1.0,
    theme_blend = 0.0,
    contrast_level = 0.50,
    display_level = 1.0,
    page = 0,
    heartbeat = 0
}

-- Pilot-facing state is kept separate from the simulator datarefs. The active
-- squawk remains unchanged while a replacement code is being entered.
local s_unit = {
    initialized = false,
    power_state = POWER_OFF,
    requested_mode = 2,
    selected_mode = 2,
    active_code = 1200,
    entry_digits = nil,
    entry_count = 0,
    entry_cursor_slot = nil,
    post_entry_until = 0.0,
    self_test_started_at = 0.0,
    self_test_until = 0.0,
    self_test_failed = false,
    ident_until = 0.0,
    vfr_active = false,
    vfr_previous_code = nil,
    func_page = 0,
    advisory_text = nil,
    advisory_until = 0.0,
    airborne_known = false,
    airborne = false,
    ground_since = nil,
    -- sim_clock when the raw air / ground reading first disagreed with
    -- airborne (nil while they agree): the change waits out its debounce
    airborne_change_since = nil,
    debug_airborne_override = -1,
    -- Simulator clock: frozen while paused or in replay, scaled by time
    -- acceleration. Timers, the landing delay, IDENT (18 s), the 5 s recall
    -- and the advisory prompt run on it. The self test, the OFF hold,
    -- fades, easing, blinking and key timing stay on XPLMGetElapsedTime.
    sim_clock = 0.0,
    last_run_time = nil,
    last_real_time = nil,
    flight_time = 0.0,
    flight_timer_running = false,
    -- the ACCUMULATE flight time last handed to gtx327_pilot.ini
    flight_saved = 0.0,
    count_up_elapsed = 0.0,
    count_up_running = false,
    count_down_initial = 0.0,
    count_down_remaining = 0.0,
    count_down_expired_elapsed = 0.0,
    count_down_running = false,
    count_down_expired = false,
    count_down_entry_digits = nil,
    count_down_entry_original = nil,
    count_down_entry_position = nil,
    off_hold_active = false,
    off_hold_started_at = 0.0,
    shutdown_fade_started_at = 0.0,
    -- configuration mode entry: FUNC held, or (mouse stand-in) FUNC tapped
    -- while off less than 3 s before the power key
    func_held = false,
    func_held_at = 0.0,
    func_tapped_at = nil,
    config_requested = false,
    -- popup key held by the mouse (its CommandEnd is sent if the popup hides)
    popup_key = nil,
    -- the SELF TEST FAILED note goes to Log.txt once per load
    failure_noted = false,
    ambient_light = 1.0,
    night_mode = false,
    theme_blend = 0.0,
    theme_last_update_time = 0.0,
    backlight = 0.0,
    -- the 3D screen's: dimmed by the sky over the aircraft (eased, 1 = clear)
    backlight_3d = 0.0,
    -- daylight on the LCD's face, as a screen level (popup, 3D screen): what
    -- shows with the backlight at 000 (update_backlight)
    reflected = 0.0,
    reflected_3d = 0.0,
    sky = nil,
    -- key lighting level (KEY LIGHTING LVL), 0-1, and the legend glow it
    -- gives, 0-1, before the unit's power (update_backlight)
    key_drive = 0.0,
    key_light = 0.0,
    -- MAN key lighting minus the screen level as the pilot left it on the
    -- DISPLAY page, kept through a clamp at 0 or 100 %; nil = not yet
    key_offset = nil,
    backlight_last_update_time = nil,
    last_bus_power = false,
    -- this unit's share of plugin_bus_load_amps[power_bus]
    bus_load_amps = 0.0,
    -- the "avionics master on, bus dead" note goes to Log.txt once per load,
    -- and only before the bus was ever live (later: a crash or a failure)
    dead_bus_noted = false,
    pressed_button_identifier = 0,
    last_touch_identifier = 0,
    -- IDENT's Begin went on to X-Plane: its Continue / End follow it
    ident_passed = false,
    -- X-Plane's transponder_id still on from before the last power off or on:
    -- not this power cycle's IDENT, ignored until it ends
    ident_stale = false,
    -- X-Plane's transponder failure seen at any time during the self test
    self_test_fault_seen = false,
    -- the code loaded at Start differs from X-Plane's: written into X-Plane
    -- once Enable has succeeded (without the unit X-Plane keeps its own)
    code_to_sim = false,
    -- an outside code the keys cannot make, written back: one NOTE per load
    invalid_code_noted = false
}

local s_popup_seen_visible = false
local s_popup_grace_frames = 0
local s_popup_native_geometry = nil
local s_popup_os_geometry = nil
local s_popup_mode = nil
local s_popup_geometry_settle_frames = 0

local function log(message)
    print("[GTX327] " .. tostring(message))
end

-- fn behind an error guard, for the callbacks X-Plane calls every frame or
-- on every key: a script error writes one BUG line per guard (the devices'
-- and flight loop's per Enable, the shared key handler's per load) instead of
-- an xLua error on every call, and the call answers fallback.
local function guarded(name, fn, fallback)
    local reported = false
    return function(...)
        local ok, result = pcall(fn, ...)
        if ok then return result end
        if not reported then
            reported = true
            log("BUG " .. name .. " failed (" .. tostring(result) .. "); later failures are not logged."
                .. " Report on GitHub with Log.txt.")
        end
        return fallback
    end
end

local function clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

local function unwrap_string(value)
    if type(value) == "table" then
        return value[1] or value.outPath or value.outFileName or value.outSystemPath or ""
    end
    return value or ""
end

local function unwrap_number(value)
    if type(value) == "number" then return value end
    return tonumber(tostring(value))
end

local function normalize_path(path)
    return tostring(path or ""):gsub("\\", "/")
end

local function dirname(path)
    return normalize_path(path):match("^(.*)/[^/]*$") or ""
end

local function make_xplane_relative_path(path)
    local normalized = normalize_path(path)
    local system_result = XPLMGetSystemPath()
    local system_path = ""
    if type(system_result) == "table" then
        system_path = normalize_path(unwrap_string(system_result.outSystemPath or system_result))
    else
        system_path = normalize_path(unwrap_string(system_result))
    end

    if system_path ~= "" then
        if string.sub(system_path, -1) ~= "/" then system_path = system_path .. "/" end
        if string.sub(normalized, 1, string.len(system_path)) == system_path then
            return string.sub(normalized, string.len(system_path) + 1)
        end
    end

    return normalized
end

local s_script_dir = nil

-- Files next to this script. The folder is wherever xLua loaded it from
-- (plugins/xlua/scripts/<name> or plugins/xlua2/scripts/<name>), so the unit
-- runs in any aircraft without knowing its layout.
local function resource_path(filename)
    if s_script_dir == nil then
        local info = debug and debug.getinfo and debug.getinfo(1, "S")
        local source = info and info.source or ""
        if string.sub(source, 1, 1) == "@" then
            s_script_dir = dirname(string.sub(source, 2))
        end
        if s_script_dir == nil or s_script_dir == "" then
            local model = XPLMGetNthAircraftModel(XPLM_USER_AIRCRAFT)
            local aircraft_dir = dirname(type(model) == "table" and unwrap_string(model.outPath) or "")
            s_script_dir = aircraft_dir .. "/plugins/xlua/scripts/" .. SCRIPT_FOLDER
            for _, runtime in ipairs({ "xlua", "xlua2" }) do
                local candidate = aircraft_dir .. "/plugins/" .. runtime .. "/scripts/" .. SCRIPT_FOLDER
                local file = io.open(make_xplane_relative_path(candidate .. "/" .. SCRIPT_FOLDER .. ".lua"), "r")
                if file ~= nil then
                    file:close()
                    s_script_dir = candidate
                    break
                end
            end
        end
    end
    return make_xplane_relative_path(s_script_dir .. "/" .. filename)
end

-- A module next to this script (gtx327_pick.lua, gtx327_setup.lua): loadfile
-- with this script's environment. Returns the module's table,
-- or nil and why.
local function load_module(filename)
    local ok, chunk, err = pcall(loadfile, resource_path(filename))
    if not ok or type(chunk) ~= "function" then return nil, tostring(err or chunk) end
    if setfenv and getfenv then setfenv(chunk, getfenv(1)) end
    local ok_run, module = pcall(chunk)
    if not ok_run or type(module) ~= "table" then return nil, tostring(module) end
    return module
end

local function get_int(handle, fallback)
    if handle == nil then return fallback end
    local ok, value = pcall(XPLMGetDatai, handle)
    if ok and value ~= nil then return value end
    return fallback
end

local function func_page_enabled(page)
    if page == 4 then return s_config.manual_contrast_page end
    if page == 5 then return s_config.manual_display_page end
    return page >= 0 and page < FUNC_PAGE_COUNT
end

local function next_func_page(page)
    local candidate = math.floor(page or 0)
    for _ = 1, FUNC_PAGE_COUNT do
        candidate = (candidate + 1) % FUNC_PAGE_COUNT
        if func_page_enabled(candidate) then return candidate end
    end
    return 0
end

local function get_float(handle, fallback)
    if handle == nil then return fallback end
    local ok, value = pcall(XPLMGetDataf, handle)
    if ok and value ~= nil then return value end
    return fallback
end

local get_float_array_value
do
    local values = {}   -- reused: read several times a frame
    get_float_array_value = function(handle, zero_based_index, fallback)
        if handle == nil then return fallback end
        values[1] = nil
        local index = math.max(0, math.floor(zero_based_index or 0))
        local ok, count = pcall(XPLMGetDatavf, handle, values, index, 1)
        if not ok or not count or count <= 0 or values[1] == nil then return fallback end
        return values[1]
    end
end

local function now_seconds()
    local ok, value = pcall(XPLMGetElapsedTime)
    if ok and value ~= nil then return value end
    return 0.0
end

local function set_int(handle, value)
    if handle == nil then return false end
    local ok = pcall(XPLMSetDatai, handle, math.floor(value))
    return ok
end

local function is_valid_squawk(code)
    local value = math.floor(tonumber(code) or -1)
    if value < 0 or value > 7777 then return false end
    local text = string.format("%04d", value)
    for index = 1, 4 do
        if tonumber(string.sub(text, index, index)) > 7 then return false end
    end
    return true
end

local function digits_from_code(code)
    local text = string.format("%04d", math.floor(code or 0))
    return {
        tonumber(string.sub(text, 1, 1)),
        tonumber(string.sub(text, 2, 2)),
        tonumber(string.sub(text, 3, 3)),
        tonumber(string.sub(text, 4, 4))
    }
end

local function code_from_digits(digits)
    return digits[1] * 1000 + digits[2] * 100 + digits[3] * 10 + digits[4]
end

local function code_display_text()
    if s_unit.entry_digits == nil then
        return string.format("%04d", s_unit.active_code)
    end

    local characters = {}
    for index = 1, 4 do
        characters[index] = s_unit.entry_digits[index] ~= nil
            and tostring(s_unit.entry_digits[index]) or "-"
    end
    return table.concat(characters)
end

local function timer_entry_display_text()
    if s_unit.count_down_entry_digits == nil then return nil end

    local characters = {}
    for index = 1, 6 do
        characters[index] = tostring(s_unit.count_down_entry_digits[index] or 0)
    end
    return characters[1] .. characters[2] .. ":"
        .. characters[3] .. characters[4] .. ":"
        .. characters[5] .. characters[6]
end

local function timer_digits_from_seconds(seconds)
    local total = clamp(math.floor(tonumber(seconds) or 0), 0, TIMER_MAX_SEC)
    local text = string.format(
        "%02d%02d%02d",
        math.floor(total / 3600),
        math.floor(total / 60) % 60,
        total % 60
    )
    local digits = {}
    for index = 1, 6 do
        digits[index] = tonumber(string.sub(text, index, index)) or 0
    end
    return digits
end

local function timer_seconds_from_digits(digits)
    local hours = digits[1] * 10 + digits[2]
    local minutes = digits[3] * 10 + digits[4]
    local seconds = digits[5] * 10 + digits[6]
    return clamp(hours * 3600 + minutes * 60 + seconds, 0, TIMER_MAX_SEC)
end

local function cancel_count_down_entry(reason)
    -- Left before the sixth digit: the count down is as it was before CRSR,
    -- running or expired included.
    local before = s_unit.count_down_entry_original
    if s_unit.count_down_entry_digits ~= nil and before ~= nil then
        s_unit.count_down_initial = before.initial
        s_unit.count_down_remaining = before.remaining
        s_unit.count_down_running = before.running
        s_unit.count_down_expired = before.expired
        s_unit.count_down_expired_elapsed = before.expired_elapsed
    end
    s_unit.count_down_entry_digits = nil
    s_unit.count_down_entry_original = nil
    s_unit.count_down_entry_position = nil
end

local function set_advisory(text, duration)
    s_unit.advisory_text = tostring(text or "")
    s_unit.advisory_until = s_unit.sim_clock + (duration or ADVISORY_DURATION_SEC)
end

local function clear_advisory()
    s_unit.advisory_text = nil
    s_unit.advisory_until = 0.0
end

local function determine_airborne()
    if s_config.debug_mode and s_unit.debug_airborne_override >= 0 then
        return s_unit.debug_airborne_override ~= 0
    end

    local radio_altitude = get_float(s_dr.radio_altitude, 0.0)
    local groundspeed = get_float(s_dr.groundspeed, 0.0)
    local vertical_speed = math.abs(get_float(s_dr.vertical_speed, 0.0))
    -- Height hysteresis: air above 1.0 m, back to the
    -- ground below 0.5 m, so a hover near 1 m does not flicker.
    local agl_limit = (s_unit.airborne_known and s_unit.airborne) and 0.5 or 1.0

    if s_dr.onground_any ~= nil then
        if get_int(s_dr.onground_any, 1) ~= 0 then return false end
        -- During an aircraft reload some aircraft briefly report no contact while
        -- still sitting at zero AGL. Require a second flight-state signal so a
        -- load transient cannot start ALT or the automatic flight timer.
        return radio_altitude > agl_limit
            or groundspeed > 15.0
            or (radio_altitude > 0.25 and vertical_speed > 100.0)
    end

    return radio_altitude > agl_limit or groundspeed > 15.0
end

local function reset_timer_state()
    -- first, so leaving an open entry cannot put the old count down back
    cancel_count_down_entry("timer reset")
    -- ACCUMULATE keeps adding on from flight to flight, so its flight time
    -- outlives a power off (and a reload: gtx327_pilot.ini); CLR zeroes it.
    if s_config.flight_timer_mode == FLIGHT_TIMER_MANUAL or s_config.flight_timer_mode == FLIGHT_TIMER_CLEAR then
        s_unit.flight_time = 0.0
    end
    s_unit.flight_timer_running = false
    s_unit.count_up_elapsed = 0.0
    s_unit.count_up_running = false
    s_unit.count_down_initial = s_config.countdown_default_seconds
    s_unit.count_down_remaining = s_config.countdown_default_seconds
    s_unit.count_down_expired_elapsed = 0.0
    s_unit.count_down_running = false
    s_unit.count_down_expired = false
end

-- IM table 4-1: POWER INPUT (pin 15) is the bus; AVIONICS MASTER ON (pin 1)
-- is a separate turn-on input (IM 1.2: the unit "can be configured" so the
-- avionics master turns it on). power_source = avionics: pin 1 on the
-- avionics switch; bus: pin 1 on the bus; keys (2): pin 1 not connected, so
-- only the STBY / ON / ALT keys turn the unit on.
local function master_bus_is_on()
    if s_config.debug_mode then return true end
    if get_float_array_value(s_dr.bus_volts, s_config.power_bus, 0.0) < 10.0 then return false end
    return s_config.power_source ~= 0 or get_int(s_dr.master_power, 0) ~= 0
end

local function cancel_code_entry(reason)
    s_unit.entry_digits = nil
    s_unit.entry_count = 0
    s_unit.entry_cursor_slot = nil
end

local function write_active_code(code)
    if not is_valid_squawk(code) then return false end
    s_unit.active_code = math.floor(code)
    set_int(s_dr.transponder_code, s_unit.active_code)
    return true
end

local function write_selected_mode(mode)
    local selected = math.floor(mode or 1)
    if selected < 1 or selected > 3 then return false end
    s_unit.selected_mode = selected
    set_int(s_dr.transponder_mode, selected)
    return true
end

local function handle_airborne_transition(airborne)
    s_unit.airborne = airborne

    if airborne then
        s_unit.ground_since = nil
        if s_config.flight_timer_mode == FLIGHT_TIMER_CLEAR then
            s_unit.flight_time = 0.0
        end
        if s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL then
            s_unit.flight_timer_running = true
        end
        if s_config.auto_standby_enabled and s_unit.power_state == POWER_OPERATING then
            write_selected_mode(3)
        end
    else
        s_unit.ground_since = s_unit.sim_clock
        if s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL then
            s_unit.flight_timer_running = false
        end
    end
end

-- Installation manual 5.1 note and 5.2.7.2: with AUTO STBY the unit annunciates
-- STBY on the ground whichever mode key is pressed. It counts as ground-borne
-- from power-up on the ground, or once it has been on the ground for the Delay
-- Time plus the rotorcraft air-state allowance after a landing.
local function auto_standby_holds()
    if not s_config.auto_standby_enabled or s_unit.airborne then return false end
    if s_unit.ground_since == nil then return true end
    local total_delay = s_config.ground_delay_seconds + s_config.air_state_delay
    return s_unit.sim_clock - s_unit.ground_since >= total_delay
end

local function update_airborne_state()
    -- Replay moves the aircraft through old positions; a lift-off or landing
    -- seen there is not one. After replay the aircraft is back where it was.
    if get_int(s_dr.replay, 0) ~= 0 then return end
    local airborne = determine_airborne()
    if not s_unit.airborne_known then
        s_unit.airborne_known = true
        s_unit.airborne = airborne
        s_unit.ground_since = nil
        s_unit.airborne_change_since = nil
        if s_unit.power_state == POWER_OPERATING then
            -- AUTO STBY selects ALT whenever the unit determines it is airborne,
            -- including a new flight that starts in the air (no lift-off seen).
            if airborne and s_config.auto_standby_enabled then
                write_selected_mode(3)
            end
            -- A relocation: the automatic flight timer runs in the air and
            -- stops on the ground, as at power-up; a new flight in the air
            -- starts CLEAR from zero, as a lift-off does.
            if s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL then
                s_unit.flight_timer_running = airborne
            end
            if airborne and s_config.flight_timer_mode == FLIGHT_TIMER_CLEAR then
                s_unit.flight_time = 0.0
            end
        end
    elseif airborne ~= s_unit.airborne then
        -- Debounce: a lift-off counts after 1 s in the air;
        -- a landing after the IM 5.2.7.2 air-state delay on the ground (1 s
        -- rotorcraft, 4.5 s others), timed from the touchdown, so a bounce or
        -- touch-and-go keeps the flight timer and ALT.
        -- The debug override is the settled state: no debounce.
        local since = s_unit.airborne_change_since
        if s_config.debug_mode and s_unit.debug_airborne_override >= 0 then
            s_unit.airborne_change_since = nil
            handle_airborne_transition(airborne)
        elseif since == nil then
            s_unit.airborne_change_since = s_unit.sim_clock
        elseif s_unit.sim_clock - since >= (airborne and 1.0 or s_config.air_state_delay) then
            s_unit.airborne_change_since = nil
            handle_airborne_transition(airborne)
            if not airborne then s_unit.ground_since = since end
        end
    else
        s_unit.airborne_change_since = nil
    end

    if not s_config.auto_standby_enabled or s_unit.power_state ~= POWER_OPERATING then return end

    if auto_standby_holds() and s_unit.selected_mode ~= 1 then
        write_selected_mode(1)
    end
end

-- A jump in total_running_time_sec (new situation)
-- counts as one real frame. A long frame at high time acceleration (16x at
-- 3 fps is over 5 s of sim time) is not a jump: the limit grows with it.
local function sim_step(real_dt)
    -- no total_running_time_sec (INSTALL line at start): real time, so the
    -- timers and IDENT still end
    if s_dr.run_time == nil then
        if get_int(s_dr.paused, 0) ~= 0 or get_int(s_dr.replay, 0) ~= 0 then return 0.0 end
        return clamp(real_dt, 0.0, 1.0)
    end
    local t = get_float(s_dr.run_time, 0.0)
    local d = 0.0
    if s_unit.last_run_time ~= nil and t > s_unit.last_run_time then
        d = t - s_unit.last_run_time
    end
    s_unit.last_run_time = t
    if get_int(s_dr.paused, 0) ~= 0 or get_int(s_dr.replay, 0) ~= 0 then return 0.0 end
    if d > math.max(5.0, clamp(real_dt, 0.0, 2.0) * 20.0) then d = clamp(real_dt, 0.0, 1.0) end
    return d
end

local function update_timers(dt)
    if s_unit.power_state ~= POWER_OPERATING then return end

    if s_unit.flight_timer_running then
        s_unit.flight_time = clamp(s_unit.flight_time + dt, 0.0, TIMER_MAX_SEC)
    end

    if s_unit.count_up_running then
        s_unit.count_up_elapsed = clamp(s_unit.count_up_elapsed + dt, 0.0, TIMER_MAX_SEC)
    end

    if s_unit.count_down_running then
        if s_unit.count_down_expired then
            s_unit.count_down_expired_elapsed = clamp(
                s_unit.count_down_expired_elapsed + dt,
                0.0,
                TIMER_MAX_SEC
            )
        else
            s_unit.count_down_remaining = s_unit.count_down_remaining - dt
            if s_unit.count_down_remaining <= 0.0 then
                s_unit.count_down_expired_elapsed = -s_unit.count_down_remaining
                s_unit.count_down_remaining = 0.0
                s_unit.count_down_expired = true
            end
        end
    end
end

local function update_display_theme(now)
    local r = get_float(s_dr.cockpit_light_r, 1.0)
    local g = get_float(s_dr.cockpit_light_g, r)
    local b = get_float(s_dr.cockpit_light_b, r)
    local scene_night = get_float(s_dr.scene_night_factor, -1.0)
    local ambient = scene_night >= 0.0
        and 1.0 - clamp(scene_night, 0.0, 1.0)
        or clamp((r + g + b) / 3.0, 0.0, 1.0)
    s_unit.ambient_light = ambient

    if s_unit.power_state == POWER_SELF_TEST then
        -- The real self-test is always the positive/day polarity, even when the
        -- photocell already sees darkness. Automatic inversion begins after it.
        s_unit.night_mode = false
        s_unit.theme_blend = 0.0
        s_unit.theme_last_update_time = now
        return
    end

    if s_config.display_mode == 1 then
        s_unit.night_mode = false
    elseif s_config.display_mode == 2 then
        s_unit.night_mode = true
    elseif s_unit.night_mode then
        -- capped just under full daylight, so LEVEL 93-99 can still return to day
        if ambient >= math.min(0.995, s_config.photo_sensor_threshold + 0.08) then
            s_unit.night_mode = false
        end
    elseif ambient <= s_config.photo_sensor_threshold then
        s_unit.night_mode = true
    end

    local last = s_unit.theme_last_update_time or now
    local dt = clamp(now - last, 0.0, 1.0)
    s_unit.theme_last_update_time = now
    local target = s_unit.night_mode and 1.0 or 0.0
    local step = THEME_TRANSITION_SEC > 0.0 and dt / THEME_TRANSITION_SEC or 1.0
    if s_unit.theme_blend < target then
        s_unit.theme_blend = math.min(target, s_unit.theme_blend + step)
    elseif s_unit.theme_blend > target then
        s_unit.theme_blend = math.max(target, s_unit.theme_blend - step)
    end
end

-- Installation manual 5.2.2 / 5.2.3. MAN: the pilot sets the level on the
-- DISPLAY page. AUTO: the level follows the photocell or the lighting bus
-- through SLOPE / OFFSET, never below MIN, and a bus at its minimum (daytime)
-- setting hands over to the photocell. key: the key lighting (5.2.3), which
-- runs in the same mode with its own level and parameters.
local function backlight_target(rheostat, photocell, key)
    if s_config.manual_display_page then return key and s_config.key_light_level or s_config.display_level end
    local source, slope, offset, minimum = s_config.backlight_source, s_config.backlight_slope,
        s_config.backlight_offset, s_config.backlight_min
    if key then
        source, slope, offset, minimum = s_config.key_light_source, s_config.key_light_slope,
            s_config.key_light_offset, s_config.key_light_min
    end
    local input = photocell
    if source == BACKLIGHT_BUS and rheostat > BACKLIGHT_BUS_MINIMUM then
        input = rheostat
    end
    return clamp((offset - 50.0) / 100.0 + slope / 50.0 * input, minimum / 99.0, 1.0)
end

-- The sky over the aircraft, 1 = clear.
-- X-Plane's ambient value does not see the weather (1.000 under the
-- Large-cell Storms preset), while its camera opens up under clouds and the
-- self-lit 3D screen glares (too bright by day, worst under
-- an overcast; the popup is fine). Each layer above the aircraft takes cover x
-- opacity (cirrus 0.15, stratus 0.75, cumulus 0.55, cumulonimbus 0.9; less for
-- thin layers), rain at the camera up to 35 % more, never below 0.2.
local update_backlight
do
    local OPACITY = { [0] = 0.15, 0.75, 0.55, 0.9 }
    -- the factory curve's floor (MIN 8) and the 3D screen's darkest
    local FACTORY_FLOOR, AMBIENT_MIN = 8.0 / 99.0, 0.002

    local function sky_factor()
        if s_config.backlight_cloud_dim <= 0.0 or s_dr.elevation == nil then return 1.0 end
        local ok, altitude = pcall(XPLMGetDatad or XPLMGetDataf, s_dr.elevation)
        altitude = ok and tonumber(altitude) or nil
        -- without the aircraft's height every layer would count as above it
        if altitude == nil then return 1.0 end
        local sky = 1.0
        for layer = 0, 2 do
            local cover = clamp(get_float_array_value(s_dr.cloud_cover, layer, 0.0), 0.0, 1.0)
            local top = get_float_array_value(s_dr.cloud_top, layer, 0.0)
            if cover > 0.01 and top > altitude then
                local kind = clamp(get_float_array_value(s_dr.cloud_type, layer, 0.0), 0.0, 3.0)
                local index = math.floor(kind)
                local opacity = OPACITY[index] + (OPACITY[math.min(3, index + 1)] - OPACITY[index]) * (kind - index)
                local thickness = top - math.max(get_float_array_value(s_dr.cloud_base, layer, 0.0), altitude)
                sky = sky * (1.0 - cover * opacity * clamp(0.35 + thickness / 1500.0, 0.0, 1.0))
            end
        end
        sky = sky * (1.0 - 0.35 * clamp(get_float(s_dr.rain, 0.0), 0.0, 1.0))
        return math.max(0.2, sky)
    end

    function update_backlight(now, rheostat)
        -- Screen photocell: X-Plane's own ambient brightness for the 3D screen
        -- (what the stock Garmins follow; it does not see clouds, see sky_factor
        -- above, so the clouds' dimming is the 3D screen's own). percent_lights_on
        -- stays the fallback until X-Plane has called the brightness callback.
        -- The popup uses it as it is; the 3D screen's is dimmed by the sky
        -- (backlight_cloud_dim: 0 off, 1 full), eased over about 3 s.
        local ambient = s_unit.xp_ambient or s_unit.ambient_light
        local target = backlight_target(rheostat, ambient)
        local dt = clamp(now - (s_unit.backlight_last_update_time or now), 0.0, 1.0)
        local sky = sky_factor()
        s_unit.sky = s_unit.sky == nil and sky or s_unit.sky + (sky - s_unit.sky) * math.min(1.0, dt / 3.0)
        local lit = ambient * s_unit.sky ^ s_config.backlight_cloud_dim
        -- The LCD is transflective: the brightness levels drive only the
        -- backlight, and daylight on the face still shows the cells. 0.04 of
        -- the ambient level: in full daylight a little under LEVEL 005, so
        -- 005-100 look as before; at night next to nothing. The 3D screen's
        -- daylight is dimmed by the sky like its backlight.
        s_unit.reflected = 0.04 * clamp(ambient, 0.0, 1.0)
        s_unit.reflected_3d = 0.04 * clamp(lit, 0.0, 1.0)
        local target_3d = backlight_target(rheostat, lit)
        if not s_config.manual_display_page
            and not (s_config.backlight_source == BACKLIGHT_BUS and rheostat > BACKLIGHT_BUS_MINIMUM)
        then
            -- On the photocell, X-Plane's ambient value is already the level
            -- a screen should show (SDK), returned as it is.
            -- The Garmin curve's own floor (MIN 8 = 0.08) made the 3D screen
            -- several times brighter than that at night, far too bright
            -- for an LCD. So the curve acts relative to its
            -- factory form: factory settings give X-Plane's value, a higher
            -- MIN or OFFSET a proportionally brighter screen.
            target_3d = clamp(math.max(lit, AMBIENT_MIN) * target_3d / clamp(lit, FACTORY_FLOOR, 1.0), AMBIENT_MIN, 1.0)
        end
        -- Key legends (warm white): the same curve on X-Plane's
        -- photocell, photo_auto_atten (measured: clear day 1.00,
        -- overcast 0.88, dusk 0.07, night 0.02, smooth in between). That level is
        -- the lamps' drive; what the eye sees is the glow against the daylight, so
        -- (1 - photocell) hides it in sunshine (the popup has no exposure, and
        -- X-Plane's left the 3D glow plain to see at noon), and the brightness goes
        -- as the cube root of the drive (Stevens): the factory MIN 8 shows at 0.43.
        local photocell = clamp(get_float(s_dr.photocell, s_unit.ambient_light), 0.0, 1.0)
        local key_drive = backlight_target(rheostat, photocell, true)
        local key_target = (1.0 - photocell) * key_drive ^ (1.0 / 3.0)
        local first = s_unit.backlight_last_update_time == nil
        s_unit.backlight_last_update_time = now
        -- The lag filters ambient changes; it is already settled when the unit
        -- powers on, so an unpowered unit simply tracks the target.
        if s_config.manual_display_page or first or s_unit.power_state == POWER_OFF then
            s_unit.backlight = target
            s_unit.backlight_3d = target_3d
            s_unit.key_drive = key_drive
            s_unit.key_light = key_target
            return
        end
        -- RSP TIME 3..7, higher is slower; factory 4. The manual gives no unit,
        -- so 4 is taken as a 1 s time constant and each step adds 0.5 s.
        local step = 1.0 - math.exp(-dt / ((s_config.backlight_response - 2) * 0.5))
        s_unit.backlight = s_unit.backlight + (target - s_unit.backlight) * step
        s_unit.backlight_3d = s_unit.backlight_3d + (target_3d - s_unit.backlight_3d) * step
        step = 1.0 - math.exp(-dt / ((s_config.key_light_response - 2) * 0.5))
        s_unit.key_drive = s_unit.key_drive + (key_drive - s_unit.key_drive) * step
        s_unit.key_light = s_unit.key_light + (key_target - s_unit.key_light) * step
    end
end

local function power_off(reason)
    cancel_code_entry("power off")
    cancel_count_down_entry("power off")
    clear_advisory()
    s_unit.post_entry_until = 0.0
    s_unit.self_test_until = 0.0
    s_unit.self_test_started_at = 0.0
    s_unit.self_test_failed = false
    s_unit.ident_until = 0.0
    s_unit.vfr_active = false
    s_unit.vfr_previous_code = nil
    s_unit.airborne_known = false
    s_unit.ground_since = nil
    s_unit.off_hold_active = false
    s_unit.off_hold_started_at = 0.0
    s_unit.shutdown_fade_started_at = 0.0
    s_unit.ident_stale = get_int(s_dr.transponder_ident, 0) ~= 0
    reset_timer_state()
    if s_unit.power_state == POWER_CONFIG then s_setup.exit() end
    s_unit.config_requested = false
    -- a FUNC release that never arrived must not start configuration mode
    s_unit.func_held = false
    s_unit.power_state = POWER_OFF
    set_int(s_dr.transponder_mode, 0)
end

local function begin_shutdown_hold()
    -- A second OFF press (two bindings, mouse and joystick) does not restart
    -- the hold, so its release cannot cancel a shutdown already fading.
    if s_unit.power_state == POWER_OFF or s_unit.off_hold_active then return end
    s_unit.off_hold_active = true
    s_unit.off_hold_started_at = now_seconds()
    s_unit.shutdown_fade_started_at = 0.0
end

local function release_shutdown_hold()
    if not s_unit.off_hold_active or s_unit.shutdown_fade_started_at > 0.0 then return end
    s_unit.off_hold_active = false
    s_unit.off_hold_started_at = 0.0
end

-- Real time: the hold measures the pilot's finger, so it works
-- while paused and is not shortened by time acceleration.
local function update_shutdown_hold(now)
    if not s_unit.off_hold_active then return end
    if s_unit.shutdown_fade_started_at <= 0.0
        and now - s_unit.off_hold_started_at >= OFF_HOLD_DURATION_SEC
    then
        s_unit.shutdown_fade_started_at = s_unit.off_hold_started_at + OFF_HOLD_DURATION_SEC
    end
    if s_unit.shutdown_fade_started_at > 0.0
        and now - s_unit.shutdown_fade_started_at >= OFF_FADE_DURATION_SEC
    then
        power_off("front-panel OFF held one second")
    end
end

local function begin_power_on(mode, reason, config)
    local requested = math.floor(mode or s_unit.selected_mode or 2)
    if requested < 1 or requested > 3 then requested = 2 end

    s_unit.config_requested = config == true
    s_unit.func_tapped_at = nil
    cancel_code_entry("power on")
    cancel_count_down_entry("power on")
    clear_advisory()
    reset_timer_state()
    s_unit.post_entry_until = 0.0
    s_unit.ident_until = 0.0
    s_unit.func_page = 0
    s_unit.requested_mode = requested
    s_unit.power_state = POWER_SELF_TEST
    -- Real time: a power-up while paused still reaches the
    -- pages, configuration mode included.
    s_unit.self_test_started_at = now_seconds()
    s_unit.self_test_until = s_unit.self_test_started_at + SELF_TEST_DURATION_SEC
    s_unit.self_test_failed = false
    s_unit.self_test_fault_seen = false
    -- an SPI X-Plane is still sending from before is not this power-up's IDENT
    s_unit.ident_stale = s_unit.ident_stale or get_int(s_dr.transponder_ident, 0) ~= 0
    s_unit.off_hold_active = false
    s_unit.off_hold_started_at = 0.0
    s_unit.shutdown_fade_started_at = 0.0
    s_unit.night_mode = false
    s_unit.theme_blend = 0.0
    s_unit.theme_last_update_time = s_unit.self_test_started_at
    -- The unit must not reply while the self-test page is visible.
    set_int(s_dr.transponder_mode, 1)
end

local XPLANE_FAILURE_ACTIVE = 6

local function complete_self_test()
    if s_unit.power_state ~= POWER_SELF_TEST or s_unit.self_test_failed then return end
    -- Pilot's guide: an internal failure found by the self test shows SELF TEST
    -- FAILED. The unit stays on that page (sim mode held at STBY) until it is
    -- powered off. A failure present at any time while the start-up page is
    -- shown is one the self test found; one that appears after the self test
    -- is left to X-Plane's own transponder model, which stops the replies (the
    -- pilot's guide names SELF TEST FAILED for the self test only).
    if s_unit.self_test_fault_seen or get_int(s_dr.transponder_failure, 0) == XPLANE_FAILURE_ACTIVE then
        s_unit.self_test_failed = true
        if s_unit.failure_noted then return end
        s_unit.failure_noted = true
        if get_int(s_dr.transponder_failure, 0) == XPLANE_FAILURE_ACTIVE then
            log("NOTE SELF TEST FAILED is shown because X-Plane's transponder failure (sim/operation/failures/rel_xpndr) is active; clear it in X-Plane's failures. Not a fault of the unit.")
        else
            log("NOTE SELF TEST FAILED is shown because X-Plane's transponder failure (sim/operation/failures/rel_xpndr) was active during the self test; it has cleared, so turn the unit off and on again. Not a fault of the unit.")
        end
        return
    end
    if s_unit.config_requested then
        -- the sim mode stays STBY (the mode sync holds it) until OFF
        s_unit.power_state = POWER_CONFIG
        s_setup.enter()
        return
    end
    s_unit.power_state = POWER_OPERATING
    s_unit.airborne = determine_airborne()
    s_unit.airborne_known = true
    s_unit.ground_since = nil
    s_unit.airborne_change_since = nil
    write_active_code(s_unit.active_code)
    -- The power key selects the first mode. AUTO STBY overrides it: STBY for
    -- a parked aircraft (installation manual 5.1 note), ALT when airborne.
    local first_mode = s_unit.requested_mode
    if s_config.auto_standby_enabled then
        first_mode = s_unit.airborne and 3 or (auto_standby_holds() and 1 or first_mode)
    end
    write_selected_mode(first_mode)
    -- MANUAL is pilot-controlled (IM 5.2.7.1); flight_timer_power_on_start=1
    -- imitates footage of a real unit and is opt-in. CLEAR and ACCUMULATE
    -- follow airborne determination as documented.
    if s_config.flight_timer_mode == FLIGHT_TIMER_MANUAL then
        s_unit.flight_timer_running = s_config.flight_timer_power_on_start
    else
        s_unit.flight_timer_running = s_unit.airborne
    end
end

local function select_mode(mode)
    cancel_code_entry("mode change")
    cancel_count_down_entry("mode change")
    s_unit.post_entry_until = 0.0
    s_unit.requested_mode = mode

    if s_unit.power_state == POWER_OFF then
        -- The keys power the unit on only when it has electrical power.
        if not master_bus_is_on() then
            return
        end
        -- IM 5.2: FUNC held while the power key is pressed. A mouse cannot
        -- hold two keys, so FUNC clicked first counts for 3 s (not Garmin).
        -- A hold older than 10 s is a release X-Plane never delivered.
        local now = now_seconds()
        local config = s_setup ~= nil
            and ((s_unit.func_held and now - s_unit.func_held_at <= 10.0)
                or (s_unit.func_tapped_at ~= nil and now - s_unit.func_tapped_at <= 3.0))
        begin_power_on(mode, "front-panel mode key", config)
    elseif s_unit.power_state == POWER_SELF_TEST then
    elseif auto_standby_holds() and mode ~= 1 then
    else
        write_selected_mode(mode)
    end
end

local function enter_code_digit(digit)
    if s_unit.power_state ~= POWER_OPERATING or digit < 0 or digit > 7 then return end

    if s_unit.entry_digits == nil then
        s_unit.entry_digits = {}
        s_unit.entry_count = 0
        s_unit.entry_cursor_slot = nil
        s_unit.post_entry_until = 0.0
    end

    local slot = math.min(s_unit.entry_count + 1, 4)
    s_unit.entry_digits[slot] = digit
    s_unit.entry_count = slot
    s_unit.entry_cursor_slot = slot < 4 and slot + 1 or nil
    if slot < 4 then return end

    local committed = code_from_digits(s_unit.entry_digits)
    s_unit.vfr_active = false
    s_unit.vfr_previous_code = nil
    write_active_code(committed)
    s_unit.entry_digits = nil
    s_unit.entry_count = 0
    s_unit.entry_cursor_slot = nil
    s_unit.post_entry_until = s_unit.sim_clock + POST_ENTRY_RECALL_SEC
end

local function activate_ident()
    if s_unit.power_state ~= POWER_OPERATING then return end

    -- Garmin documents every IDENT key press as a new 18-second activation.
    -- A repeated press therefore restarts the interval; it is not a toggle.
    -- Simulator time, as X-Plane's own transponder_id.
    s_unit.ident_until = s_unit.sim_clock + IDENT_DURATION_SEC
    s_unit.ident_stale = false
end

local function toggle_vfr()
    if s_unit.power_state ~= POWER_OPERATING then return end
    if not s_config.vfr_key_enabled then
        set_advisory("VFR Key Disabled", ADVISORY_DURATION_SEC)
        return
    end

    cancel_code_entry("VFR")
    cancel_count_down_entry("VFR")
    s_unit.post_entry_until = 0.0

    if s_unit.vfr_active then
        local previous = s_unit.vfr_previous_code
        s_unit.vfr_active = false
        s_unit.vfr_previous_code = nil
        if previous ~= nil and is_valid_squawk(previous) then
            write_active_code(previous)
        end
        return
    end

    s_unit.vfr_previous_code = s_unit.active_code
    s_unit.vfr_active = true
    write_active_code(s_config.vfr_code)
end

local function begin_count_down_entry()
    if s_unit.power_state ~= POWER_OPERATING or s_unit.func_page ~= 3 then return end
    if s_unit.count_down_entry_digits ~= nil then
        cancel_count_down_entry("CRSR")
        return
    end

    s_unit.count_down_entry_original = {
        initial = s_unit.count_down_initial,
        remaining = s_unit.count_down_remaining,
        running = s_unit.count_down_running,
        expired = s_unit.count_down_expired,
        expired_elapsed = s_unit.count_down_expired_elapsed,
        -- what CLR puts back when it cancels a keypress
        digits = timer_digits_from_seconds(s_unit.count_down_initial),
    }
    s_unit.count_down_entry_digits = timer_digits_from_seconds(s_unit.count_down_initial)
    s_unit.count_down_entry_position = 1
    s_unit.count_down_running = false
    s_unit.count_down_expired = false
    s_unit.count_down_expired_elapsed = 0.0
end

local function inject_count_down_entry(finish_entry)
    local digits = s_unit.count_down_entry_digits
    if digits == nil then return nil end
    local seconds = timer_seconds_from_digits(digits)
    s_unit.count_down_initial = seconds
    s_unit.count_down_remaining = seconds
    s_unit.count_down_expired_elapsed = 0.0
    s_unit.count_down_running = false
    s_unit.count_down_expired = false
    if finish_entry then
        s_unit.count_down_entry_digits = nil
        s_unit.count_down_entry_original = nil
        s_unit.count_down_entry_position = nil
    end
    return seconds
end

local function enter_count_down_digit(digit)
    local digits = s_unit.count_down_entry_digits
    if digits == nil or digit < 0 or digit > 9 then return false end

    local position = math.floor(s_unit.count_down_entry_position or 1)
    if (position == 3 or position == 5) and digit > 5 then
        return true
    end

    digits[position] = digit
    if position < 6 then
        s_unit.count_down_entry_position = position + 1
        return true
    end

    -- PG p7 "All digits must be entered": the time is set by the sixth
    -- digit. Any other way out of the entry keeps the old time,
    -- so the digits are not written into it before.
    inject_count_down_entry(true)
    return true
end

local function clear_count_down_entry_digit()
    local digits = s_unit.count_down_entry_digits
    if digits == nil then return false end
    local position = math.floor(s_unit.count_down_entry_position or 1)
    if position <= 1 then
        -- No previous keypress left to cancel: a real unit clears the time
        -- to 00:00:00 and leaves the entry (seen in a
        -- video of a real unit).
        s_unit.count_down_initial = 0.0
        s_unit.count_down_remaining = 0.0
        s_unit.count_down_expired_elapsed = 0.0
        s_unit.count_down_running = false
        s_unit.count_down_expired = false
        s_unit.count_down_entry_original = nil
        cancel_count_down_entry("CLR at first digit; cleared to 00:00:00")
    else
        -- Pilot's guide: CLR cancels the previous keypress, so that digit
        -- shows what it was before the entry again.
        local before = s_unit.count_down_entry_original
        if before ~= nil and before.digits ~= nil then
            digits[position - 1] = before.digits[position - 1]
        end
        s_unit.count_down_entry_position = position - 1
    end
    return true
end

local function toggle_current_timer()
    if s_unit.power_state ~= POWER_OPERATING then return end

    if s_unit.func_page == 1 then
        -- Pilot's guide Timer Operation step 3 applies to every FLT TMR mode:
        -- START/STOP pauses or restarts the timer; automation only acts on
        -- lift-off and touchdown transitions.
        s_unit.flight_timer_running = not s_unit.flight_timer_running
    elseif s_unit.func_page == 2 then
        s_unit.count_up_running = not s_unit.count_up_running
    elseif s_unit.func_page == 3 then
        -- START waits for all six digits.
        if s_unit.count_down_entry_digits ~= nil then return end
        if not s_unit.count_down_expired and s_unit.count_down_remaining <= 0.0 then
            s_unit.count_down_remaining = s_unit.count_down_initial
        end
        if s_unit.count_down_remaining <= 0.0 and not s_unit.count_down_expired then
            return
        end
        s_unit.count_down_running = not s_unit.count_down_running
    end
end

local function clear_code_entry()
    if s_unit.power_state ~= POWER_OPERATING then return end

    if s_unit.entry_digits ~= nil then
        -- Pilot's guide: CLR moves the cursor back to the previous digit; CLR
        -- with the cursor already on the first digit cancels the entry. One
        -- entered digit therefore takes two CLR presses to cancel.
        if s_unit.entry_count <= 0 then
            cancel_code_entry("CLR at first digit")
        else
            s_unit.entry_count = s_unit.entry_count - 1
            for slot = s_unit.entry_count + 1, 4 do
                s_unit.entry_digits[slot] = nil
            end
            s_unit.entry_cursor_slot = s_unit.entry_count + 1
        end
        return
    end

    if s_unit.post_entry_until > 0.0 and s_unit.sim_clock <= s_unit.post_entry_until then
        local digits = digits_from_code(s_unit.active_code)
        s_unit.entry_digits = { digits[1], digits[2], digits[3], digits[4] }
        s_unit.entry_count = 3
        s_unit.entry_cursor_slot = 4
        s_unit.post_entry_until = 0.0
    end
end

local function clear_current_context()
    if s_unit.power_state ~= POWER_OPERATING then return end

    if s_unit.advisory_text ~= nil then
        clear_advisory()
        return
    end
    if clear_count_down_entry_digit() then return end

    if s_unit.entry_digits ~= nil
        or (s_unit.post_entry_until > 0.0 and s_unit.sim_clock <= s_unit.post_entry_until)
    then
        clear_code_entry()
        return
    end

    -- Pilot's guide: CLR resets the timer (to zero, or Count Down to its
    -- initial time). It does not stop it; START/STOP owns the run state.
    if s_unit.func_page == 1 then
        s_unit.flight_time = 0.0
    elseif s_unit.func_page == 2 then
        s_unit.count_up_elapsed = 0.0
    elseif s_unit.func_page == 3 then
        s_unit.count_down_remaining = s_unit.count_down_initial
        s_unit.count_down_expired_elapsed = 0.0
        s_unit.count_down_expired = false
        if s_unit.count_down_initial <= 0.0 then s_unit.count_down_running = false end
    end
end

local function initialize_unit_state()
    local native_code = get_int(s_dr.transponder_code, 1200)
    local native_mode = get_int(s_dr.transponder_mode, 2)
    if is_valid_squawk(native_code) then s_unit.active_code = native_code end
    -- Pilot's guide: the unit powers on with the last active code, its own
    -- memory (gtx327_pilot.ini) where it has one, over the aircraft's.
    -- X-Plane gets it when Enable succeeds (XPluginEnable).
    if s_setup ~= nil and type(s_setup.pilot_code) == "function" then
        s_unit.active_code = s_setup.pilot_code(s_unit.active_code)
    end
    s_unit.code_to_sim = s_unit.active_code ~= native_code
    if native_mode >= 1 and native_mode <= 3 then
        s_unit.selected_mode = native_mode
        s_unit.requested_mode = native_mode
    end

    s_unit.power_state = POWER_OFF
    cancel_code_entry("initialization")
    s_unit.ident_until = 0.0
    s_unit.vfr_active = false
    s_unit.vfr_previous_code = nil
    s_unit.func_page = 0
    clear_advisory()
    s_unit.airborne_known = false
    s_unit.airborne = false
    s_unit.ground_since = nil
    s_unit.airborne_change_since = nil
    s_unit.off_hold_active = false
    s_unit.off_hold_started_at = 0.0
    s_unit.shutdown_fade_started_at = 0.0
    s_unit.night_mode = false
    s_unit.theme_blend = 0.0
    s_unit.theme_last_update_time = now_seconds()
    s_unit.pressed_button_identifier = 0
    s_unit.last_touch_identifier = 0
    reset_timer_state()
    if s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL and s_config.flight_timer_mode ~= FLIGHT_TIMER_CLEAR
        and s_setup ~= nil and type(s_setup.pilot_flight_time) == "function"
    then
        s_unit.flight_time = s_setup.pilot_flight_time()
    end
    s_unit.flight_saved = s_unit.flight_time
    s_unit.last_bus_power = false
    s_unit.initialized = true
end

local function update_unit_state()
    if not s_unit.initialized then initialize_unit_state() end

    local now = now_seconds()
    local sim_dt = sim_step(now - (s_unit.last_real_time or now))
    s_unit.last_real_time = now
    s_unit.sim_clock = s_unit.sim_clock + sim_dt
    local bus_power = master_bus_is_on()
    if bus_power and not s_unit.last_bus_power and s_unit.power_state == POWER_OFF
        and (s_config.power_source ~= 2 or s_config.debug_mode)
    then
        -- Bus power starts the unit in the mode it was last in (ON the first
        -- time), as a mode knob would stay where it was left: the Garmin
        -- manuals name no first mode for a master-switch start, and the unit
        -- keeps its code and settings through a power off. AUTO STBY then
        -- picks STBY or ALT at the end of the self test. Not with
        -- power_source = keys (pin 1 not connected).
        local first_mode = 2
        if s_setup ~= nil and type(s_setup.pilot_mode) == "function" then first_mode = s_setup.pilot_mode() end
        begin_power_on(first_mode, "avionics master")
    elseif not bus_power and s_unit.last_bus_power and s_unit.power_state ~= POWER_OFF then
        power_off("avionics master")
    end
    s_unit.last_bus_power = bus_power

    -- IM 1.5.3 Maximum Quiescent current: 0.50 A at 27.5 V, 0.90 A at 13.75 V,
    -- in between by bus voltage. X-Plane keeps plugin_bus_load_amps and other
    -- plugins add to it, so only the change in this unit's share is written.
    local volts = get_float_array_value(s_dr.bus_volts, s_config.power_bus, 0.0)
    -- An avionics master that is on while the unit's bus is dead: a battery
    -- left off, or the unit wired to another bus (power_bus). Said once, and
    -- only if that bus was never live this load: losing it later is a crash,
    -- a failure or a flat battery, not the installation.
    if volts >= 10.0 then s_unit.dead_bus_noted = true end
    if not s_unit.dead_bus_noted and not s_config.debug_mode and s_config.power_source == 0
        and volts < 10.0 and get_int(s_dr.master_power, 0) ~= 0
    then
        s_unit.dead_bus_noted = true
        log(string.format("NOTE avionics master on, bus %d at %.1f V: the unit stays off until that bus has 10 V."
            .. " Battery off, or does the aircraft feed its avionics from another bus? Set [Power] power_bus.",
            s_config.power_bus, volts))
    end
    local amps = 0.0
    if s_unit.power_state ~= POWER_OFF and volts >= 10.0 then
        amps = 0.90 - (clamp(volts, 13.75, 27.5) - 13.75) * (0.90 - 0.50) / (27.5 - 13.75)
    end
    if s_dr.bus_load ~= nil and math.abs(amps - s_unit.bus_load_amps) >= 0.01 then
        -- no write after a failed read: it would wipe the other plugins' load
        local load = get_float_array_value(s_dr.bus_load, s_config.power_bus, nil)
        if load ~= nil and pcall(XPLMSetDatavf, s_dr.bus_load, { math.max(0.0, load - s_unit.bus_load_amps + amps) }, s_config.power_bus, 1) then
            s_unit.bus_load_amps = amps
        end
    end

    update_shutdown_hold(now)

    if s_unit.power_state == POWER_SELF_TEST then
        if get_int(s_dr.transponder_failure, 0) == XPLANE_FAILURE_ACTIVE then s_unit.self_test_fault_seen = true end
        if now >= s_unit.self_test_until then complete_self_test() end
    end
    -- X-Plane's SPI from before a power off or on has ended
    if s_unit.ident_stale and get_int(s_dr.transponder_ident, 0) == 0 then s_unit.ident_stale = false end

    -- Simulator time, as the flight timers
    local sim_now = s_unit.sim_clock
    if s_unit.post_entry_until > 0.0 and sim_now > s_unit.post_entry_until then
        s_unit.post_entry_until = 0.0
    end

    if s_unit.ident_until > 0.0 and sim_now > s_unit.ident_until then
        s_unit.ident_until = 0.0
    end

    if s_unit.advisory_until > 0.0 and sim_now > s_unit.advisory_until then
        clear_advisory()
    end

    update_airborne_state()
    update_timers(sim_dt)
    update_display_theme(now)
    update_backlight(now, clamp(get_float_array_value(s_dr.instrument_brightness, s_config.lighting_dimmer, 1.0), 0.0, 1.0))
    if s_setup ~= nil then
        -- the mode the unit is in, while it is on; the ACCUMULATE flight time
        -- when it stops, after a CLR, and once a minute while it runs (so a
        -- crash in flight loses at most about a minute, and the disk is not
        -- written every second; the script's stop writes the exact time);
        -- zero in the other timer modes
        local flight = 0.0
        if s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL and s_config.flight_timer_mode ~= FLIGHT_TIMER_CLEAR then
            if not s_unit.flight_timer_running or s_unit.flight_time < s_unit.flight_saved
                or s_unit.flight_time - s_unit.flight_saved >= 60.0
            then
                s_unit.flight_saved = s_unit.flight_time
            end
            flight = s_unit.flight_saved
        end
        s_setup.pilot_tick(now, s_unit.active_code,
            s_unit.power_state == POWER_OPERATING and s_unit.selected_mode or nil, flight)
    end

    -- The unit owns the simulator mode. X-Plane commands this unit does not
    -- intercept (mode up/down, TEST, GND, TA/RA) and raw dataref writes must not
    -- leave the simulator replying while the display says otherwise.
    local native_mode = get_int(s_dr.transponder_mode, -1)
    if s_unit.power_state == POWER_OFF then
        if native_mode ~= 0 then set_int(s_dr.transponder_mode, 0) end
    elseif s_unit.power_state == POWER_SELF_TEST or s_unit.power_state == POWER_CONFIG then
        if native_mode ~= 1 then set_int(s_dr.transponder_mode, 1) end
    elseif native_mode ~= s_unit.selected_mode then
        -- An external STBY/ON/ALT (hardware writing the dataref) is adopted
        -- whenever the same key would be (AUTO STBY refuses ON / ALT only
        -- while it holds STBY on the ground); anything else is written back.
        if not auto_standby_holds() and native_mode >= 1 and native_mode <= 3 then
            s_unit.selected_mode = native_mode
        else
            set_int(s_dr.transponder_mode, s_unit.selected_mode)
        end
    end

    -- Follow legitimate simulator-side code changes when the front panel is
    -- idle, also while off or self-testing: the unit keeps the last code and
    -- the end of the self test writes it back. A code the unit cannot
    -- produce (an 8 or 9, or out of range: the keys are 0-7) is written back.
    -- Not before Enable has put the unit's own code into X-Plane.
    local native_code = get_int(s_dr.transponder_code, s_unit.active_code)
    if native_code ~= s_unit.active_code and not s_unit.code_to_sim then
        if not is_valid_squawk(native_code) then
            set_int(s_dr.transponder_code, s_unit.active_code)
            if not s_unit.invalid_code_noted then
                s_unit.invalid_code_noted = true
                log(string.format("NOTE X-Plane's transponder code was set to %d from outside (another script or"
                    .. " panel); the unit has only the 0-7 keys and keeps %04d. Logged once per load.",
                    native_code, s_unit.active_code))
            end
        elseif s_unit.entry_digits == nil then
            s_unit.active_code = native_code
            s_unit.vfr_active = false
            s_unit.vfr_previous_code = nil
        end
    end
end

local function find_input_dataref(key, name)
    local handle = XPLMFindDataRef(name)
    s_dr[key] = handle
    if handle == nil then log("INSTALL X-Plane dataref " .. name .. " not found: X-Plane older than 12.4.4? Otherwise report a BUG on GitHub.") end
end

local function find_input_datarefs()
    -- Power: bus_volts[power_bus], plus the avionics switch for power_source =
    -- avionics (gtx327_config.ini); the unit's current goes on that bus.
    find_input_dataref("master_power", "sim/cockpit2/switches/avionics_power_on")
    find_input_dataref("bus_volts", "sim/cockpit2/electrical/bus_volts")
    find_input_dataref("bus_load", "sim/cockpit2/electrical/plugin_bus_load_amps")
    -- The panel dimmer writes this switches array; the electrical array of the
    -- same name can stay at full scale (seen in a test aircraft).
    find_input_dataref("instrument_brightness", "sim/cockpit2/switches/instrument_brightness_ratio")
    -- The key lights' photocell (update_backlight).
    find_input_dataref("photocell", "sim/graphics/misc/photo_auto_atten")
    -- The sky over the aircraft (the 3D screen's backlight, update_backlight).
    find_input_dataref("elevation", "sim/flightmodel/position/elevation")
    find_input_dataref("cloud_cover", "sim/weather/aircraft/cloud_coverage_percent")
    find_input_dataref("cloud_type", "sim/weather/aircraft/cloud_type")
    find_input_dataref("cloud_base", "sim/weather/aircraft/cloud_base_msl_m")
    find_input_dataref("cloud_top", "sim/weather/aircraft/cloud_tops_msl_m")
    find_input_dataref("rain", "sim/weather/view/rain_ratio")

    find_input_dataref("transponder_code", "sim/cockpit2/radios/actuators/transponder_code")
    find_input_dataref("transponder_mode", "sim/cockpit2/radios/actuators/transponder_mode")
    find_input_dataref("transponder_ident", "sim/cockpit2/radios/indicators/transponder_id")
    find_input_dataref("transponder_reply", "sim/cockpit/radios/transponder_light")
    find_input_dataref("pressure_altitude", "sim/flightmodel2/position/pressure_altitude")
    find_input_dataref("onground_any", "sim/flightmodel/failures/onground_any")
    find_input_dataref("groundspeed", "sim/flightmodel/position/groundspeed")
    find_input_dataref("radio_altitude", "sim/flightmodel/position/y_agl")
    find_input_dataref("vertical_speed", "sim/flightmodel/position/vh_ind_fpm")
    find_input_dataref("scene_night_factor", "sim/graphics/scenery/percent_lights_on")
    find_input_dataref("cockpit_light_r", "sim/graphics/misc/cockpit_light_level_r")
    find_input_dataref("cockpit_light_g", "sim/graphics/misc/cockpit_light_level_g")
    find_input_dataref("cockpit_light_b", "sim/graphics/misc/cockpit_light_level_b")
    find_input_dataref("transponder_failure", "sim/operation/failures/rel_xpndr")
    find_input_dataref("static_failure", "sim/operation/failures/rel_static")
    find_input_dataref("run_time", "sim/time/total_running_time_sec")
    find_input_dataref("paused", "sim/time/paused")
    find_input_dataref("replay", "sim/time/is_in_replay")

end

local function update_render_state()
    update_unit_state()
    local now = now_seconds()
    s_render.debug_mode = s_config.debug_mode and 1 or 0
    s_render.power_state = s_unit.power_state
    s_render.powered = s_unit.power_state ~= POWER_OFF
    s_render.self_test_text_visible = s_unit.power_state == POWER_SELF_TEST
        and now - s_unit.self_test_started_at >= SELF_TEST_BLANK_SEC
    s_render.self_test_failed = s_unit.self_test_failed

    -- The rheostat reaches the display only through the backlight model
    -- (BKLT SRCE = bus). The key legends (the popup's _LIT overlay and the 3D
    -- unit's ATTR_light_level, laminar/gtx327/key_light) are the unit's own
    -- lamps, dark with the unit off.
    s_render.instrument_brightness = clamp(
        get_float_array_value(s_dr.instrument_brightness, s_config.lighting_dimmer, 1.0),
        0.0,
        1.0
    )
    s_render.contrast_level = s_config.contrast_level
    s_render.display_level = s_config.display_level
    local backlight = clamp(PLUGIN_MASTER_BRIGHTNESS * s_unit.backlight, 0.0, 1.0)
    s_render.bezel_lit_alpha = s_render.powered and clamp(s_unit.key_light, 0.0, 1.0) or 0.0
    -- The popup face is grey, never the cockpit flood's colour:
    -- as dark as X-Plane's own 430 / 530 popups by day, dark but still
    -- visible at night.
    s_render.bezel_shade = POPUP_NIGHT_SHADE + (POPUP_DAY_SHADE - POPUP_NIGHT_SHADE) * clamp(s_unit.ambient_light or 1.0, 0.0, 1.0)
    -- the backlight, or the daylight on the face where that shows more
    s_render.effective_brightness = s_render.powered and math.max(backlight, s_unit.reflected) or 0.0
    -- The 3D screen at 0.85: a little darker, nearer other 3D panel screens.
    -- A brighter OBJ (2000 nits) made it brighter instead.
    s_render.effective_brightness_3d = s_render.powered
        and clamp(0.85 * PLUGIN_MASTER_BRIGHTNESS * math.max(s_unit.backlight_3d, s_unit.reflected_3d), 0.0, 1.0) or 0.0

    s_render.code = s_unit.active_code
    s_render.code_text = code_display_text()
    s_render.code_entry_active = s_unit.entry_digits ~= nil
    s_render.code_entry_count = s_unit.entry_digits ~= nil and s_unit.entry_count or 0
    s_render.code_entry_cursor_slot = s_unit.entry_cursor_slot or 0
    s_render.mode = s_unit.selected_mode
    s_render.mode_text = MODE_LABELS[s_render.mode] or ""
    -- IDENT shows until both the unit's 18 s and X-Plane's transponder_id
    -- have ended (both simulator time). X-Plane keeps an SPI running through
    -- a power off; one from before this power-up is not shown.
    s_render.ident = s_render.power_state == POWER_OPERATING
        and (s_unit.ident_until > s_unit.sim_clock
            or (not s_unit.ident_stale and get_int(s_dr.transponder_ident, 0) ~= 0))
    -- X-Plane blinks transponder_light in STBY as well; STBY never replies
    -- (pilot's guide), so the symbol is limited to ON and ALT.
    s_render.reply = s_render.power_state == POWER_OPERATING
        and s_unit.selected_mode >= 2
        and get_int(s_dr.transponder_reply, 0) ~= 0
    -- The encoder is plumbed to the static system: with the static port blocked
    -- (rel_static = 6) it keeps the last reading until the failure is cleared.
    if not (s_render.pressure_altitude_valid
            and get_int(s_dr.static_failure, 0) == XPLANE_FAILURE_ACTIVE) then
        -- pressure_altitude is a double dataref; XPLMGetDataf reads it as a float.
        s_render.pressure_altitude = get_float(s_dr.pressure_altitude, s_render.pressure_altitude)
    end
    s_render.pressure_altitude_valid = s_dr.pressure_altitude ~= nil
    -- The unit shows what its encoder reports: Mode C 100 ft increments from
    -- -1000 to 62,700 ft (installation manual 1.4). Gray-code encoders change
    -- state 50 ft either side of each hundred, so round to the nearest one.
    local encoded = clamp(
        math.floor(s_render.pressure_altitude / 100.0 + 0.5) * 100,
        ENCODER_MIN_FT,
        ENCODER_MAX_FT
    )
    if s_config.altitude_format == ALTITUDE_FORMAT_FEET then
        s_render.pressure_prefix = ""
        s_render.pressure_value = string.format("%d", encoded)
        s_render.pressure_suffix = "ft"
    elseif s_config.altitude_format == ALTITUDE_FORMAT_METERS then
        s_render.pressure_prefix = ""
        s_render.pressure_value = string.format("%d", math.floor(encoded * 0.3048 + 0.5))
        s_render.pressure_suffix = "m"
    else
        s_render.pressure_prefix = "FL"
        s_render.pressure_value = string.format("%03d", encoded / 100)
        s_render.pressure_suffix = ""
    end

    local vertical_speed = get_float(s_dr.vertical_speed, 0.0)
    local vertical_sign = vertical_speed >= 0.0 and 1 or -1
    local vertical_magnitude = math.abs(vertical_speed)
    -- The arrow shows the altitude increasing or decreasing (pilot's guide,
    -- Altitude Trend Indicator): with the static port blocked the encoder
    -- altitude above is frozen, so there is no trend to show.
    -- Small arrow from VS RATE, large from twice it. The Garmin manuals give
    -- no hysteresis; one is added so a rate hovering at a threshold does not
    -- make the arrow flicker: an arrow shown stays until the rate falls below
    -- 80 % of the threshold that brought it. Arrows still come at once.
    local rate = s_config.altitude_trend_fpm
    if get_int(s_dr.static_failure, 0) == XPLANE_FAILURE_ACTIVE or rate <= 0.0 then
        s_render.altitude_trend = 0
    else
        local shown = s_render.altitude_trend
        local held = (shown * vertical_sign > 0) and math.abs(shown) or 0
        if vertical_magnitude >= rate * 2.0 or (held == 2 and vertical_magnitude >= rate * 1.6) then
            s_render.altitude_trend = vertical_sign * 2
        elseif vertical_magnitude >= rate or (held >= 1 and vertical_magnitude >= rate * 0.8) then
            s_render.altitude_trend = vertical_sign
        else
            s_render.altitude_trend = 0
        end
    end

    s_render.airborne = s_unit.airborne
    s_render.flight_time = s_unit.flight_time
    s_render.flight_timer_running = s_unit.flight_timer_running
    s_render.count_up_elapsed = s_unit.count_up_elapsed
    s_render.count_up_running = s_unit.count_up_running
    s_render.count_down_initial = s_unit.count_down_initial
    s_render.count_down_running = s_unit.count_down_running
    s_render.count_down_expired = s_unit.count_down_expired
    -- Count Down rounds up: 10:00 stays 10:00 for its
    -- first second and reaches 00:00:00 as it expires.
    s_render.count_down_value = s_unit.count_down_expired
        and s_unit.count_down_expired_elapsed or math.ceil(s_unit.count_down_remaining - 1e-6)
    s_render.count_down_entry_text = timer_entry_display_text()
    s_render.count_down_entry_active = s_unit.count_down_entry_digits ~= nil
    s_render.count_down_entry_count = s_unit.count_down_entry_digits ~= nil
        and (s_unit.count_down_entry_position or 1) - 1 or 0
    s_render.count_down_entry_cursor_position = s_unit.count_down_entry_position or 0
    s_render.expired_visible = math.floor(now * EXPIRED_BLINK_HZ) % 2 == 0
    s_render.advisory_text = s_unit.advisory_text
    s_render.shutdown_message = s_unit.off_hold_active
    s_render.shutdown_fade = s_unit.shutdown_fade_started_at > 0.0
        and clamp((now - s_unit.shutdown_fade_started_at) / OFF_FADE_DURATION_SEC, 0.0, 1.0)
        or 0.0
    s_render.ambient_light = s_unit.ambient_light
    s_render.theme_blend = s_unit.theme_blend
    s_render.page = s_unit.func_page
    s_render.setup_items = s_unit.power_state == POWER_CONFIG and s_setup.items(s_unit.backlight, s_unit.key_drive) or nil
    s_render.heartbeat = s_heartbeat
end

-- 1 while the unit runs: a Plane Maker hide dataref for the instrument the
-- GTX replaces (the stock unit comes back if this script is not running).
s_diag_read.installed = function(refcon)
    return s_xlua_loaded
end

s_diag_read.debug_mode = function(refcon)
    return s_config.debug_mode and 1 or 0
end

s_diag_read.xlua_loaded = function(refcon)
    return s_xlua_loaded
end

s_diag_read.xlua_heartbeat = function(refcon)
    return s_heartbeat
end

s_diag_read.popup_alive = function(refcon)
    return (s_device_popup ~= nil and (s_popup_seen_visible or s_popup_grace_frames > 0)) and 1 or 0
end

s_diag_read.avionics_alive = function(refcon)
    return s_device_3d ~= nil and 1 or 0
end

s_diag_read.baseline_version = function(refcon)
    return BASELINE_VERSION
end

s_diag_read.raster_pipeline = function(refcon)
    return s_raster ~= nil and RASTER_PIPELINE_REVISION or 0
end

s_diag_read.unit_powered = function(refcon)
    return s_unit.power_state ~= POWER_OFF and 1 or 0
end

s_diag_read.power_state = function(refcon)
    return s_unit.power_state
end

s_diag_read.active_code = function(refcon)
    return s_unit.active_code
end

s_diag_read.selected_mode = function(refcon)
    return s_unit.selected_mode
end

s_diag_read.code_entry_digits = function(refcon)
    return s_unit.entry_digits ~= nil and s_unit.entry_count or 0
end

s_diag_read.code_display = function(refcon)
    return tonumber((string.gsub(code_display_text(), "%-", "0"))) or s_unit.active_code
end

s_diag_read.code_entry_cursor_slot = function(refcon)
    return s_unit.entry_cursor_slot or 0
end

s_diag_read.ident_active = function(refcon)
    return s_unit.power_state == POWER_OPERATING
        and s_unit.ident_until > s_unit.sim_clock and 1 or 0
end

s_diag_read.vfr_active = function(refcon)
    return s_unit.vfr_active and 1 or 0
end

s_diag_read.vfr_code = function(refcon)
    return s_config.vfr_code
end

s_diag_read.func_page = function(refcon)
    return s_unit.func_page
end

s_diag_read.requested_mode = function(refcon)
    return s_unit.requested_mode
end

s_diag_read.auto_standby = function(refcon)
    return s_config.auto_standby_enabled and 1 or 0
end

s_diag_read.airborne = function(refcon)
    return s_unit.airborne and 1 or 0
end

s_diag_read.debug_airborne_override = function(refcon)
    return s_unit.debug_airborne_override
end

s_diag_read.ground_delay_remaining = function(refcon)
    if s_unit.airborne or s_unit.ground_since == nil then return 0 end
    local total = s_config.ground_delay_seconds + s_config.air_state_delay
    return math.max(0, math.ceil(total - (s_unit.sim_clock - s_unit.ground_since)))
end

s_diag_read.flight_timer_mode = function(refcon)
    return s_config.flight_timer_mode
end

s_diag_read.flight_time_sec = function(refcon)
    return math.floor(s_unit.flight_time)
end

s_diag_read.flight_timer_running = function(refcon)
    return s_unit.flight_timer_running and 1 or 0
end

s_diag_read.count_up_sec = function(refcon)
    return math.floor(s_unit.count_up_elapsed)
end

s_diag_read.count_up_running = function(refcon)
    return s_unit.count_up_running and 1 or 0
end

s_diag_read.count_down_sec = function(refcon)
    if s_unit.count_down_expired then return math.floor(s_unit.count_down_expired_elapsed) end
    return math.max(0, math.ceil(s_unit.count_down_remaining - 1e-6))
end

s_diag_read.count_down_initial_sec = function(refcon)
    return math.floor(s_unit.count_down_initial)
end

s_diag_read.count_down_running = function(refcon)
    return s_unit.count_down_running and 1 or 0
end

s_diag_read.count_down_expired = function(refcon)
    return s_unit.count_down_expired and 1 or 0
end

s_diag_read.count_down_entry_digits = function(refcon)
    return s_unit.count_down_entry_digits ~= nil
        and (s_unit.count_down_entry_position or 1) - 1 or 0
end

s_diag_read.count_down_entry_cursor_position = function(refcon)
    return s_unit.count_down_entry_position or 0
end

s_diag_read.altitude_trend = function(refcon)
    return s_render.altitude_trend
end

s_diag_read.contrast_percent = function(refcon)
    return math.floor(clamp(s_config.contrast_level, 0.0, 1.0) * 100.0 + 0.5)
end

s_diag_read.display_percent = function(refcon)
    return math.floor(clamp(s_config.display_level, 0.0, 1.0) * 100.0 + 0.5)
end

s_diag_read.altitude_trend_threshold_fpm = function(refcon)
    return math.floor(s_config.altitude_trend_fpm + 0.5)
end

s_diag_read.advisory_active = function(refcon)
    return s_unit.advisory_text ~= nil and 1 or 0
end

s_diag_read.self_test_failed = function(refcon)
    return s_unit.self_test_failed and 1 or 0
end

s_diag_read.self_test_text_visible = function(refcon)
    return s_unit.power_state == POWER_SELF_TEST
        and now_seconds() - s_unit.self_test_started_at >= SELF_TEST_BLANK_SEC and 1 or 0
end

s_diag_read.shutdown_hold = function(refcon)
    return s_unit.off_hold_active and 1 or 0
end

s_diag_read.shutdown_fade_percent = function(refcon)
    if s_unit.shutdown_fade_started_at <= 0.0 then return 0 end
    return math.floor(clamp(
        (now_seconds() - s_unit.shutdown_fade_started_at) / OFF_FADE_DURATION_SEC,
        0.0,
        1.0
    ) * 100.0)
end

s_diag_read.night_mode = function(refcon)
    return s_unit.night_mode and 1 or 0
end

s_diag_read.theme_percent = function(refcon)
    return math.floor(clamp(s_unit.theme_blend, 0.0, 1.0) * 100.0)
end

s_diag_read.altitude_format = function(refcon)
    return s_config.altitude_format
end

s_diag_read.ambient_light_milli = function(refcon)
    return math.floor(clamp(s_unit.ambient_light, 0.0, 1.0) * 1000.0)
end

s_diag_read.display_mode_config = function(refcon)
    return s_config.display_mode
end

s_diag_read.backlight_percent = function(refcon)
    return math.floor(clamp(s_unit.backlight, 0.0, 1.0) * 100.0 + 0.5)
end

s_diag_read.instrument_brightness_percent = function(refcon)
    return math.floor(clamp(s_render.instrument_brightness, 0.0, 1.0) * 100.0 + 0.5)
end

s_diag_read.bezel_lit_percent = function(refcon)
    return math.floor(clamp(s_render.bezel_lit_alpha, 0.0, 1.0) * 100.0 + 0.5)
end

-- not a diagnostic: the 3D OBJ's ATTR_light_level (always registered)
s_diag_read.key_light = function(refcon)
    return s_render.bezel_lit_alpha
end

s_diag_read.popup_aspect_milli = function(refcon)
    return s_render.popup_aspect_milli or 0
end

s_diag_read.popup_geometry_status = function(refcon)
    return s_render.popup_geometry_status or 0
end

s_diag_read.last_button_touch = function(refcon)
    return s_unit.last_touch_identifier or 0
end

s_diag_read.pressed_button_identifier = function(refcon)
    return s_unit.pressed_button_identifier or 0
end

-- laminar/gtx327/<name> state datarefs ([Budget] diagnostic_datarefs), most
-- useful first; each is read by s_diag_read[name].
local DIAGNOSTIC_DATAREFS = {
    "debug_mode", "xlua_loaded", "xlua_heartbeat", "popup_alive", "avionics_alive",
    "baseline_version", "raster_pipeline", "unit_powered", "power_state", "active_code",
    "selected_mode", "code_entry_digits", "code_display", "code_entry_cursor_slot",
    "ident_active", "vfr_active", "vfr_code", "func_page", "requested_mode", "auto_standby",
    "airborne", "debug_airborne_override", "ground_delay_remaining", "flight_timer_mode",
    "flight_time_sec", "flight_timer_running", "count_up_sec", "count_up_running",
    "count_down_sec", "count_down_initial_sec", "count_down_running", "count_down_expired",
    "count_down_entry_digits", "count_down_entry_cursor_position", "altitude_trend",
    "contrast_percent", "display_percent", "altitude_trend_threshold_fpm", "advisory_active",
    "self_test_failed", "self_test_text_visible", "shutdown_hold", "shutdown_fade_percent",
    "night_mode", "theme_percent", "altitude_format", "ambient_light_milli",
    "display_mode_config", "backlight_percent", "instrument_brightness_percent",
    "bezel_lit_percent", "popup_aspect_milli", "popup_geometry_status", "last_button_touch",
    "pressed_button_identifier",
}

---------------------------------------------------------------------------
-- Registration
--
-- xLua persists every Lua function handed to the SDK, against ~500 shared by
-- all of the aircraft's scripts and counted per hand-off: a dataref, command
-- handler or flight loop costs 1, a device 1 per callback, a click window 4.
-- Datarefs share dr_get and commands share cmd_handler, with the entry id as
-- refcon, so a released entry never reaches a
-- dropped closure. stage "start" entries live until XPluginStop, "enable"
-- entries until XPluginDisable. reg_int / reg_cmd raise when the SDK refuses
-- (the budget); the caller rolls back or, for the optional ones, stops there.

local function dr_get(ref)
    local getter = s_reg.entries[ref]
    if getter == nil then return 0 end
    return getter(ref) or 0
end

-- true passes the command on to X-Plane / other plugins (also after an error)
local cmd_handler = guarded("key command", function(command, phase, ref)
    local handler = s_reg.entries[ref]
    if handler == nil then return true end
    return handler(command, phase, ref) == true
end, true)

-- float = true: a float dataref (key_light, read by the OBJ), else int
local function reg_int(name, getter, stage, float)
    s_reg.next_id = s_reg.next_id + 1
    local id = s_reg.next_id
    s_reg.entries[id] = getter
    -- 12 accessors (int, float, double, int array, float array, data; read and
    -- write each), then the read and write refcons.
    local ok, handle
    if float then
        ok, handle = pcall(XPLMRegisterDataAccessor, name, XPLMDataTypeID.xplmType_Float, false,
            nil, nil, dr_get, nil, nil, nil, nil, nil, nil, nil, nil, nil, id, id)
    else
        ok, handle = pcall(XPLMRegisterDataAccessor, name, XPLMDataTypeID.xplmType_Int, false,
            dr_get, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil, id, id)
    end
    if not ok or handle == nil then
        s_reg.entries[id] = nil
        error("dataref " .. name .. ": " .. tostring(handle), 0)
    end
    s_reg.datarefs[#s_reg.datarefs + 1] = { handle = handle, id = id, stage = stage }
end

local function reg_cmd(command, handler, stage)
    s_reg.next_id = s_reg.next_id + 1
    local id = s_reg.next_id
    s_reg.entries[id] = handler
    local ok, err = pcall(XPLMRegisterCommandHandler, command, cmd_handler, true, id)
    if not ok then
        s_reg.entries[id] = nil
        error("command handler: " .. tostring(err), 0)
    end
    s_reg.commands[#s_reg.commands + 1] = { command = command, id = id, stage = stage }
end

-- Unregisters the datarefs and command handlers of one stage, or all (nil).
local function release_registrations(stage)
    local kept_datarefs, kept_commands = {}, {}
    for _, entry in ipairs(s_reg.datarefs) do
        if stage == nil or entry.stage == stage then
            pcall(XPLMUnregisterDataAccessor, entry.handle)
            s_reg.entries[entry.id] = nil
        else
            kept_datarefs[#kept_datarefs + 1] = entry
        end
    end
    for _, entry in ipairs(s_reg.commands) do
        if stage == nil or entry.stage == stage then
            pcall(XPLMUnregisterCommandHandler, entry.command, cmd_handler, true, entry.id)
            s_reg.entries[entry.id] = nil
        else
            kept_commands[#kept_commands + 1] = entry
        end
    end
    s_reg.datarefs, s_reg.commands = kept_datarefs, kept_commands
end

-- Callbacks this script currently holds in xLua's budget.
local function live_callbacks()
    local count = #s_reg.datarefs + #s_reg.commands + s_reg.windows * 4
    for _, callbacks in pairs(s_reg.devices) do count = count + callbacks end
    if s_flight_loop ~= nil then count = count + 1 end
    return count
end

local fill_rect
do
    -- One quad, refilled per call (XPLMPolygonc reads it during the call):
    -- the LCD draws a few hundred cell runs a frame.
    local quad = { {}, {}, {}, {} }
    fill_rect = function(left, top, right, bottom, color)
        local v = quad
        v[1].x, v[1].y, v[1].color = left, bottom, color
        v[2].x, v[2].y, v[2].color = left, top, color
        v[3].x, v[3].y, v[3].color = right, top, color
        v[4].x, v[4].y, v[4].color = right, bottom, color
        XPLMPolygonc(v, 4)
    end
end

local draw_lcd_surface_art
do
    -- Every vertex and colour of the layer is fixed: built on the first draw,
    -- then only handed to X-Plane (no new tables per frame).
    local quads, line_draws = nil, nil

    local function build()
        local quads_built, lines_built = {}, {}
        -- A restrained vector-only wear layer shared by the 3-D panel and popup.
        -- The gradient edge bands mimic the slight falloff of the recessed LCD;
        -- fixed hairline marks break up the otherwise mathematically perfect glass.
        local left = LCD_ORIGIN_X
        local right = LCD_ORIGIN_X + LCD_W * LCD_SCALE
        local bottom = LCD_ORIGIN_Y
        local top = LCD_ORIGIN_Y + LCD_H * LCD_SCALE
        -- laid out at 2 px a cell; u keeps it on the same cells at LCD_SCALE
        local u = LCD_SCALE / 2
        local edge = XPLMMakeColor(0.0, 0.018, 0.0, 0.24)
        local inner_edge = XPLMMakeColor(0.015, 0.04, 0.0, 0.075)
        local clear = XPLMMakeColor(0.0, 0.0, 0.0, 0.0)

        quads_built[#quads_built + 1] = {
            { x = left, y = top, color = edge }, { x = right, y = top, color = edge },
            { x = right, y = top - 14 * u, color = clear }, { x = left, y = top - 14 * u, color = clear }
        }
        quads_built[#quads_built + 1] = {
            { x = left, y = bottom + 12 * u, color = clear }, { x = right, y = bottom + 12 * u, color = clear },
            { x = right, y = bottom, color = edge }, { x = left, y = bottom, color = edge }
        }
        quads_built[#quads_built + 1] = {
            { x = left, y = bottom, color = edge }, { x = left, y = top, color = edge },
            { x = left + 18 * u, y = top, color = clear }, { x = left + 18 * u, y = bottom, color = clear }
        }
        quads_built[#quads_built + 1] = {
            { x = right - 18 * u, y = bottom, color = clear }, { x = right - 18 * u, y = top, color = clear },
            { x = right, y = top, color = edge }, { x = right, y = bottom, color = edge }
        }

        -- A second, broader falloff prevents the first band from reading as a
        -- simple border and gives the recessed LCD a slightly uneven glass depth.
        quads_built[#quads_built + 1] = {
            { x = left + 7 * u, y = top - 7 * u, color = inner_edge },
            { x = right - 7 * u, y = top - 7 * u, color = inner_edge },
            { x = right - 25 * u, y = top - 25 * u, color = clear },
            { x = left + 25 * u, y = top - 25 * u, color = clear }
        }
        quads_built[#quads_built + 1] = {
            { x = left + 24 * u, y = bottom + 22 * u, color = clear },
            { x = right - 24 * u, y = bottom + 22 * u, color = clear },
            { x = right - 6 * u, y = bottom + 6 * u, color = inner_edge },
            { x = left + 6 * u, y = bottom + 6 * u, color = inner_edge }
        }

        lines_built[#lines_built + 1] = {
            XPLMMakeColor(0.0, 0.025, 0.0, 0.030),
            0.55 * u,
            {
                { x = left + 12 * u, y = bottom + 13 * u }, { x = right - 12 * u, y = bottom + 13 * u },
                { x = left + 9 * u, y = bottom + 27 * u }, { x = right - 9 * u, y = bottom + 27 * u },
                { x = left + 8 * u, y = bottom + 41 * u }, { x = right - 8 * u, y = bottom + 41 * u },
                { x = left + 10 * u, y = bottom + 55 * u }, { x = right - 10 * u, y = bottom + 55 * u }
            },
            8
        }

        lines_built[#lines_built + 1] = {
            XPLMMakeColor(0.0, 0.035, 0.0, 0.070),
            0.95 * u,
            {
                { x = left + 92 * u, y = top - 18 * u }, { x = left + 139 * u, y = top - 20 * u },
                { x = left + 337 * u, y = bottom + 20 * u }, { x = left + 369 * u, y = bottom + 18 * u }
            },
            4
        }
        return quads_built, lines_built
    end

    draw_lcd_surface_art = function()
        if quads == nil then quads, line_draws = build() end
        for i = 1, #quads do XPLMPolygonc(quads[i], 4) end
        for i = 1, #line_draws do
            local d = line_draws[i]
            XPLMLinesWithWidth(d[1], d[2], d[3], d[4])
        end
    end
end

local accumulate_buttons
do
    -- A key held down sinks into the bezel: its cap
    -- is drawn again from the image a little smaller and lower, shaded, over
    -- a dark hole, so a gap opens above it and the cap covers most of its own
    -- drop shadow below. Input is handled by the device's bezelClickCallback;
    -- the pressed visual stays in the same device coordinates as the artwork
    -- (BEZEL_W x BEZEL_H times DEVICE_PX), so X-Plane scales art, hit-testing and
    -- feedback as one unit, including in a resized first-class OS popup.
    local SINK_SCALE = 0.96   -- the cap, about its centre
    local SINK_DROP = 2.0     -- bezel units down
    local CAP_SHADE = 0.80    -- the sunk cap is in the bezel's shade
    local HOLE_ALPHA = 0.50
    -- A square key's box also holds the cap's drop shadow (below it): the cap
    -- is the box less these (sides and top, bottom), with rounded corners
    -- (measured on the image's 0 key).
    local CAP_INSET_SIDE, CAP_INSET_BOTTOM, CAP_RADIUS = 2, 3, 6

    -- the cap as a convex polygon, counter-clockwise; an outline key's is its
    -- outline
    local function cap_polygon(button)
        local vertices = button.cap_vertices
        if vertices == nil then
            vertices = {}
            if button.outline ~= nil then
                for i = 1, #button.outline, 2 do
                    vertices[#vertices + 1] = { x = button.outline[i], y = button.outline[i + 1] }
                end
            else
                local left, right = button.left + CAP_INSET_SIDE, button.right - CAP_INSET_SIDE
                local top, bottom = button.top - CAP_INSET_SIDE, button.bottom + CAP_INSET_BOTTOM
                -- corner centres from bottom right, each corner 90 degrees in 4 points
                local corners = {
                    { right - CAP_RADIUS, bottom + CAP_RADIUS }, { right - CAP_RADIUS, top - CAP_RADIUS },
                    { left + CAP_RADIUS, top - CAP_RADIUS }, { left + CAP_RADIUS, bottom + CAP_RADIUS }
                }
                for c = 1, 4 do
                    for step = 0, 3 do
                        local angle = math.rad(-90 + 90 * (c - 1) + 30 * step)
                        vertices[#vertices + 1] = {
                            x = corners[c][1] + CAP_RADIUS * math.cos(angle),
                            y = corners[c][2] + CAP_RADIUS * math.sin(angle)
                        }
                    end
                end
            end
            -- bezel units to device pixels
            for i = 1, #vertices do
                vertices[i].x, vertices[i].y = vertices[i].x * DEVICE_PX, vertices[i].y * DEVICE_PX
            end
            button.cap_vertices = vertices
        end
        return vertices
    end

    -- The sunk cap as a triangle strip (zig-zag across the convex polygon:
    -- 1, n, 2, n-1, ...): texture coordinates where the cap is in the image,
    -- positions scaled about its centre and dropped.
    local function cap_mesh(button)
        local mesh = button.cap_mesh
        if mesh == nil then
            local vertices = cap_polygon(button)
            local n = #vertices
            local cx, cy = 0.0, 0.0
            for i = 1, n do cx, cy = cx + vertices[i].x, cy + vertices[i].y end
            cx, cy = cx / n, cy / n
            mesh = {}
            local low, high = 1, n
            while low <= high do
                for _, i in ipairs(low == high and { low } or { low, high }) do
                    local v = vertices[i]
                    mesh[#mesh + 1] = {
                        x = cx + (v.x - cx) * SINK_SCALE,
                        y = cy + (v.y - cy) * SINK_SCALE - SINK_DROP * DEVICE_PX,
                        s = v.x / (BEZEL_W * DEVICE_PX),
                        t = v.y / (BEZEL_H * DEVICE_PX)
                    }
                end
                low, high = low + 1, high - 1
            end
            button.cap_mesh = mesh
        end
        return mesh
    end

    accumulate_buttons = function()
        local button = BUTTONS[s_unit.pressed_button_identifier]
        if button == nil then return end
        -- without the image (or the mesh call) the key only darkens
        local sink = s_atlas ~= nil and s_base_image ~= nil and XPLMTextureAtlasDrawMesh ~= nil
        local hole = XPLMMakeColor(0.0, 0.0, 0.0, sink and HOLE_ALPHA or 0.20)
        local vertices = cap_polygon(button)
        if XPLMPolygon ~= nil then
            XPLMPolygon(hole, vertices, #vertices)
        else
            fill_rect((button.left + 2) * DEVICE_PX, (button.top - 2) * DEVICE_PX,
                (button.right - 2) * DEVICE_PX, (button.bottom + 2) * DEVICE_PX, hole)
        end
        if not sink then return end

        local mesh = cap_mesh(button)
        local shade = clamp(s_render.bezel_shade or 1.0, 0.0, 1.0) * CAP_SHADE
        XPLMTextureAtlasDrawMesh(s_atlas, s_base_image, XPLMMakeColor(shade, shade, shade, 1.0), mesh, #mesh)
        -- the legend's glow goes down with the cap
        local lit_alpha = clamp(s_render.bezel_lit_alpha or 0.0, 0.0, 1.0)
        if s_lit_image ~= nil and lit_alpha > 0.001 then
            XPLMTextureAtlasDrawMesh(s_atlas, s_lit_image, XPLMMakeColor(1.0, 1.0, 1.0, lit_alpha), mesh, #mesh)
        end
    end
end


local function lcd_emit_run(x, y, width, height, on)
    local left = LCD_ORIGIN_X + math.floor(x) * LCD_SCALE
    local right = left + math.floor(width) * LCD_SCALE
    local top = LCD_ORIGIN_Y + (LCD_H - math.floor(y)) * LCD_SCALE
    local bottom = top - math.floor(height) * LCD_SCALE
    -- The same 1-bit masks support both day and night polarity. Reverse-video
    -- cursor glyphs continue to invert correctly through the transition.
    fill_rect(left, top, right, bottom, on and s_lcd_foreground or s_lcd_background)
end

local function screen_draw_cb(refcon)
    -- X-Plane does not clear custom avionics framebuffers between callbacks.
    fill_rect(0, SCREEN_H * DEVICE_PX, SCREEN_W * DEVICE_PX, 0, s_clear_black)
    if s_raster == nil or not s_render.powered then return end

    local blend = clamp(s_render.theme_blend or 0.0, 0.0, 1.0)
    blend = blend * blend * (3.0 - 2.0 * blend)
    local fade = 1.0 - clamp(s_render.shutdown_fade or 0.0, 0.0, 1.0)
    local inverse = 1.0 - blend
    -- Day samples are bright yellow-green with dark olive cells. Night mode is
    -- a true global polarity change: pale green cells on a deep green field
    -- (the backlight still shows, rather than the manual's black).
    local background_r = 0.79 * inverse + 0.13 * blend
    local background_g = 0.92 * inverse + 0.25 * blend
    local background_b = 0.28 * inverse + 0.10 * blend
    local nominal_r = 0.13 * inverse + 0.82 * blend
    local nominal_g = 0.24 * inverse + 0.93 * blend
    local nominal_b = 0.01 * inverse + 0.36 * blend
    -- Contrast changes cell-to-background separation in either polarity; it
    -- does not bypass the photo-sensor day/night transition. contrast_level is
    -- the contrast itself in MAN and the offset to the compensated contrast in
    -- AUTO (IM 5.2.4). X-Plane has no LCD temperature, so the compensated
    -- contrast stays at the look of the factory offset 50, and the offset
    -- moves it either way by the same step as a MAN level.
    local contrast = 0.15 + 0.85 * clamp(s_render.contrast_level or 0.50, 0.0, 1.0)
    local foreground_r = background_r + (nominal_r - background_r) * contrast
    local foreground_g = background_g + (nominal_g - background_g) * contrast
    local foreground_b = background_b + (nominal_b - background_b) * contrast
    s_lcd_background = XPLMMakeColor(
        background_r * fade, background_g * fade, background_b * fade, 1.0
    )
    s_lcd_foreground = XPLMMakeColor(
        foreground_r * fade, foreground_g * fade, foreground_b * fade, 1.0
    )

    fill_rect(
        LCD_ORIGIN_X,
        LCD_ORIGIN_Y + LCD_H * LCD_SCALE,
        LCD_ORIGIN_X + LCD_W * LCD_SCALE,
        LCD_ORIGIN_Y,
        s_lcd_background
    )

    -- All text, cursors, arrows, reply symbology and debug marks are emitted as
    -- integer-aligned runs of logical LCD cells.  No XPLM font/vector primitive
    -- is used anywhere in the active display path.
    s_raster.draw_screen(s_render, lcd_emit_run)
    draw_lcd_surface_art()
end

local function bezel_draw_cb(ambient_r, ambient_g, ambient_b, refcon)
    if s_atlas == nil or s_base_image == nil then
        fill_rect(0, BEZEL_H * DEVICE_PX, BEZEL_W * DEVICE_PX, 0, XPLMMakeColor(0.05, 0.05, 0.05, 1.0))
        accumulate_buttons()
        return
    end

    -- Not times X-Plane's panel ambient (about 0.8 at noon): the image is
    -- already lit as the unit looks by day.
    local shade = clamp(s_render.bezel_shade or 1.0, 0.0, 1.0)
    XPLMTextureAtlasDrawIn(
        s_atlas,
        s_base_image,
        XPLMMakeColor(shade, shade, shade, 1.0),
        0, BEZEL_H * DEVICE_PX, BEZEL_W * DEVICE_PX, 0
    )

    -- The key legends' glow, as the 3D unit's ATTR_light_level: the image's
    -- colour times alpha is the glow, so a normal blend adds it.
    local bezel_lit_alpha = clamp(s_render.bezel_lit_alpha or 0.0, 0.0, 1.0)
    if s_lit_image ~= nil and bezel_lit_alpha > 0.001 then
        XPLMTextureAtlasDrawIn(
            s_atlas,
            s_lit_image,
            XPLMMakeColor(1.0, 1.0, 1.0, bezel_lit_alpha),
            0, BEZEL_H * DEVICE_PX, BEZEL_W * DEVICE_PX, 0
        )
    end

    accumulate_buttons()
end

local function brightness_cb(rheo, ambient, bus, refcon)
    -- inAmbientBrightness: "the value the callback should return for the
    -- screen to be at a usable brightness based on ambient light" (SDK). It
    -- is the unit's photocell; the Garmin backlight curve still applies. The
    -- 3D screen gets the level dimmed by the sky (update_backlight).
    if refcon == "cockpit" then
        if type(ambient) == "number" then s_unit.xp_ambient = clamp(ambient, 0.0, 1.0) end
        return s_render.effective_brightness_3d
    end
    return s_render.effective_brightness
end

local function make_device_params(device_id, device_name, refcon)
    return {
        screenWidth = SCREEN_W * DEVICE_PX,
        screenHeight = SCREEN_H * DEVICE_PX,
        bezelWidth = BEZEL_W * DEVICE_PX,
        bezelHeight = BEZEL_H * DEVICE_PX,
        screenOffsetX = SCREEN_OFFSET_X * DEVICE_PX,
        screenOffsetY = SCREEN_OFFSET_Y * DEVICE_PX,
        drawOnDemand = false,
        drawCallback = guarded("screen draw", screen_draw_cb),
        -- The bezel is drawn only in a popup; the cockpit device is never
        -- popped up (the popup is its own device), so it does not spend a
        -- budget callback on one.
        bezelDrawCallback = refcon == "popup" and guarded("popup bezel draw", bezel_draw_cb) or nil,
        -- The cockpit unit already receives input through the OBJ manipulators.
        -- Installing this callback there as well double-fired a single 3-D
        -- click. Direct bezel hit-testing belongs only to the popup device.
        bezelClickCallback = refcon == "popup" and guarded("popup click", s_bezel_cb.click, false) or nil,
        bezelCursorCallback = refcon == "popup" and guarded("popup cursor", s_bezel_cb.cursor, 0) or nil,
        brightnessCallback = guarded("screen brightness", brightness_cb, 1.0),
        deviceID = device_id,
        deviceName = device_name,
        refcon = refcon,
        contentType = XPLMWindowContentType.xplm_WindowContentTypePanelGraphics,
        -- Pure bezel, like X-Plane's stock Garmin popups (config popup_frame).
        windowWithChrome = s_config.popup_frame and 1 or 0
    }
end

-- Raises when the SDK refuses (e.g. the xLua budget).
local function create_device(params)
    local ok, device = pcall(XPLMCreateAvionicsEx, params)
    if not ok or device == nil then
        error("XPLMCreateAvionicsEx " .. params.deviceID .. ": " .. tostring(device), 0)
    end
    local callbacks = 0
    for _, value in pairs(params) do
        if type(value) == "function" then callbacks = callbacks + 1 end
    end
    s_reg.devices[device] = callbacks
    return device
end

local function destroy_device(device)
    if device == nil then return end
    s_reg.devices[device] = nil
    pcall(XPLMDestroyAvionics, device)
end

local function read_popup_geometry()
    if s_device_popup == nil then
        s_render.popup_geometry_status = -1
        return nil
    end
    local ok_popped, popped = pcall(XPLMIsAvionicsPoppedOut, s_device_popup)
    if not ok_popped then
        s_render.popup_geometry_status = -2
        return nil
    end
    local getter = popped and XPLMGetAvionicsGeometryOS or XPLMGetAvionicsGeometry
    local ok, geometry = pcall(getter, s_device_popup)
    if not ok then
        s_render.popup_geometry_status = -3
        return nil
    end
    if type(geometry) ~= "table" then
        s_render.popup_geometry_status = -4
        return nil
    end

    local left = unwrap_number(geometry.outLeft)
    local top = unwrap_number(geometry.outTop)
    local right = unwrap_number(geometry.outRight)
    local bottom = unwrap_number(geometry.outBottom)
    if left and top and right and bottom and math.abs(right - left) >= 100 and math.abs(top - bottom) >= 50 then
        s_render.popup_geometry_status = popped and 10 or 11
        return { left = left, top = top, right = right, bottom = bottom }, popped
    end
    s_render.popup_geometry_status = -5
    return nil
end

local function popup_geometry_size(geometry)
    return math.abs(geometry.right - geometry.left), math.abs(geometry.top - geometry.bottom)
end

local function popup_geometry_is_native(geometry)
    local width, height = popup_geometry_size(geometry)
    return math.abs(width - height * POPUP_NATIVE_ASPECT) <= POPUP_ASPECT_TOLERANCE_PX
end

local function correct_popup_geometry(geometry, previous)
    local width, height = popup_geometry_size(geometry)
    local corrected_width = width
    local corrected_height = height

    if popup_geometry_is_native(geometry) then return geometry, false end

    if previous ~= nil then
        local previous_width, previous_height = popup_geometry_size(previous)
        local width_change = math.abs(width - previous_width) / math.max(previous_width, 1)
        local height_change = math.abs(height - previous_height) / math.max(previous_height, 1)
        if width_change > height_change then
            corrected_height = math.max(50, math.floor(width / POPUP_NATIVE_ASPECT + 0.5))
        else
            corrected_width = math.max(100, math.floor(height * POPUP_NATIVE_ASPECT + 0.5))
        end
    else
        -- X-Plane can restore an old near-square popup while retaining the
        -- intrinsic bezel height.  The first correction therefore treats
        -- height as authoritative and restores the missing horizontal extent.
        corrected_width = math.max(100, math.floor(height * POPUP_NATIVE_ASPECT + 0.5))
    end

    local horizontal_sign = geometry.right >= geometry.left and 1 or -1
    local vertical_sign = geometry.bottom >= geometry.top and 1 or -1
    return {
        left = geometry.left,
        top = geometry.top,
        right = geometry.left + horizontal_sign * corrected_width,
        bottom = geometry.top + vertical_sign * corrected_height
    }, true
end

local function enforce_popup_native_aspect()
    local geometry, popped = read_popup_geometry()
    if geometry == nil then return end
    local popup_mode = popped and "os" or "native"
    if s_popup_mode ~= popup_mode then
        s_popup_mode = popup_mode
        s_popup_geometry_settle_frames = 2
        return
    end
    if s_popup_geometry_settle_frames > 0 then
        s_popup_geometry_settle_frames = s_popup_geometry_settle_frames - 1
        return
    end

    local previous = popped and s_popup_os_geometry or s_popup_native_geometry
    local corrected, changed = correct_popup_geometry(geometry, previous)
    if not popped and previous == nil and popup_geometry_size(corrected) >= 2 * BEZEL_W then
        -- First open: X-Plane sizes a new popup from the device's bezel, which
        -- is DEVICE_PX times the bezel units. Open it at the
        -- bezel-unit size instead, about the same centre.
        local cx = (corrected.left + corrected.right) / 2
        local cy = (corrected.top + corrected.bottom) / 2
        local horizontal_sign = corrected.right >= corrected.left and 1 or -1
        local vertical_sign = corrected.bottom >= corrected.top and 1 or -1
        corrected = {
            left = cx - horizontal_sign * BEZEL_W / 2,
            right = cx + horizontal_sign * BEZEL_W / 2,
            top = cy - vertical_sign * BEZEL_H / 2,
            bottom = cy + vertical_sign * BEZEL_H / 2
        }
        changed = true
    end
    local width, height = popup_geometry_size(corrected)
    s_render.popup_aspect_milli = math.floor(width / math.max(height, 1) * 1000 + 0.5)
    if popped then
        s_popup_os_geometry = corrected
    else
        s_popup_native_geometry = corrected
    end

    if changed then
        local setter = popped and XPLMSetAvionicsGeometryOS or XPLMSetAvionicsGeometry
        local ok = pcall(
            setter,
            s_device_popup,
            math.floor(corrected.left),
            math.floor(corrected.top),
            math.floor(corrected.right),
            math.floor(corrected.bottom)
        )
        if ok then
            s_popup_geometry_settle_frames = 2
        end
    end
end

local function save_popup_geometry()
    local geometry, popped = read_popup_geometry()
    if geometry == nil then return end
    if popup_geometry_is_native(geometry) then
        if popped then
            s_popup_os_geometry = geometry
        else
            s_popup_native_geometry = geometry
        end
        local width, height = popup_geometry_size(geometry)
        s_render.popup_aspect_milli = math.floor(width / math.max(height, 1) * 1000 + 0.5)
    elseif popped and s_popup_os_geometry == nil then
        s_popup_os_geometry = select(1, correct_popup_geometry(geometry, nil))
    elseif not popped and s_popup_native_geometry == nil then
        s_popup_native_geometry = select(1, correct_popup_geometry(geometry, nil))
    end
end

-- The popup device is created each time the popup opens (5 callbacks) and
-- destroyed when it is closed or toggled off, not created once and
-- then only hidden (XLua 2.0.0-r1 has no callback budget to spare for a
-- hidden popup). Its size and place are kept for the next open.
local function popup_shown()
    return s_device_popup ~= nil and (s_popup_seen_visible or s_popup_grace_frames > 0)
end

local function destroy_popup(reason)
    if s_device_popup == nil then return end
    -- a key held down in the popup gets no mouse-up once it is gone
    local key = s_unit.popup_key
    if key ~= nil then
        s_unit.popup_key = nil
        pcall(XPLMCommandEnd, s_button_commands[key])
    end
    if popup_shown() then pcall(save_popup_geometry) end
    s_popup_seen_visible = false
    s_popup_grace_frames = 0
    s_popup_mode = nil
    s_popup_geometry_settle_frames = 0
    local handle = s_device_popup
    pcall(XPLMSetAvionicsPopupVisible, handle, false)
    s_device_popup = nil
    destroy_device(handle)
end

-- Fail-soft: a popup refused by the budget costs only the popup.
local function show_popup()
    if s_device_popup == nil then
        local ok, device = pcall(create_device,
            make_device_params(DEVICE_ID_POPUP, "Garmin GTX 327 Popup", "popup"))
        if not ok then
            -- each toggle tries again; Log.txt hears it once per load
            if not s_reg.popup_refused_noted then
                s_reg.popup_refused_noted = true
                log("INSTALL popup could not be created (" .. tostring(device) .. "): the aircraft's xLua callback budget is probably used up (XLua older than 2.0.0-r1 also counts every popup open). Local fix: update XLua, or free callbacks; the 3D unit still works.")
            end
            return false
        end
        s_device_popup = device
    end

    s_popup_seen_visible = false
    s_popup_grace_frames = 30
    s_popup_mode = nil
    s_popup_geometry_settle_frames = 0
    XPLMSetAvionicsBrightnessRheo(s_device_popup, s_render.effective_brightness)
    XPLMSetAvionicsPopupVisible(s_device_popup, true)

    -- Always start as an X-Plane floating avionics window.  The pilot may use
    -- X-Plane's pop-out control to promote it to a first-class OS window.
    if s_popup_native_geometry ~= nil then
        pcall(
            XPLMSetAvionicsGeometry,
            s_device_popup,
            math.floor(s_popup_native_geometry.left),
            math.floor(s_popup_native_geometry.top),
            math.floor(s_popup_native_geometry.right),
            math.floor(s_popup_native_geometry.bottom)
        )
        s_popup_geometry_settle_frames = 2
    end

    return true
end

local function update_popup_lifecycle()
    if not popup_shown() then return end

    local ok, visible = pcall(XPLMIsAvionicsPopupVisible, s_device_popup)
    if ok and visible then
        s_popup_seen_visible = true
        enforce_popup_native_aspect()
        return
    end

    if s_popup_seen_visible then
        destroy_popup("window close")
        return
    end

    s_popup_grace_frames = s_popup_grace_frames - 1
    if s_popup_grace_frames <= 0 then destroy_popup("never became visible") end
end

local function popup_command_cb(command, phase, refcon)
    -- No screen device (Disabled, or Enable failed): no popup either.
    if s_device_3d == nil then return true end
    if phase == XPLMCommandPhase.xplm_CommandBegin then
        if popup_shown() then
            destroy_popup("toggle command")
        else
            show_popup()
        end
    end
    return true
end

local function debug_airborne_command_cb(command, phase, refcon)
    if phase == XPLMCommandPhase.xplm_CommandBegin and s_config.debug_mode then
        local value = math.floor(tonumber(refcon) or -1)
        s_unit.debug_airborne_override = clamp(value, -1, 1)
    end
    return true
end

local function bezel_command_cb(command, phase, refcon)
    local name = tostring(refcon or "")
    if name == "off" then
        if phase == XPLMCommandPhase.xplm_CommandBegin then
            begin_shutdown_hold()
        elseif phase == XPLMCommandPhase.xplm_CommandEnd then
            release_shutdown_hold()
        end
        return true
    end
    if name == "func" then
        if phase == XPLMCommandPhase.xplm_CommandBegin then
            s_unit.func_held = true
            s_unit.func_held_at = now_seconds()
            if s_unit.power_state == POWER_OFF then s_unit.func_tapped_at = s_unit.func_held_at end
        elseif phase == XPLMCommandPhase.xplm_CommandEnd then
            s_unit.func_held = false
        end
    end
    if phase ~= XPLMCommandPhase.xplm_CommandBegin then return true end
    if s_unit.off_hold_active then return true end

    if s_unit.power_state == POWER_CONFIG then
        s_setup.key(name)
    elseif name == "ident" then
        activate_ident()
    elseif name == "vfr" then
        toggle_vfr()
    elseif name == "stby" then
        select_mode(1)
    elseif name == "on" then
        select_mode(2)
    elseif name == "alt" then
        select_mode(3)
    elseif name == "func" then
        if s_unit.power_state == POWER_OPERATING then
            cancel_count_down_entry("FUNC page change")
            s_unit.func_page = next_func_page(s_unit.func_page)
        end
    elseif name == "startstop" then
        toggle_current_timer()
    elseif name == "clr" then
        clear_current_context()
    elseif name == "crsr" then
        if s_unit.entry_digits ~= nil then
            cancel_code_entry("CRSR")
        elseif s_unit.func_page == 3 then
            begin_count_down_entry()
        end
    else
        local digit = tonumber(name)
        -- the CONTRAST / DISPLAY page is kept while off; 8 / 9 need the unit on
        local operating = s_unit.power_state == POWER_OPERATING
        if digit ~= nil and s_unit.count_down_entry_digits ~= nil then
            enter_count_down_digit(digit)
        elseif digit == 8 and operating and s_unit.func_page == 4 and s_config.manual_contrast_page then
            s_config.contrast_level = clamp(s_config.contrast_level - LEVEL_STEP, 0.0, 1.0)
        elseif digit == 9 and operating and s_unit.func_page == 4 and s_config.manual_contrast_page then
            s_config.contrast_level = clamp(s_config.contrast_level + LEVEL_STEP, 0.0, 1.0)
        elseif (digit == 8 or digit == 9) and operating and s_unit.func_page == 5 and s_config.manual_display_page then
            -- MAN key lighting is the pilot's on this page too (IM 5.2.3): it
            -- moves by what the screen level moved, keeping the pilot's
            -- difference through a clamp at 0 / 100 %. A key level
            -- changed elsewhere (configuration mode) starts a new difference.
            local before = s_config.display_level
            local offset = s_unit.key_offset
            if offset == nil or clamp(before + offset, 0.0, 1.0) ~= s_config.key_light_level then
                offset = s_config.key_light_level - before
                s_unit.key_offset = offset
            end
            s_config.display_level = clamp(before + (digit == 8 and -LEVEL_STEP or LEVEL_STEP), 0.0, 1.0)
            s_config.key_light_level = clamp(s_config.display_level + offset, 0.0, 1.0)
        elseif digit ~= nil and digit >= 0 and digit <= 7 then
            enter_code_digit(digit)
        end
        -- Per the pilot guide, 8/9 are never valid squawk digits. Outside
        -- Count Down entry and the two optional adjustment pages they do nothing.
    end
    return true
end

local function button_index_at(x, y)
    local px = tonumber(x)
    local py = tonumber(y)
    if px == nil or py == nil then return 0 end
    px, py = px / DEVICE_PX, py / DEVICE_PX   -- device pixels to BUTTONS' bezel units
    for index = #BUTTONS, 1, -1 do
        local button = BUTTONS[index]
        if px >= button.left and px <= button.right
            and py <= button.top and py >= button.bottom then
            -- ALT and the arc keys around it overlap as boxes: inside the
            -- outline (convex, counter-clockwise) = left of every edge.
            local outline = button.outline
            if outline == nil then return index end
            local n = #outline
            local inside = true
            for i = 1, n, 2 do
                local x0, y0 = outline[i], outline[i + 1]
                local x1, y1 = outline[(i + 1) % n + 1], outline[(i + 2) % n + 1]
                if (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0) < 0 then
                    inside = false
                    break
                end
            end
            if inside then return index end
        end
    end
    return 0
end

-- The button cursor over the keys, as over the 3D unit's keys (gtx327_pick.lua).
s_bezel_cb.cursor = function(x, y, refcon)
    local key = button_index_at(x, y) > 0 and "xplm_CursorButton" or "xplm_CursorDefault"
    return (XPLMCursorStatus and XPLMCursorStatus[key]) or 0
end

-- The mouse ends only the key it pressed itself (popup_key): a key held at
-- the same time from the keyboard, a joystick or the 3D unit is left to its
-- own release.
s_bezel_cb.click = function(x, y, status, refcon)
    if status == XPLMMouseStatus.xplm_MouseDown then
        local index = button_index_at(x, y)
        if index <= 0 then return false end

        -- a mouse-up that never came: end the mouse's own key first
        local own = s_unit.popup_key
        if own ~= nil and BUTTONS[own] ~= nil then
            s_unit.popup_key = nil
            XPLMCommandEnd(s_button_commands[own])
        end
        -- the key is already held from another source: one key, one press
        if s_unit.pressed_button_identifier == index then return true end
        XPLMCommandBegin(s_button_commands[index])
        s_unit.popup_key = index
        return true
    end

    local own = s_unit.popup_key
    if own == nil or BUTTONS[own] == nil then return false end
    if status == XPLMMouseStatus.xplm_MouseUp then
        s_unit.popup_key = nil
        XPLMCommandEnd(s_button_commands[own])
    end
    -- Consume drag/up for the button that owned mouse-down, even if the pointer
    -- has drifted outside its rectangle.  This preserves the one-second OFF
    -- hold/release semantics and prevents a stuck pressed state.
    return true
end

-- Core: the 20 keys (the OBJ's primary commands) and popup_toggle, plus the
-- aircraft clock's commands when sim_timer_commands hands them over.
local function create_commands()
    reg_cmd(XPLMCreateCommand("laminar/gtx327/popup_toggle", "Toggle GTX 327 popup"), popup_command_cb, "start")

    for index = 1, #BUTTONS do
        local button = BUTTONS[index]
        local button_name = button.name
        local button_index = index
        local passthrough = button.passthrough
        local runtime_name = button.command
        s_button_commands[index] = XPLMFindCommand(button.command)
        if s_button_commands[index] == nil then
            if string.sub(runtime_name, 1, 4) == "sim/" then
                runtime_name = COMMAND_PREFIX .. button.name
                log("INSTALL X-Plane has no command " .. button.command .. "; using " .. runtime_name .. " instead. X-Plane older than 12.4.4? Otherwise report a BUG on GitHub.")
            end
            s_button_commands[index] = XPLMCreateCommand(
                runtime_name,
                "GTX 327 " .. string.upper(button.name)
            )
        end
        button.runtime_name = runtime_name
        reg_cmd(s_button_commands[index], function(command, phase)
            -- No screen device: Enable failed or has not run. The unit is not
            -- there, so X-Plane (and a stock transponder) keeps the command.
            if s_device_3d == nil then return true end
            if phase == XPLMCommandPhase.xplm_CommandBegin then
                s_unit.pressed_button_identifier = button_index
                s_unit.last_touch_identifier = button_index
                -- Decided once per press, so X-Plane gets the Begin and
                -- its End, or neither (the unit can power off in between)
                -- (not while OFF is held: the unit ignores the other keys then)
                if passthrough then
                    s_unit.ident_passed = s_unit.power_state == POWER_OPERATING and not s_unit.off_hold_active
                end
            end
            bezel_command_cb(command, phase, button_name)
            if phase == XPLMCommandPhase.xplm_CommandEnd then
                if s_unit.pressed_button_identifier == button_index then
                    s_unit.pressed_button_identifier = 0
                end
                if s_unit.popup_key == button_index then s_unit.popup_key = nil end
            end
            -- Only IDENT passes through, and only from an operating unit:
            -- an OFF or self-testing transponder sends no SPI pulse.
            return passthrough and s_unit.ident_passed
        end, "start")
    end

    -- The timer keys' alias is the aircraft clock's sim command, when the
    -- installation hands it over; it routes to the primary command.
    for index = 1, #BUTTONS do
        local button = BUTTONS[index]
        if s_config.sim_timer_commands and button.sim_alias ~= nil
            and button.runtime_name == COMMAND_PREFIX .. button.name then
            local primary_command = s_button_commands[index]
            reg_cmd(XPLMCreateCommand(button.sim_alias, "GTX 327 " .. string.upper(button.name)),
                function(command, phase)
                    -- No unit (Disabled, or Enable failed): the aircraft
                    -- clock keeps its command
                    if s_device_3d == nil then return true end
                    if phase == XPLMCommandPhase.xplm_CommandBegin then
                        XPLMCommandBegin(primary_command)
                    elseif phase == XPLMCommandPhase.xplm_CommandEnd then
                        XPLMCommandEnd(primary_command)
                    end
                    return false
                end, "start")
        end
    end
end

-- Optional, registered last and fail-soft ([Budget] in gtx327_config.ini,
-- and the block on X-Plane's code up / down commands, always wanted):
-- stops at the first registration the budget refuses; the unit is unaffected.
-- Returns registered, wanted.
local function register_optional()
    local steps = {}
    if s_config.alias_commands then
        -- laminar/gtx327_<key> and laminar/gtx327_popup: older bindings and
        -- panels with their own GTX click regions; each routes to the primary command.
        steps[#steps + 1] = function()
            reg_cmd(XPLMCreateCommand("laminar/gtx327_popup", "Toggle GTX 327 popup"), popup_command_cb, "enable")
        end
        for index = 1, #BUTTONS do
            local button = BUTTONS[index]
            local alias = COMMAND_PREFIX .. button.name
            if alias ~= button.runtime_name then
                local primary_command = s_button_commands[index]
                steps[#steps + 1] = function()
                    reg_cmd(XPLMCreateCommand(alias, "GTX 327 compatibility alias " .. string.upper(button.name)),
                        function(command, phase)
                            if phase == XPLMCommandPhase.xplm_CommandBegin then
                                XPLMCommandBegin(primary_command)
                            elseif phase == XPLMCommandPhase.xplm_CommandEnd then
                                XPLMCommandEnd(primary_command)
                            end
                            return false
                        end, "enable")
                end
            end
        end
    end
    if s_config.debug_mode then
        for index = 1, #DEBUG_AIRBORNE_COMMANDS do
            local definition = DEBUG_AIRBORNE_COMMANDS[index]
            steps[#steps + 1] = function()
                reg_cmd(XPLMCreateCommand(DREF_PREFIX .. "debug_airborne_" .. definition.name,
                    "GTX 327 debug airborne override " .. definition.name),
                    function(command, phase)
                        return debug_airborne_command_cb(command, phase, definition.value)
                    end, "enable")
            end
        end
    end
    if s_config.diagnostic_datarefs then
        for _, name in ipairs(DIAGNOSTIC_DATAREFS) do
            steps[#steps + 1] = function()
                reg_int(DREF_PREFIX .. name, s_diag_read[name], "enable")
            end
        end
    end
    -- X-Plane's digit up / down commands: the unit has no such control (pilot's
    -- guide: the code is set with the 0-7 keys), so they are kept from X-Plane,
    -- on or off. Without the unit X-Plane keeps them. Last: out of budget, only
    -- these stay with X-Plane.
    local function no_code_steps(command, phase)
        return s_device_3d == nil
    end
    local budget_steps, missing = #steps, 0
    for _, place in ipairs({ "thousands", "hundreds", "tens", "ones", "12", "34" }) do
        for _, way in ipairs({ "up", "down" }) do
            local name = "sim/transponder/transponder_" .. place .. "_" .. way
            steps[#steps + 1] = function()
                local command = XPLMFindCommand(name)
                if command == nil then
                    missing = missing + 1
                    return
                end
                reg_cmd(command, no_code_steps, "enable")
            end
        end
    end

    for done, step in ipairs(steps) do
        local ok, err = pcall(step)
        if not ok then
            local advice
            if done > budget_steps then
                -- these have no switch: only freeing callbacks helps
                advice = " Some of X-Plane's code up / down commands are not kept from X-Plane and can still change"
                    .. " the code. Local fix: free callbacks, or ignore; the unit works without them."
            else
                advice = " The blocks on X-Plane's code up / down commands, registered after them, are skipped too."
                    .. " Local fix: turn off [Budget] options in gtx327_config.ini, or ignore; the unit works without them."
            end
            log(string.format("INSTALL optional registrations stopped at %d of %d (%s): the xLua callback budget is"
                .. " probably used up by other scripts.%s", done - 1, #steps, tostring(err), advice))
            return done - 1 - missing, #steps - missing
        end
    end
    return #steps - missing, #steps - missing
end

local function flight_loop_cb(elapsed_since_last_call, elapsed_since_last_loop, counter, refcon)
    s_heartbeat = s_heartbeat + 1
    update_render_state()
    update_popup_lifecycle()
    if s_pick ~= nil then
        local ok, err = pcall(s_pick.update)
        if not ok then
            log("BUG 3D clicks stopped (" .. tostring(err) .. "). Report on GitHub with Log.txt; keys still work from the popup and bindings.")
            pcall(s_pick.disable)
            s_pick = nil
        end
    end
    -- Negative intervals are flight-loop counts, not seconds. -1 requests the
    -- next flight loop and is required for smooth one-second display fades.
    return -1.0
end

local destroy_atlas

local function create_atlas()
    s_atlas = XPLMCreateTextureAtlas()
    if s_atlas == nil then
        log("BUG popup bezel: texture atlas could not be created. Report on GitHub with Log.txt.")
        return false
    end

    local base_path = resource_path(BASE_IMAGE)
    local lit_path = resource_path(LIT_IMAGE)

    local ok_base, base_image = pcall(XPLMTextureAtlasAddImageFile, s_atlas, base_path)
    local ok_lit, lit_image = pcall(XPLMTextureAtlasAddImageFile, s_atlas, lit_path)
    if not ok_base or base_image == nil or not ok_lit or lit_image == nil then
        log("INSTALL popup bezel images missing or unreadable (" .. base_path .. ", " .. lit_path .. "); a plain bezel is drawn. Local fix: reinstall the package folder.")
        destroy_atlas()
        return false
    end

    s_base_image = base_image
    s_lit_image = lit_image

    local ok_bake, bake_error = pcall(XPLMTextureAtlasBake, s_atlas)
    if not ok_bake then
        log("BUG popup bezel: texture atlas bake failed (" .. tostring(bake_error) .. "). Report on GitHub with Log.txt.")
        destroy_atlas()
        return false
    end

    return true
end

destroy_atlas = function()
    if s_atlas ~= nil then XPLMDestroyTextureAtlas(s_atlas) end
    s_atlas = nil
    s_base_image = nil
    s_lit_image = nil
end

-- Undoes XPluginEnable (also a half-finished one).
local function teardown_enable()
    s_xlua_loaded = 0
    -- Take this unit's current back off the bus (the flight loop stops here).
    if s_unit.bus_load_amps ~= 0.0 then
        local load = get_float_array_value(s_dr.bus_load, s_config.power_bus, nil)
        if load ~= nil then
            pcall(XPLMSetDatavf, s_dr.bus_load, { math.max(0.0, load - s_unit.bus_load_amps) }, s_config.power_bus, 1)
        end
        s_unit.bus_load_amps = 0.0
    end
    if s_pick ~= nil then pcall(s_pick.disable) end
    s_reg.windows = 0
    if s_flight_loop ~= nil then
        pcall(XPLMDestroyFlightLoop, s_flight_loop)
        s_flight_loop = nil
    end
    destroy_popup("plugin disable")
    destroy_device(s_device_3d)
    s_device_3d = nil
    -- A key held across Disable never sends its End to this unit. An OFF
    -- hold already fading finishes (the unit goes off); one still being held
    -- is let go, so Enable does not shut the unit down at once. An IDENT End
    -- arriving after a re-Enable is then kept from X-Plane.
    if s_unit.shutdown_fade_started_at > 0.0 then power_off("OFF held through Disable") end
    s_unit.off_hold_active = false
    s_unit.off_hold_started_at = 0.0
    s_unit.func_held = false
    s_unit.popup_key = nil
    s_unit.pressed_button_identifier = 0
    s_unit.last_touch_identifier = 0
    s_unit.ident_passed = false
    -- key_light outlives Enable (stage "start"): no flight loop, no lamps
    s_render.bezel_lit_alpha = 0.0
    -- the pilot's levels, code, mode and ACCUMULATE flight time, if they
    -- changed in the last few seconds
    if s_setup ~= nil then
        local accumulate = s_config.flight_timer_mode ~= FLIGHT_TIMER_MANUAL and s_config.flight_timer_mode ~= FLIGHT_TIMER_CLEAR
        pcall(s_setup.pilot_flush, s_unit.active_code,
            s_unit.power_state == POWER_OPERATING and s_unit.selected_mode or nil,
            accumulate and s_unit.flight_time or 0.0)
    end
    release_registrations("enable")
end

-- Undoes everything. xLua can stop a script without disabling it (after a
-- failed XPluginEnable), so XPluginStop goes through teardown_enable too.
local function teardown_all()
    teardown_enable()
    release_registrations(nil)
    s_button_commands = {}
    destroy_atlas()
    s_pick = nil
    s_setup = nil
    s_raster = nil
    s_lcd_foreground = nil
    s_lcd_background = nil
    s_clear_black = nil
end

local function start()
    find_input_datarefs()
    -- gtx327_config.ini and the configuration mode. Without the module the
    -- unit runs on the factory values above and has no configuration mode.
    local setup_error = nil
    s_setup, setup_error = load_module("gtx327_setup.lua")
    if s_setup ~= nil then
        local factory = {}
        for key, value in pairs(s_config) do factory[key] = value end
        local ok, err = pcall(function()
            s_setup.init({ log = log, path = resource_path(CONFIG_FILE) }, s_config)
            s_setup.load()
        end)
        if not ok then
            -- half a file read is worse than none: back to the factory values
            for key in pairs(s_config) do s_config[key] = nil end
            for key, value in pairs(factory) do s_config[key] = value end
            s_setup = nil
            log("BUG gtx327_setup.lua failed (" .. tostring(err) .. "); Garmin factory values in use,"
                .. " no configuration mode. Report on GitHub with Log.txt.")
        end
    else
        log("INSTALL gtx327_setup.lua missing or damaged (" .. tostring(setup_error) .. "); Garmin factory values in use, no configuration mode. Local fix: reinstall the package folder.")
    end
    initialize_unit_state()

    -- Day LCD colours sampled from footage of a real unit.
    s_lcd_foreground = XPLMMakeColor(0.13, 0.24, 0.01, 1.0)
    s_lcd_background = XPLMMakeColor(0.79, 0.92, 0.28, 1.0)
    s_clear_black = XPLMMakeColor(0.0, 0.0, 0.0, 1.0)

    local raster_path = resource_path(RASTER_DATA_FILE)
    -- XLua 2.0 wraps dofile and discards the executed chunk's return value.
    -- loadfile keeps the generated raster data as a separate source file while
    -- still allowing this script to receive its module table directly.
    local ok_load, raster_chunk_or_error = pcall(loadfile, raster_path)
    local ok_raster = false
    local raster_or_error = raster_chunk_or_error
    if ok_load and type(raster_chunk_or_error) == "function" then
        ok_raster, raster_or_error = pcall(raster_chunk_or_error)
        -- the generated file also sets this global (for the dofile path)
        GTX327_RASTER_MODULE = nil
    else
        GTX327_RASTER_MODULE = nil
        ok_raster, raster_or_error = pcall(dofile, raster_path)
        if ok_raster and type(raster_or_error) ~= "table" then
            raster_or_error = GTX327_RASTER_MODULE
        end
        GTX327_RASTER_MODULE = nil
    end
    if not ok_raster or type(raster_or_error) ~= "table" then
        error("raster module load FAILED: " .. tostring(raster_or_error), 0)
    end
    s_raster = raster_or_error

    -- Mouse clicks on the 3D unit. X-Plane only clicks manipulators in the
    -- aircraft's own cockpit object, so gtx327_pick.lua picks GTX327.obj itself.
    local pick_error = nil
    s_pick, pick_error = load_module("gtx327_pick.lua")
    if s_pick ~= nil then
        local ok, err = pcall(s_pick.init, { log = log }, s_config)
        if not ok then
            s_pick = nil
            log("BUG gtx327_pick.lua failed (" .. tostring(err) .. "); no 3D clicks (the popup and bindings"
                .. " still work). Report on GitHub with Log.txt.")
        end
    else
        log("INSTALL gtx327_pick.lua missing or damaged (" .. tostring(pick_error) .. "); no 3D clicks. Local fix: reinstall the package folder.")
    end

    local ok_atlas, atlas_error = pcall(create_atlas)
    if not ok_atlas then
        pcall(destroy_atlas)
        log("BUG popup bezel failed (" .. tostring(atlas_error) .. "); a plain bezel is drawn."
            .. " Report on GitHub with Log.txt.")
    end

    -- Core registrations last, so a refusal leaves nothing else to undo.
    reg_int(DREF_PREFIX .. "installed", s_diag_read.installed, "start")
    reg_int(DREF_PREFIX .. "key_light", s_diag_read.key_light, "start", true)
    create_commands()
end

local function enable()
    update_render_state()

    s_device_3d = create_device(make_device_params(DEVICE_ID_3D, "Garmin GTX 327", "cockpit"))
    XPLMSetAvionicsPopupVisible(s_device_3d, false)

    local flight_loop = XPLMCreateFlightLoop({
        phase = XPLMFlightLoopPhaseType.xplm_FlightLoop_Phase_AfterFlightModel,
        callbackFunc = guarded("flight loop", flight_loop_cb, -1.0),
        refcon = nil
    })
    assert(flight_loop ~= nil, "XPLMCreateFlightLoop")
    s_flight_loop = flight_loop
    XPLMScheduleFlightLoop(s_flight_loop, -1.0, true)

    -- Clicks are not worth the unit: a refused click window costs only the
    -- 3D clicks (the popup and bindings still work).
    if s_pick ~= nil then
        local model = XPLMGetNthAircraftModel(XPLM_USER_AIRCRAFT)
        local acf = normalize_path(type(model) == "table" and unwrap_string(model.outPath) or "")
        local ok, err = pcall(s_pick.load, s_script_dir .. "/3D/GTX327.obj", acf)
        if ok then ok, err = pcall(s_pick.enable) end
        if ok then
            s_reg.windows = s_pick.windows()
        elseif tostring(err):find("callbacks", 1, true) then
            -- xLua: "... has persisted more than 500 callbacks ..."
            log("INSTALL 3D clicks could not start (" .. tostring(err) .. "): X-Plane refused the click window,"
                .. " the aircraft's xLua callback budget is used up by other scripts. Local fix: free callbacks.")
            -- The OK line then says off, not "on: 1 window(s)"
            pcall(s_pick.disable, "X-Plane refused the click window (INSTALL line above)")
        else
            log("BUG 3D clicks could not start (" .. tostring(err) .. "); the popup and bindings still work."
                .. " Report on GitHub with Log.txt.")
            pcall(s_pick.disable, "failed to start (BUG line above)")
        end
    end
end

-- Start / Enable failed and everything was released. A missing file or a
-- refused registration (the shared xLua callback budget) is the aircraft's
-- install; anything else is a fault of the unit.
local function report_failure(stage, err)
    local text = tostring(err)
    if text:find("raster module load", 1, true) then
        log("INSTALL " .. stage .. " failed: gtx327_raster.lua missing or damaged (" .. text
            .. "). Local fix: reinstall the package folder. The stock transponder (if any) stays usable.")
    elseif text:find("^dataref " .. DREF_PREFIX .. "installed") or text:find("XPLMCreateAvionicsEx " .. DEVICE_ID_3D .. ":", 1, true) then
        -- the names a second copy of this package would register again
        log("INSTALL " .. stage .. " failed: X-Plane refused a registration (" .. text
            .. "): a second GTX 327 in this aircraft (one per aircraft), or the aircraft's xLua callback"
            .. " budget used up by other scripts. Local fix: remove the second custom_device_GTX327 folder,"
            .. " or free callbacks. The stock transponder (if any) stays usable.")
    elseif text:find("^dataref ") or text:find("XPLMCreateAvionicsEx", 1, true)
        or text:find("^command handler: ") or text:find("persisted more than", 1, true) then
        -- reg_int / reg_cmd / create_device name what was refused; xLua's
        -- own budget error ("... has persisted more than 500 callbacks") covers
        -- the flight loop. Any other text is a fault of the unit.
        log("INSTALL " .. stage .. " failed: X-Plane refused a registration (" .. text
            .. "): the aircraft's xLua callback budget is probably used up by other scripts."
            .. " Local fix: free callbacks. The stock transponder (if any) stays usable.")
    else
        log("BUG " .. stage .. " failed (" .. text .. "). Report on GitHub with Log.txt."
            .. " The stock transponder (if any) stays usable.")
    end
end

function XPluginStart()
    local ok, err = pcall(start)
    if not ok then
        report_failure("start", err)
        teardown_all()
        return false
    end
    return true
end

function XPluginStop()
    teardown_all()
end

function XPluginEnable()
    local ok, err = pcall(enable)
    if not ok then
        report_failure("enable", err)
        teardown_enable()
        return false
    end
    s_xlua_loaded = 1
    -- The unit is there: its code (loaded at Start) goes into X-Plane now. A
    -- refused Enable leaves X-Plane, and a stock transponder, the aircraft's.
    if s_unit.code_to_sim then
        s_unit.code_to_sim = false
        set_int(s_dr.transponder_code, s_unit.active_code)
    end

    -- debug_mode opens the popup on enable so a load is visible at once;
    -- otherwise laminar/gtx327/popup_toggle (OBJ hotspot) opens it.
    if s_config.debug_mode then show_popup() end
    local registered, wanted = register_optional()
    log(string.format("OK version %d in %s: %d xLua callbacks (optional %d of %d); 3D clicks %s%s",
        BASELINE_VERSION, tostring(s_script_dir), live_callbacks(), registered, wanted,
        s_pick ~= nil and s_pick.status() or "off: gtx327_pick.lua not loaded",
        s_config.debug_mode and "; DEBUG MODE ON (aircraft power ignored)" or ""))
    return true
end

function XPluginDisable()
    teardown_enable()
end

local MSG_PLANE_LOADED = XPLM_MSG_PLANE_LOADED or 102
local MSG_AIRPORT_LOADED = XPLM_MSG_AIRPORT_LOADED or 103

function XPluginReceiveMessage(from, message, param)
    if from ~= XPLM_PLUGIN_XPLANE then return end
    -- A new flight does not restart XLua. Relocating must not read as a
    -- lift-off or touchdown (CLEAR reset, auto ALT/STBY). The code is the
    -- unit's own memory (pilot's guide: the last active code): a code the new
    -- situation set is written over. Outside writes after this are followed
    -- as usual.
    if message == MSG_AIRPORT_LOADED
        or (message == MSG_PLANE_LOADED and (param == 0 or param == nil))
    then
        cancel_code_entry("new flight")
        cancel_count_down_entry("new flight")
        s_unit.post_entry_until = 0.0
        s_unit.airborne_known = false
        s_unit.ground_since = nil
        s_unit.last_run_time = nil
        if s_device_3d ~= nil then set_int(s_dr.transponder_code, s_unit.active_code) end
        -- X-Plane clears plugin_bus_load_amps for a new flight: the next
        -- frame adds this unit's whole current again
        s_unit.bus_load_amps = 0.0
    end
end
