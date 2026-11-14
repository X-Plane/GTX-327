--[[
GTX 327 plugin-side click picking ("compatibility mode"), a general module
shared with other xLua instruments. The native-click marker counts only on
ATTR_manip_* lines.

X-Plane only picks OBJ manipulators from the aircraft's ONE cockpit object
(OBJ8 spec: "Only triangles in the cockpit object can be in the manipulation
plane"). GTX327.obj is attached as an ordinary object so that any aircraft can
take it without giving up its own cockpit object; its manipulators are
therefore ignored by X-Plane, and this module emulates them:

  * GTX327.obj is read at start-up: every ATTR_manip_* batch (type, cursor,
    commands, triangles with the static part of their animation).
  * The .acf is read for the slot(s) that attach GTX327.obj: offset, rotation,
    hide dataref. Plugin picking switches itself off for a slot that X-Plane
    can already pick natively (the slot IS the cockpit object, or the host
    cockpit object already carries the unit's click regions), so nothing ever
    fires twice.
  * Every frame the manipulator groups (one for the GTX: all its click batches sit in one
    ANIM block of GTX327.obj) are projected with
    the 3D-cockpit camera; one small, invisible, undecorated window is laid
    tightly over each group (clipped to the screen; any size, so a zoomed-in
    view keeps its clicks). Nothing of the host aircraft outside those
    rectangles is ever covered.
  * Seen at an angle the unit is a slanted shape, and its upright rectangle
    reaches over its neighbours (a radio stacked below took the GTX's 0 and
    1 keys). So every frame: with the mouse over the unit's
    outline (convex hull of the click regions) the window comes to the front
    once; with the mouse inside the rectangle but off the outline the window
    steps aside, and the click goes to whatever is below (another unit's
    window, or the host). Misses between the keys stay swallowed. Same rule
    for every unit that uses this recipe; no click pass-through (the SDK
    warns it breaks mouse tracking).
  * The camera is the one of the frame on screen, read in the window's draw
    callback: the G-loaded camera and head tracking move the drawn view away
    from the pilot's head datarefs (pull-ups, turns and bumps put the clicks
    beside the keys).
  * Inside a window, the mouse ray is intersected with the manipulator
    triangles: a hit fires the command (Begin on mouse down, End on mouse up,
    like X-Plane's own manipulators) and sets the cursor. Mouse wheel turns
    the knob.

Touch screen (general; the GTX 327 has none): an ATTR_manip_device batch (the screen triangles)
is picked the same way; the hit's barycentric position gives the screen UV,
i.e. the device framebuffer pixel, which goes to P.on_touch(phase, x, y)
("down" / "drag" / "up", framebuffer px, y up). While a touch is held the
mouse ray is intersected with the touched triangle's plane, so a drag keeps
reporting (extrapolated) positions after it leaves the glass. The wheel over
the screen goes to P.on_wheel(x, y, clicks).

Limits: 3D cockpit view only (no VR controllers, no external views); host
geometry in front of the unit does not block it; only ANIM_trans offsets are
applied (rotations are ignored, fine for round knobs).
--]]

local P = {}

local U, log, config
local FT = 0.3048

local slots = {}        -- attached GTX327.obj instances: base offset (m, CG frame), rotation, hide dataref
local groups = {}       -- manipulator groups: { batches = {...}, corners = {...}, win = window }
local active = nil      -- { cmd = ref } command held by the current click
local dr = {}
local enabled = false
local status = "off"

-----------------------------------------------------------------------------
-- small vector helpers (tables {x, y, z})
-----------------------------------------------------------------------------

local sin, cos, rad, tan = math.sin, math.cos, math.rad, math.tan

local function rot_x(v, a) local c, s = cos(a), sin(a); return { v[1], v[2] * c - v[3] * s, v[2] * s + v[3] * c } end
local function rot_y(v, a) local c, s = cos(a), sin(a); return { v[1] * c + v[3] * s, v[2], -v[1] * s + v[3] * c } end
local function rot_z(v, a) local c, s = cos(a), sin(a); return { v[1] * c - v[2] * s, v[1] * s + v[2] * c, v[3] } end

-- X-Plane heading/pitch/roll (deg) -> rotation of a vector from the rotated
-- frame into the parent frame; inverse undoes it. Same convention for the
-- pilot's head and for attached objects (heading CW, pitch up, roll right).
local function to_parent(v, psi, the, phi) return rot_y(rot_x(rot_z(v, -rad(phi)), rad(the)), -rad(psi)) end
local function to_child(v, psi, the, phi) return rot_z(rot_x(rot_y(v, rad(psi)), -rad(the)), rad(phi)) end

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

-- Moller-Trumbore, both faces; returns distance along the ray and the
-- barycentric (u, v) of the hit, or nil. unbounded: hit the triangle's plane
-- anywhere (drags that leave the glass).
local function ray_tri(o, d, a, b, c, unbounded)
    local e1, e2 = sub(b, a), sub(c, a)
    local p = cross(d, e2)
    local det = dot(e1, p)
    if math.abs(det) < 1e-12 then return nil end
    local inv = 1 / det
    local t = sub(o, a)
    local u = dot(t, p) * inv
    if not unbounded and (u < 0 or u > 1) then return nil end
    local q = cross(t, e1)
    local v = dot(d, q) * inv
    if not unbounded and (v < 0 or u + v > 1) then return nil end
    local dist = dot(e2, q) * inv
    if dist <= 0 then return nil end
    return dist, u, v
end

-----------------------------------------------------------------------------
-- Files
-----------------------------------------------------------------------------

local function norm_path(p)
    p = (p or ""):gsub("\\", "/")
    local out = {}
    for part in p:gmatch("[^/]+") do
        if part == ".." and #out > 0 and out[#out] ~= ".." then
            out[#out] = nil
        elseif part ~= "." then
            out[#out + 1] = part
        end
    end
    local lead = p:match("^/") and "/" or ""
    return lead .. table.concat(out, "/")
end

local CURSORS = {
    four_arrows = "xplm_CursorFourArrows", hand = "xplm_CursorHandle", button = "xplm_CursorButton",
    rotate_small = "xplm_CursorRotateSmall", rotate_small_left = "xplm_CursorRotateSmallLeft",
    rotate_small_right = "xplm_CursorRotateSmallRight", rotate_medium = "xplm_CursorRotateMedium",
    rotate_medium_left = "xplm_CursorRotateMediumLeft", rotate_medium_right = "xplm_CursorRotateMediumRight",
    rotate_large = "xplm_CursorRotateLarge", rotate_large_left = "xplm_CursorRotateLargeLeft",
    rotate_large_right = "xplm_CursorRotateLargeRight", up_down = "xplm_CursorUpDown", down = "xplm_CursorDown",
    up = "xplm_CursorUp", left_right = "xplm_CursorLeftRight", left = "xplm_CursorLeft", right = "xplm_CursorRight",
    arrow = "xplm_CursorArrow",
}

local function cursor_id(name)
    local key = CURSORS[name or ""] or "xplm_CursorHandle"
    return (XPLMCursorStatus and XPLMCursorStatus[key]) or 0
end

-- manipulator line -> { kind = "hold" | "pair", axis = "x" | "y", cursor, cmds = { name... } }
local function parse_manip(p)
    local k = p[1]
    if k == "ATTR_manip_command" or k == "ATTR_manip_command_knob2" then
        return { kind = "hold", cursor = p[2], cmds = { p[3] } }
    elseif k == "ATTR_manip_command_switch_left_right" or k == "ATTR_manip_command_switch_left_right2"
        or k == "ATTR_manip_command_knob" then
        return { kind = "pair", axis = "x", cursor = p[2], cmds = { p[3], p[4] } }
    elseif k == "ATTR_manip_command_switch_up_down" or k == "ATTR_manip_command_switch_up_down2" then
        return { kind = "pair", axis = "y", cursor = p[2], cmds = { p[3], p[4] } }
    elseif k == "ATTR_manip_device" then
        -- ATTR_manip_device <cursor> <device> <tooltip>: the touch screen
        return { kind = "screen", cursor = p[2], cmds = {}, device = p[3] }
    end
    return nil
end

-- manipulator batches, vertices in OBJ-local metres incl. static ANIM_trans;
-- screen batches also keep the vertex UVs
local function read_obj(path)
    local f = io.open(path, "r")
    if not f then return nil, "cannot open " .. path end
    local vt, idx, batches = {}, {}, {}
    local stack = { { 0, 0, 0 } }
    local manip, top_group, group_seq = nil, 0, 0
    for line in f:lines() do
        local p = {}
        for w in line:gmatch("%S+") do p[#p + 1] = w end
        local k = p[1]
        if k == "VT" then
            vt[#vt + 1] = { tonumber(p[2]), tonumber(p[3]), tonumber(p[4]), tonumber(p[8]) or 0, tonumber(p[9]) or 0 }
        elseif k == "IDX" or k == "IDX10" then
            for i = 2, #p do idx[#idx + 1] = tonumber(p[i]) end
        elseif k == "ANIM_begin" then
            if #stack == 1 then group_seq = group_seq + 1; top_group = group_seq end
            local t = stack[#stack]
            stack[#stack + 1] = { t[1], t[2], t[3] }
        elseif k == "ANIM_end" then
            stack[#stack] = nil
            if #stack == 1 then top_group = 0 end
        elseif k == "ANIM_trans" then
            local t = stack[#stack]
            t[1], t[2], t[3] = t[1] + tonumber(p[2]), t[2] + tonumber(p[3]), t[3] + tonumber(p[4])
        elseif k and k:sub(1, 11) == "ATTR_manip_" then
            manip = (k ~= "ATTR_manip_none") and parse_manip(p) or nil
        elseif k == "TRIS" and manip then
            local first, count = tonumber(p[2]), tonumber(p[3])
            local off = stack[#stack]
            local tris = {}
            for i = first, first + count - 1, 3 do
                local tri = { uv = {} }
                for j = 0, 2 do
                    local v = vt[idx[i + j + 1] + 1]
                    tri[j + 1] = { v[1] + off[1], v[2] + off[2], v[3] + off[3] }
                    tri.uv[j + 1] = { v[4], v[5] }
                end
                tris[#tris + 1] = tri
            end
            batches[#batches + 1] = {
                kind = manip.kind, axis = manip.axis, cursor = manip.cursor, cmd_names = manip.cmds,
                tris = tris,
                -- batches outside any animation are their own group
                group = (top_group ~= 0) and top_group or (1000 + #batches),
            }
        end
    end
    f:close()
    return batches
end

local function read_acf(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local obja = {}
    local root = {}
    for line in f:lines() do
        local n, key, val = line:match("^P _obja/(%d+)/(%S+) (.*)$")
        if n then
            n = tonumber(n)
            obja[n] = obja[n] or {}
            obja[n][key] = val:gsub("%s+$", "")
        else
            local k2, v2 = line:match("^P acf/(%S+) (.*)$")
            if k2 == "_cgY" or k2 == "_cgZ" then root[k2] = tonumber(v2) end
        end
    end
    f:close()
    return obja, root
end

-- true if a manipulator line (ATTR_manip_*) of the OBJ names the marker; other
-- mentions (a hide dataref, a comment) do not count as native click regions
local function file_contains(path, needle)
    local f = io.open(path, "r")
    if not f then return false end
    for line in f:lines() do
        if line:match("^%s*ATTR_manip_") and line:find(needle, 1, true) then
            f:close()
            return true
        end
    end
    f:close()
    return false
end

-----------------------------------------------------------------------------
-- Datarefs
-----------------------------------------------------------------------------

-- the handle; a missing name goes on the list `missing` (if given)
local function find(name, missing)
    local h = XPLMFindDataRef(name)
    if h == nil and missing then missing[#missing + 1] = name end
    return h
end

local scratch = {}

-- "path[3]" or "path" -> number, any type
local function read_any(h, index)
    if h == nil then return 0 end
    local t = XPLMGetDataRefTypes(h)
    if index then
        if t % 16 >= 8 then -- float array bit
            if XPLMGetDatavf(h, scratch, index, 1) == 1 then return scratch[1] or 0 end
        elseif t % 32 >= 16 then
            if XPLMGetDatavi(h, scratch, index, 1) == 1 then return scratch[1] or 0 end
        end
        return 0
    end
    if t % 4 >= 2 then return XPLMGetDataf(h) end
    if t % 2 >= 1 then return XPLMGetDatai(h) end
    if t % 8 >= 4 then return XPLMGetDatad(h) end
    return 0
end

local function hide_ref(spec)
    if not spec or spec == "" or spec == "none" then return nil end
    local name, index = spec:match("^(.-)%[(%d+)%]$")
    name = name or spec
    local h = XPLMFindDataRef(name)
    if h == nil then return nil end
    return { h = h, index = index and tonumber(index) or nil }
end

-----------------------------------------------------------------------------
-- Camera
-----------------------------------------------------------------------------

local cam = { ok = false }
local proj_m = {}
-- the screen bounds taken for the 3D view have X-Plane's window shape: nil
-- before the first look, then true / false (each change logs once per load);
-- l / t / r / b, since, asked, monitors: the full-screen monitor count for
-- that desktop (fullscreen_monitors)
local view_fits = { now = nil, logged_off = false, logged_on = false }

-- the camera of the last frame drawn (CG frame), read in the click window's
-- draw callback: pos, axes,
-- projection, off (from the pilot's head), t (XPLMGetElapsedTime, s)
local drawn = { t = nil }
-- older than this (the window not shown for a while): the head and the flight loop
local DRAWN_MAX_AGE_S = 0.25
-- the drawn camera this far from the pilot's head is not the cockpit's (a
-- G-load or head-tracking move is centimetres)
local DRAWN_MAX_OFF_M = 0.5
-- older than DRAWN_MAX_AGE_S but younger than this: the head plus the last
-- drawn offset from it (the window steps aside under the mouse and stops the
-- readings; a camera jump back to the head would move its outline)
local DRAWN_HOLD_S = 2

local function num(x) return tonumber(tostring(x)) or 0 end

local function now() return XPLMGetElapsedTime and num(XPLMGetElapsedTime()) or nil end

local function bounds()
    local b = XPLMGetScreenBoundsGlobal()
    if type(b) == "table" then
        return num(b.outLeft or b[1]), num(b.outTop or b[2]), num(b.outRight or b[3]), num(b.outBottom or b[4])
    end
    return 0, 0, 0, 0
end

-- mouse in global boxels, or nil
local function mouse_xy()
    if not XPLMGetMouseLocationGlobal then return nil end
    local m = XPLMGetMouseLocationGlobal()
    if type(m) ~= "table" then return nil end
    return num(m.outX or m[1]), num(m.outY or m[2])
end

-- The projection X-Plane really used for the last 3D frame. It includes the
-- mouse-wheel zoom, which field_of_view_deg does not (zoomed 72.5 deg showed
-- as 38 deg). OpenGL column-major: m[0] = 1/tan_h, m[5] = 1/tan_v, m[8]/m[9]
-- = frustum shift. Into c; false if not readable.
local function read_projection(c)
    local m = proj_m
    local ok = dr.proj and XPLMGetDatavf(dr.proj, m, 0, 16) == 16
        and m[1] and m[6] and m[1] > 0.05 and m[6] > 0.05 and m[11]
    -- A readable matrix with m[10] not negative (reverse Z, another
    -- layout or NaN; seen on no X-Plane yet): the field of view stands in, if
    -- X-Plane has it. Said once per load.
    local layout_ok = ok and m[11] < 0
    if ok and not layout_ok and not view_fits.logged_proj then
        view_fits.logged_proj = true
        log(string.format("NOTE 3D clicks: X-Plane's projection_matrix_3d has m[10] = %.3f (not the OpenGL"
            .. " layout expected); %s Report on GitHub with Log.txt.", m[11],
            (dr.fov and dr.fov_hr and dr.fov_vr)
                and "clicks use field_of_view_deg and miss when zoomed with the mouse wheel."
                or "no field_of_view_deg either, so no 3D clicks (the popup and bindings still work)."))
    end
    if not layout_ok then return false end
    c.tan_h, c.tan_v = 1 / m[1], 1 / m[6]
    c.shift_x, c.shift_y = -m[9], -m[10]
    return true
end

-- How many monitors X-Plane runs full screen on (0 in a window); nil if
-- X-Plane cannot say. Asked once the global desktop has kept the same bounds
-- for MONITORS_SETTLE_S (a window dragged to a new size asks once, not every
-- frame), always with the one count_monitor: xLua 2.0.0a1 keeps every
-- function handed to the SDK.
local MONITORS_SETTLE_S = 1
local function count_monitor() view_fits.counted = view_fits.counted + 1 end
local function fullscreen_monitors(l, t, r, b)
    local v = view_fits
    if v.l ~= l or v.t ~= t or v.r ~= r or v.b ~= b then
        v.l, v.t, v.r, v.b, v.since, v.asked = l, t, r, b, now(), false
    end
    if not v.asked then
        local tn = now()
        if tn and v.since and tn >= v.since and tn - v.since < MONITORS_SETTLE_S then return v.monitors end
        v.asked, v.monitors, v.counted = true, nil, 0
        if XPLMGetAllMonitorBoundsGlobal and pcall(XPLMGetAllMonitorBoundsGlobal, count_monitor, nil) then
            v.monitors = v.counted
        end
    end
    return v.monitors
end

local function update_camera()
    cam.ok = false
    if XPLMGetDatai(dr.view_type) ~= 1026 then return end          -- 3D cockpit only
    if dr.vr and XPLMGetDatai(dr.vr) ~= 0 then return end
    local l, t, r, b = bounds()
    if r - l < 10 or t - b < 10 then return end
    local ww, wh = XPLMGetDatai(dr.win_w), XPLMGetDatai(dr.win_h)
    -- More than 2 % apart in shape: the global desktop is not the 3D view (a
    -- full-screen X-Plane over several monitors, or an odd windowed / high-DPI
    -- layout). The click window would sit beside the keys, so no clicks.
    -- Same shape is not enough: 2 x 2 equal monitors are 16:9 too. Sizes cannot
    -- be compared (desktop in boxels, 3D view in pixels, 150 % / 200 % UI), so
    -- also ask X-Plane how many monitors it fills.
    local shape_ok = not (ww > 0 and wh > 0) or math.abs((r - l) / (t - b) / (ww / wh) - 1) <= 0.02
    local many = shape_ok and (fullscreen_monitors(l, t, r, b) or 0) > 1
    local fits = shape_ok and not many
    if fits ~= view_fits.now then
        if not fits and not view_fits.logged_off then
            view_fits.logged_off = true
            log(string.format("NOTE 3D clicks off: the screen is %.0f x %.0f but X-Plane's 3D view %.0f x %.0f%s"
                .. " (several monitors?); the popup and bindings still work.", r - l, t - b, ww, wh,
                many and string.format(", full screen on %d monitors", view_fits.monitors) or ""))
        elseif fits and view_fits.now == false and not view_fits.logged_on then
            view_fits.logged_on = true
            log(string.format("NOTE 3D clicks back on: screen and 3D view both %.0f x %.0f.", ww, wh))
        end
        view_fits.now = fits
    end
    if not fits then return end
    local aspect = (ww > 0 and wh > 0) and (ww / wh) or ((r - l) / (t - b))
    cam.l, cam.t, cam.r, cam.b = l, t, r, b
    if not read_projection(cam) then
        if not (dr.fov and dr.fov_hr and dr.fov_vr) then return end   -- 12.4.4+ has the matrix
        cam.tan_h = tan(rad(XPLMGetDataf(dr.fov) * 0.5))
        cam.tan_v = cam.tan_h / aspect
        cam.shift_x = XPLMGetDataf(dr.fov_hr) * 2      -- frustum shift, 1 = one screen width
        cam.shift_y = XPLMGetDataf(dr.fov_vr) * 2
    end
    -- a frame drawn just now: its camera (G-loaded camera, head tracking)
    local tn = now()
    if drawn.t and tn and tn >= drawn.t and tn - drawn.t <= DRAWN_MAX_AGE_S then
        cam.pos, cam.ax_r, cam.ax_u, cam.ax_b = drawn.pos, drawn.ax_r, drawn.ax_u, drawn.ax_b
        if drawn.tan_h then
            cam.tan_h, cam.tan_v, cam.shift_x, cam.shift_y = drawn.tan_h, drawn.tan_v, drawn.shift_x, drawn.shift_y
        end
        cam.ok = true
        return
    end
    -- position: the pilot's head in the aircraft frame (exact; the world-space
    -- view_x/y/z floats lose millimetres far from the local origin; without the
    -- G-loaded camera's movement), plus the last drawn offset for a while
    cam.pos = { XPLMGetDataf(dr.hx), XPLMGetDataf(dr.hy), XPLMGetDataf(dr.hz) }
    if drawn.off and tn and tn >= drawn.t and tn - drawn.t <= DRAWN_HOLD_S then
        cam.pos = add(cam.pos, drawn.off)
    end
    -- orientation: the camera X-Plane really rendered (world view angles, which
    -- include the aircraft attitude), brought into the aircraft frame. The head
    -- angles alone were off by ~25 px at large head yaw with the aircraft pitched.
    local vh, vp, vr = XPLMGetDataf(dr.vhdg), XPLMGetDataf(dr.vpitch), XPLMGetDataf(dr.vroll)
    local ah, ap, ar = XPLMGetDataf(dr.apsi), XPLMGetDataf(dr.athe), XPLMGetDataf(dr.aphi)
    local function axis(v) return to_child(to_parent(v, vh, vp, vr), ah, ap, ar) end
    cam.ax_r, cam.ax_u, cam.ax_b = axis({ 1, 0, 0 }), axis({ 0, 1, 0 }), axis({ 0, 0, 1 })
    cam.ok = true
end

-- In the click window's draw callback: the camera of the frame on screen. View
-- angles and attitude of the same frame give the axes, the projection of the
-- same frame goes with them (a zoom in progress). Position: view_x/y/z -
-- local_x/y/z turned into the aircraft frame (the head moved by the G-loaded
-- camera, head tracking, a view change on its way); the pilot's head (exact)
-- when that is within the float step of view_x/y/z (millimetres far from the
-- local origin) or not the cockpit camera.
local function capture_camera()
    if XPLMGetDatai(dr.view_type) ~= 1026 then return end
    local t = now()
    if not t then return end
    local vh, vp, vr = XPLMGetDataf(dr.vhdg), XPLMGetDataf(dr.vpitch), XPLMGetDataf(dr.vroll)
    local ah, ap, ar = XPLMGetDataf(dr.apsi), XPLMGetDataf(dr.athe), XPLMGetDataf(dr.aphi)
    local function axis(v) return to_child(to_parent(v, vh, vp, vr), ah, ap, ar) end
    local head = { XPLMGetDataf(dr.hx), XPLMGetDataf(dr.hy), XPLMGetDataf(dr.hz) }
    local pos = head
    if dr.vx and dr.vy and dr.vz and dr.lx and dr.ly and dr.lz then
        local vx, vy, vz = XPLMGetDataf(dr.vx), XPLMGetDataf(dr.vy), XPLMGetDataf(dr.vz)
        -- local_x/y/z as doubles (the float drops millimetres)
        local getd = XPLMGetDatad or XPLMGetDataf
        local p = to_child({ vx - getd(dr.lx), vy - getd(dr.ly), vz - getd(dr.lz) }, ah, ap, ar)
        local off = sub(p, head)
        local d = math.sqrt(dot(off, off))
        local step = math.max(math.abs(vx), math.abs(vy), math.abs(vz)) / 8388608      -- 2^-23
        if d > 2 * step and d <= DRAWN_MAX_OFF_M then
            pos = p
            if not drawn.moved then
                drawn.moved = true
                log(string.format("NOTE 3D clicks follow the drawn view (%.0f mm from the pilot's head:"
                    .. " G-loaded camera or head tracking).", d * 1000))
            end
        end
    end
    drawn.off = sub(pos, head)
    drawn.pos, drawn.t = pos, t
    drawn.ax_r, drawn.ax_u, drawn.ax_b = axis({ 1, 0, 0 }), axis({ 0, 1, 0 }), axis({ 0, 0, 1 })
    if not read_projection(drawn) then drawn.tan_h = nil end
    -- the clicks that come before the next flight loop
    if cam.ok then
        cam.pos, cam.ax_r, cam.ax_u, cam.ax_b = drawn.pos, drawn.ax_r, drawn.ax_u, drawn.ax_b
        if drawn.tan_h then
            cam.tan_h, cam.tan_v, cam.shift_x, cam.shift_y = drawn.tan_h, drawn.tan_v, drawn.shift_x, drawn.shift_y
        end
    end
end

-- CG-frame vector -> camera frame (x right, y up, z toward the viewer)
local function cam_local(v)
    return { dot(v, cam.ax_r), dot(v, cam.ax_u), dot(v, cam.ax_b) }
end

-- CG-frame point -> global boxels, or nil if behind the camera
local function project(p)
    local c = cam_local(sub(p, cam.pos))
    if c[3] > -1e-4 then return nil end
    local nx = (c[1] / -c[3]) / cam.tan_h + cam.shift_x
    local ny = (c[2] / -c[3]) / cam.tan_v + cam.shift_y
    return cam.l + (nx * 0.5 + 0.5) * (cam.r - cam.l), cam.b + (ny * 0.5 + 0.5) * (cam.t - cam.b)
end

-- global boxels -> ray (origin, dir) in the CG frame
local function mouse_ray(x, y)
    local nx = ((x - cam.l) / (cam.r - cam.l)) * 2 - 1 - cam.shift_x
    local ny = ((y - cam.b) / (cam.t - cam.b)) * 2 - 1 - cam.shift_y
    local a, b = nx * cam.tan_h, ny * cam.tan_v
    local d = {
        a * cam.ax_r[1] + b * cam.ax_u[1] - cam.ax_b[1],
        a * cam.ax_r[2] + b * cam.ax_u[2] - cam.ax_b[2],
        a * cam.ax_r[3] + b * cam.ax_u[3] - cam.ax_b[3],
    }
    return cam.pos, d
end

local function slot_visible(s)
    if not s.hide then return true end
    return read_any(s.hide.h, s.hide.index) == 0
end

local function to_cg(s, v) return add(to_parent(v, s.psi, s.the, s.phi), s.base) end

-- 2D convex hull (monotone chain), counter-clockwise, of points { x, y }
local function hull2d(pts)
    table.sort(pts, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
    if #pts < 3 then return pts end
    local function turn(o, a, b) return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1]) end
    local h = {}
    for i = 1, #pts do
        while #h >= 2 and turn(h[#h - 1], h[#h], pts[i]) <= 0 do h[#h] = nil end
        h[#h + 1] = pts[i]
    end
    local lower = #h + 1
    for i = #pts - 1, 1, -1 do
        while #h >= lower and turn(h[#h - 1], h[#h], pts[i]) <= 0 do h[#h] = nil end
        h[#h + 1] = pts[i]
    end
    h[#h] = nil
    return h
end

-- inside a counter-clockwise convex polygon, or less than pad boxels outside
-- it (the window is back before a quick click right at the edge)
local function in_hull(h, x, y, pad)
    if #h < 3 then return false end
    for i = 1, #h do
        local a, b = h[i], h[i % #h + 1]
        local ex, ey = b[1] - a[1], b[2] - a[2]
        if ex * (y - a[2]) - ey * (x - a[1]) < -pad * math.sqrt(ex * ex + ey * ey) then return false end
    end
    return true
end

-----------------------------------------------------------------------------
-- Hit test
-----------------------------------------------------------------------------

-- nearest manipulator hit for a group: batch, slot, triangle, barycentric u, v
local function hit_group(g, x, y)
    if not cam.ok then return nil end
    local o, d = mouse_ray(x, y)
    local best, bb, bs, bt, bu, bv = nil, nil, nil, nil, nil, nil
    for _, s in ipairs(slots) do
        if s.on and slot_visible(s) then
            -- ray into the object's frame
            local lo = to_child(sub(o, s.base), s.psi, s.the, s.phi)
            local ld = to_child(d, s.psi, s.the, s.phi)
            for _, b in ipairs(g.batches) do
                for _, tri in ipairs(b.tris) do
                    local dist, u, v = ray_tri(lo, ld, tri[1], tri[2], tri[3])
                    if dist and (not best or dist < best) then
                        best, bb, bs, bt, bu, bv = dist, b, s, tri, u, v
                    end
                end
            end
        end
    end
    return bb, bs, bt, bu, bv
end

-- the group under the window first; windows of different groups can overlap
-- (the knob sits inside the screen's bounding box), so then every group
local function hit_any(g, x, y)
    local b, s, tri, u, v = hit_group(g, x, y)
    if b then return b, s, tri, u, v end
    for _, o in ipairs(groups) do
        if o ~= g then
            b, s, tri, u, v = hit_group(o, x, y)
            if b then return b, s, tri, u, v end
        end
    end
    return nil
end

-- barycentric (u, v) on a screen triangle -> device framebuffer px (y up)
local function tri_px(tri, u, v)
    local w = 1 - u - v
    local uv = tri.uv
    local tu = w * uv[1][1] + u * uv[2][1] + v * uv[3][1]
    local tv = w * uv[1][2] + u * uv[2][2] + v * uv[3][2]
    return tu * (config.screen_fb_w or 1), tv * (config.screen_fb_h or 1)
end

-- which command of a "pair" batch: screen side of the batch centre
local function pair_index(b, s, x, y)
    local cx, cy = project(to_cg(s, b.center))
    if not cx then return 1 end
    if b.axis == "y" then return (y >= cy) and 1 or 2 end
    return (x >= cx) and 1 or 2
end

-- a "pair" batch in the same group, for the mouse wheel
local function wheel_batch(g, b)
    if b.kind == "pair" then return b end
    -- a push cap turns the knob it sits on: the pair batch nearest in depth
    -- (a dual knob: the small knob's cap -> the small knob, not the large)
    local best, bd = nil, math.huge
    for _, o in ipairs(g.batches) do
        if o.kind == "pair" then
            local d = math.abs(o.center[3] - b.center[3])
            if d < bd then best, bd = o, d end
        end
    end
    return best
end

-----------------------------------------------------------------------------
-- Window callbacks
-----------------------------------------------------------------------------

P.on_touch = nil   -- function(phase, x, y): set by the master script
P.on_wheel = nil   -- function(x, y, clicks)

-- while a touch is held: the mouse on the touched triangle's plane
local function drag_px(x, y)
    if not (active and active.tri and cam.ok) then return nil end
    local o, d = mouse_ray(x, y)
    local s, tri = active.slot, active.tri
    local lo = to_child(sub(o, s.base), s.psi, s.the, s.phi)
    local ld = to_child(d, s.psi, s.the, s.phi)
    local dist, u, v = ray_tri(lo, ld, tri[1], tri[2], tri[3], true)
    if not dist then return nil end
    return tri_px(tri, u, v)
end

local function end_active(x, y)
    if active then
        if active.cmd then XPLMCommandEnd(active.cmd) end
        if active.tri and P.on_touch then
            local fx, fy = active.fx, active.fy
            if x then
                local px, py = drag_px(x, y)
                if px then fx, fy = px, py end
            end
            P.on_touch("up", fx, fy)
        end
        active = nil
    end
end

local function on_draw(win, g)
    -- invisible: the window only catches the mouse over the unit's controls,
    -- and reads the camera of the frame on screen
    local ok, err = pcall(capture_camera)
    if not ok and not drawn.err then
        drawn.err = true
        log("BUG 3D click camera failed (" .. tostring(err) .. "). Report on GitHub with Log.txt.")
    end
end

local function on_click(win, x, y, mouse, g)
    local ok, ret = pcall(function()
        if mouse == XPLMMouseStatus.xplm_MouseDown then
            end_active()
            local b, s, tri, u, v = hit_any(g, x, y)
            if not b then return config.pick_pass_misses ~= 0 and 0 or 1 end
            if b.kind == "screen" then
                local fx, fy = tri_px(tri, u, v)
                active = { tri = tri, slot = s, fx = fx, fy = fy }
                if config.pick_debug ~= 0 then log(string.format("NOTE pick: touch %.1f, %.1f", fx, fy)) end
                if P.on_touch then P.on_touch("down", fx, fy) end
                return 1
            end
            local i = (b.kind == "pair") and pair_index(b, s, x, y) or 1
            local c = b.cmds[i]
            if c then
                XPLMCommandBegin(c)
                active = { cmd = c }
            end
            if config.pick_debug ~= 0 then log("NOTE pick: " .. tostring(b.cmd_names[i])) end
            return 1
        elseif mouse == XPLMMouseStatus.xplm_MouseDrag then
            if active and active.tri then
                local fx, fy = drag_px(x, y)
                if fx then
                    active.fx, active.fy = fx, fy
                    if P.on_touch then P.on_touch("drag", fx, fy) end
                end
            end
        elseif mouse == XPLMMouseStatus.xplm_MouseUp then
            end_active(x, y)
        end
        return 1
    end)
    if not ok then
        -- once per session: a click error tends to repeat on every click
        if not P.click_bug_logged then
            P.click_bug_logged = true
            log("BUG 3D click failed (" .. tostring(ret) .. "). Report on GitHub with Log.txt.")
        end
        end_active()
        return 1
    end
    return ret
end

local function on_cursor(win, x, y, g)
    local ok, ret = pcall(function()
        local b, s = hit_any(g, x, y)
        if not b then return XPLMCursorStatus.xplm_CursorDefault end
        local name = b.cursor or "hand"
        if b.kind == "pair" and name:match("^rotate_%a+$") and b.axis == "x" then
            name = name .. ((pair_index(b, s, x, y) == 1) and "_right" or "_left")
        end
        return cursor_id(name)
    end)
    if not ok then return 0 end
    return ret
end

local function on_wheel(win, x, y, wheel, clicks, g)
    local ok, ret = pcall(function()
        local b, s, tri, u, v = hit_any(g, x, y)
        if not b then return false end
        if b.kind == "screen" then
            -- no wheel use on the screen: X-Plane keeps it (view zoom)
            if not P.on_wheel then return false end
            if clicks ~= 0 then
                local fx, fy = tri_px(tri, u, v)
                P.on_wheel(fx, fy, clicks)
            end
            return true
        end
        local w = wheel_batch(g, b)
        -- a key, not a knob: the wheel goes on to X-Plane
        if not w then return false end
        if wheel == 0 and clicks ~= 0 then
            local c = (clicks > 0) and w.cmds[1] or w.cmds[2]
            for _ = 1, math.min(math.abs(clicks), 10) do XPLMCommandOnce(c) end
        end
        return true     -- consume over the unit's controls
    end)
    if not ok then return true end
    return ret
end

-----------------------------------------------------------------------------
-- Public
-----------------------------------------------------------------------------

function P.init(util, cfg)
    U, config = util, cfg
    log = U.log
end

-- obj_path: this package's GTX327.obj; acf_path: the user aircraft
function P.load(obj_path, acf_path)
    slots, groups = {}, {}
    status = "off"
    if config.pick_mode == 0 then
        status = "off: [Clicks] clicks = off in gtx327_config.ini"
        return
    end
    local obja, root = read_acf(acf_path)
    if not obja then
        status = "off: cannot read the aircraft file " .. tostring(acf_path) .. " (BUG: report on GitHub)"
        return
    end
    local acf_dir = norm_path(acf_path):match("^(.*)/[^/]*$") or ""
    local cg = { 0, (root._cgY or 0) * FT, (root._cgZ or 0) * FT }
    local function resolve(file) return norm_path(acf_dir .. "/objects/" .. file) end

    -- which slots attach the unit's OBJ: this package's file, else any file
    -- with the same name
    local want = string.lower(norm_path(obj_path))
    local base_name = want:match("([^/]+)$") or want
    local matches, cockpit_file = {}, nil
    for n, o in pairs(obja) do
        local file = o._v10_att_file_stl
        local flags = tonumber(o._obj_flags or "0") or 0
        if file and (flags % 4096) >= 2048 then cockpit_file = resolve(file) end
        if file and string.lower(resolve(file)) == want then matches[#matches + 1] = n end
    end
    if #matches == 0 then
        for n, o in pairs(obja) do
            local file = o._v10_att_file_stl
            if file and string.lower(resolve(file)):match("([^/]+)$") == base_name then
                matches[#matches + 1] = n
                obj_path = resolve(file)
            end
        end
    end
    if #matches == 0 then
        status = "off: " .. base_name .. " is not attached to the aircraft (INSTALL: add 3D/GTX327.obj"
            .. " and 3D/GTX327_screen.obj in Plane Maker, Standard > Objects)"
        return
    end

    local batches, err = read_obj(obj_path)
    if not batches then
        status = "off: " .. tostring(err) .. " (INSTALL: reinstall the package folder)"
        return
    end
    local injected = cockpit_file and file_contains(cockpit_file, config.pick_inject_marker or "laminar/gtx327") or false
    table.sort(matches)
    for _, n in ipairs(matches) do
        local o = obja[n]
        local flags = tonumber(o._obj_flags or "0") or 0
        local s = {
            n = n,
            base = {
                (tonumber(o._v10_att_x_acf_prt_ref) or 0) * FT - cg[1],
                (tonumber(o._v10_att_y_acf_prt_ref) or 0) * FT - cg[2],
                (tonumber(o._v10_att_z_acf_prt_ref) or 0) * FT - cg[3],
            },
            psi = tonumber(o._v10_att_psi_ref) or 0,
            the = tonumber(o._v10_att_the_ref) or 0,
            phi = tonumber(o._v10_att_phi_ref) or 0,
            hide = hide_ref(o._obj_hide_dataref),
            on = true,
        }
        if (flags % 4096) >= 2048 then
            s.on, s.why = false, "slot is the cockpit object (native clicks)"
        elseif injected and config.pick_mode ~= 2 then
            s.on, s.why = false, "cockpit object already has the unit's click regions"
        end
        slots[#slots + 1] = s
    end

    -- group the batches, resolve commands, cache vertices for the window rects
    local by_id = {}
    for _, b in ipairs(batches) do
        b.cmds = {}
        for i, name in ipairs(b.cmd_names) do b.cmds[i] = XPLMFindCommand(name) end
        local sx, sy, sz, n = 0, 0, 0, 0
        for _, tri in ipairs(b.tris) do
            for j = 1, 3 do sx, sy, sz, n = sx + tri[j][1], sy + tri[j][2], sz + tri[j][3], n + 1 end
        end
        b.center = { sx / n, sy / n, sz / n }
        local g = by_id[b.group]
        if not g then
            g = { batches = {}, corners = {}, rect = { 0, 0, 0, 0 } }
            by_id[b.group] = g
            groups[#groups + 1] = g
        end
        g.batches[#g.batches + 1] = b
        local lo, hi = { math.huge, math.huge, math.huge }, { -math.huge, -math.huge, -math.huge }
        for _, tri in ipairs(b.tris) do
            for j = 1, 3 do
                for k = 1, 3 do lo[k], hi[k] = math.min(lo[k], tri[j][k]), math.max(hi[k], tri[j][k]) end
            end
        end
        -- the batch's box corners: the points of the unit's outline (hull)
        for c = 0, (#b.tris > 0) and 7 or -1 do
            g.corners[#g.corners + 1] = { (c % 2 == 0) and lo[1] or hi[1], (c % 4 < 2) and lo[2] or hi[2],
                (c < 4) and lo[3] or hi[3] }
        end
    end
    local on = 0
    for _, s in ipairs(slots) do if s.on then on = on + 1 end end
    if on > 0 then
        status = string.format("on: %d window(s), %d click regions", #groups, #batches)
    else
        status = "off: " .. tostring(slots[1] and slots[1].why) .. " (expected; X-Plane clicks the unit itself)"
    end
end

function P.enable()
    if #groups == 0 then return end
    local any = false
    for _, s in ipairs(slots) do any = any or s.on end
    if not any then return end
    -- an X-Plane without one of the camera datarefs (older than 12.4.4): no
    -- click window at all, one INSTALL line, instead of a failing projection
    local missing = {}
    dr.view_type = find("sim/graphics/view/view_type", missing)
    dr.vr = find("sim/graphics/VR/enabled")
    dr.win_w = find("sim/graphics/view/window_width", missing)
    dr.win_h = find("sim/graphics/view/window_height", missing)
    dr.proj = find("sim/graphics/view/projection_matrix_3d")
    -- the field of view stands in only when the projection matrix is missing
    local fov_missing = dr.proj and {} or missing
    dr.fov = find("sim/graphics/view/field_of_view_deg", fov_missing)
    dr.fov_hr = find("sim/graphics/view/field_of_view_horizontal_ratio", fov_missing)
    dr.fov_vr = find("sim/graphics/view/field_of_view_vertical_ratio", fov_missing)
    dr.vhdg = find("sim/graphics/view/view_heading", missing)
    dr.vpitch = find("sim/graphics/view/view_pitch", missing)
    dr.vroll = find("sim/graphics/view/view_roll", missing)
    dr.apsi = find("sim/flightmodel/position/psi", missing)
    dr.athe = find("sim/flightmodel/position/theta", missing)
    dr.aphi = find("sim/flightmodel/position/phi", missing)
    dr.hx = find("sim/graphics/view/pilots_head_x", missing)
    dr.hy = find("sim/graphics/view/pilots_head_y", missing)
    dr.hz = find("sim/graphics/view/pilots_head_z", missing)
    -- the drawn camera's position (any missing: the pilot's head)
    dr.vx = find("sim/graphics/view/view_x")
    dr.vy = find("sim/graphics/view/view_y")
    dr.vz = find("sim/graphics/view/view_z")
    dr.lx = find("sim/flightmodel/position/local_x")
    dr.ly = find("sim/flightmodel/position/local_y")
    dr.lz = find("sim/flightmodel/position/local_z")
    if #missing > 0 then
        status = "off: X-Plane has no " .. missing[1] .. " (INSTALL: needs X-Plane 12.4.4 or newer)"
        log("INSTALL 3D clicks off: X-Plane dataref " .. table.concat(missing, ", ") .. " not found"
            .. " (X-Plane older than 12.4.4?). The popup and bindings still work.")
        return
    end
    for _, g in ipairs(groups) do
        g.win = XPLMCreateWindowEx({
            left = 0, top = 1, right = 1, bottom = 0,
            visible = false,
            drawWindowFunc = on_draw,
            handleMouseClickFunc = on_click,
            handleCursorFunc = on_cursor,
            handleMouseWheelFunc = on_wheel,
            refcon = g,
            decorateAsFloatingWindow = XPLMWindowDecoration.xplm_WindowDecorationNone,
            layer = XPLMWindowLayer.xplm_WindowLayerFlightOverlay,
        })
        g.shown = false
    end
    enabled = true
end

local function hide(g)
    if g.shown then
        XPLMSetWindowIsVisible(g.win, false)
        g.shown = false
    end
end

-- per frame: lay each window over its group's projected bounding box
function P.update()
    if not enabled then return end
    update_camera()
    local mx, my = mouse_xy()
    for _, g in ipairs(groups) do
        local l, t, r, b = nil, nil, nil, nil
        local over = false      -- the mouse is over the unit's outline
        local outlines = {}
        if cam.ok and not active then
            for _, s in ipairs(slots) do
                if s.on and slot_visible(s) then
                    -- the click regions' box corners: the window rect and the outline.
                    -- A slot reaching behind the camera adds nothing; the window
                    -- is the union of the other slots' rects.
                    local pts = {}
                    for _, v in ipairs(g.corners) do
                        local x, y = project(to_cg(s, v))
                        if not x then pts = nil; break end
                        pts[#pts + 1] = { x, y }
                    end
                    if pts then
                        outlines[#outlines + 1] = pts
                        for _, p in ipairs(pts) do
                            l = l and math.min(l, p[1]) or p[1]
                            r = r and math.max(r, p[1]) or p[1]
                            b = b and math.min(b, p[2]) or p[2]
                            t = t and math.max(t, p[2]) or p[2]
                        end
                    end
                end
            end
            -- the outline only matters with the mouse inside the window
            if l and mx and mx >= l - 2 and mx <= r + 2 and my >= b - 2 and my <= t + 2 then
                for _, pts in ipairs(outlines) do
                    over = over or in_hull(hull2d(pts), mx, my, 3)
                end
            end
        end
        if active then
            -- keep the window still while a click is held
        elseif l and r > cam.l and l < cam.r and t > cam.b and b < cam.t
            and (mx or (r - l) < (cam.r - cam.l) * 0.95) then
            -- no mouse position (no outline test): never a window over nearly
            -- the whole screen, which would swallow the host's clicks
            -- clipped to the screen: no size limit, a zoomed-in unit keeps its clicks
            l, b = math.max(math.floor(l) - 1, cam.l), math.max(math.floor(b) - 1, cam.b)
            r, t = math.min(math.ceil(r) + 1, cam.r), math.min(math.ceil(t) + 1, cam.t)
            g.rect = { l, t, r, b }
            XPLMSetWindowGeometry(g.win, l, t, r, b)
            if config.pick_debug ~= 0 then
                -- the window and the self-test once, when the window first lands
                g.dbg = (g.dbg or 0) + 1
                if g.dbg == 1 then
                    log(string.format("NOTE pick: window %s  l %d t %d r %d b %d  (screen %d %d %d %d)",
                        tostring(g.batches[1].cmd_names[1]), l, t, r, b, cam.l, cam.t, cam.r, cam.b))
                    -- self-test: the projected centre of each batch must pick that batch
                    for _, bt in ipairs(g.batches) do
                        local s1 = slots[1] or {}
                        local pt = bt.center
                        if bt.kind == "pair" then
                            -- rim: a point 90 % of the way to its outermost vertex (right side)
                            local far = pt
                            for _, tri in ipairs(bt.tris) do
                                for j = 1, 3 do if tri[j][1] > far[1] then far = tri[j] end end
                            end
                            pt = { pt[1] + (far[1] - pt[1]) * 0.9, pt[2], far[3] }
                        end
                        local px, py = project(to_cg(s1, pt))
                        local hb, hs = hit_group(g, px, py)
                        local side = (hb and hb.kind == "pair") and pair_index(hb, hs, px, py) or 1
                        log(string.format("NOTE pick: self-test %s at %.1f,%.1f -> %s", tostring(bt.cmd_names[1]),
                            px or -1, py or -1, hb and tostring(hb.cmd_names[side]) or "MISS"))
                    end
                end
            end
            if mx and not over and mx >= l and mx <= r and my >= b and my <= t then
                -- off the outline: step aside for the unit or host below
                hide(g)
            else
                if not g.shown then
                    XPLMSetWindowIsVisible(g.win, true)
                    g.shown = true
                end
                -- onto the outline: in front of a neighbour's overlapping window
                if over and not g.over and XPLMBringWindowToFront then XPLMBringWindowToFront(g.win) end
            end
        else
            hide(g)
        end
        if not active then g.over = over end
    end
end

-- why: the clicks could not start (P.status then says off, with this reason)
function P.disable(why)
    if why ~= nil then status = "off: " .. tostring(why) end
    end_active()
    for _, g in ipairs(groups) do
        if g.win then
            XPLMDestroyWindow(g.win)
            g.win = nil
        end
    end
    enabled = false
end

function P.status() return status end

-- click windows alive (each holds 4 of xLua's shared callback budget)
function P.windows()
    local count = 0
    for _, g in ipairs(groups) do
        if g.win then count = count + 1 end
    end
    return count
end

return P
