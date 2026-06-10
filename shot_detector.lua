-- Shot Detector | Vector Lua Engine
-- Detects when a whitelisted enemy fires (via GunFiring / Ammo changes) and
-- responds with a click burst. This build adds two extra capabilities built on
-- the engine's raycast API (https://project-vector-1.gitbook.io/vector-lua-engine):
--
--   * Raycast shot detection  -> only fire when there is a clear line of sight
--                                to the target (cached or live hitbox raycast).
--   * Hitbox scanning method   -> scan every hitbox bone of a target, test each
--                                one for visibility against the world obstacle
--                                cache, project it to screen and pick the best
--                                exposed hitpoint.

local XBUTTON2       = 0x06
local LMB_VK         = 0x01
local GUN_NAME       = "[Double-Barrel SG]"
local AMMO_NAME      = "Ammo"
local BURST          = 200
local BURST_INTERVAL = 4

-- Hitbox groups -> the actual bone/part names to scan for each rig type.
-- The scan does a recursive find for each name on the target character, so the
-- same group works for both R6 and R15 characters.
local HITGROUPS = {
    { name = "Head",  bones = { "Head" } },
    { name = "Torso", bones = { "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart" } },
    { name = "Arms",  bones = { "Left Arm", "Right Arm",
                                "LeftUpperArm", "LeftLowerArm", "LeftHand",
                                "RightUpperArm", "RightLowerArm", "RightHand" } },
    { name = "Legs",  bones = { "Left Leg", "Right Leg",
                                "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
                                "RightUpperLeg", "RightLowerLeg", "RightFoot" } },
}

local whitelist  = {}
local ammo_cache = {}
local ammo_refs  = {}
local gf_refs    = {}
local selected, prev_lmb = nil, false

local _gf, _prev_gf = nil, false
local _gf_name      = nil
local _ao, _prev_ao = nil, -1
local _ao_name      = nil
local _gf_fired     = false

-- Raycast / hitbox runtime state (all safe to read from worker threads).
local char_addr = {}   -- name -> character memory address (cached each frame)
local los_ok    = {}   -- name -> last computed line-of-sight result (live scan)
local _active_target = nil
local _last_block_t  = 0

menu.add_tab("Shot Detect", "S")
menu.add_group("Shot Detect", "Settings")
menu.add_checkbox("Shot Detect", "Settings", "sd_on", "Enable", true)

menu.add_group("Shot Detect", "Raycast / Hitbox")
menu.add_checkbox("Shot Detect", "Raycast / Hitbox", "rc_los", "Only fire with line of sight", false)
menu.add_combo("Shot Detect", "Raycast / Hitbox", "rc_mode", "LOS check",
    { "Player (cached)", "Hitbox scan (live)" }, 0, { parent = "rc_los" })
menu.add_checkbox("Shot Detect", "Raycast / Hitbox", "hs_draw", "Draw hitbox scan", true)
menu.add_multicombo("Shot Detect", "Raycast / Hitbox", "hs_bones", "Scan hitboxes",
    { "Head", "Torso", "Arms", "Legs" }, { true, true, false, false }, { parent = "hs_draw" })
menu.add_slider_int("Shot Detect", "Raycast / Hitbox", "hs_range", "Scan range (studs)",
    50, 2000, 600, { parent = "hs_draw" })

local function iv(o)
    return o and utility.is_valid(o)
end

local function gval(o)
    if not o then return nil end
    local v; pcall(function() v = o.value end)
    return v
end

-- Read a BasePart world position as a Vector3 (nil if unreadable).
local function part_pos(part)
    if not iv(part) then return nil end
    local p; pcall(function() p = part.Position end)
    return p
end

-- Which hitbox groups are currently enabled in the menu.
local function enabled_bone_names()
    local sel = menu.get("hs_bones")
    local names = {}
    for i, grp in ipairs(HITGROUPS) do
        if not sel or sel[i] then
            for _, b in ipairs(grp.bones) do names[#names + 1] = b end
        end
    end
    return names
end

-- Hitbox scanning method.
-- Walks the enabled hitbox bones of a character, reads each part's world
-- position, raycasts from the camera to it to decide visibility, and projects
-- it to screen. Returns { parts, any_visible, best }.
local function hitbox_scan(char)
    local res = { parts = {}, any_visible = false, best = nil }
    if not iv(char) then return res end

    local cam = camera.get_position()
    if not cam then return res end

    local cx, cy = input.get_screen_center()
    local best_d = math.huge

    for _, bone in ipairs(enabled_bone_names()) do
        local part = char:find_first_child(bone, true)
        local pos  = part_pos(part)
        if pos then
            local vis = true
            pcall(function() vis = raycast.is_visible(cam, pos) end)
            local sx, sy, on = utility.world_to_screen(pos)

            local entry = { name = bone, pos = pos, sx = sx, sy = sy, on = on, vis = vis }
            res.parts[#res.parts + 1] = entry

            if vis then
                res.any_visible = true
                if on then
                    local d = (sx - cx) * (sx - cx) + (sy - cy) * (sy - cy)
                    if d < best_d then best_d = d; res.best = entry end
                end
            end
        end
    end
    return res
end

-- Line-of-sight gate used before firing. Fails open (returns true) whenever the
-- raycast cache or target data is not available, matching the engine's raycast
-- semantics so detection still works during startup.
local function los_clear(name)
    if not menu.get("rc_los") then return true end
    if not name then return true end

    local mode = menu.get("rc_mode") or 0
    if mode == 1 then
        -- Live hitbox scan result computed on the render thread.
        local v = los_ok[name]
        if v == nil then return true end
        return v
    end

    -- Cached per-player visibility from the raycast worker thread.
    local addr = char_addr[name]
    if not addr then return true end
    local ok = true
    pcall(function() ok = raycast.is_player_visible(addr) end)
    return ok
end

local _burst_n   = 0
local _do_click  = false
local _click_thd = nil
local _armed     = false  -- cached; safe to read from threads
local _gf_conn   = nil
local _ao_conn   = nil

local function click()
    if not pcall(function() input.simulate_mouse_click(0) end) then utility.mouse_click() end
end

local function fire(name)
    if _gf_fired then return end
    -- Raycast shot detection: skip the burst when the target is occluded.
    if not los_clear(name or _active_target) then
        _last_block_t = utility.get_time()
        return
    end
    _gf_fired = true
    _burst_n  = BURST
    _do_click = true   -- on_frame top catches this; on_pre_frame->on_frame = same game step
    if _click_thd then thread.stop(_click_thd); _click_thd = nil end
    _click_thd = thread.create(function() _do_click = true end, BURST_INTERVAL)
end

-- Subscribe to Changed event on GunFiring ref so fire() triggers the instant value changes
local function arm_gf(ref, name)
    if _gf_conn then pcall(function() _gf_conn:disconnect() end); _gf_conn = nil end
    if not ref then return end
    pcall(function()
        _gf_conn = ref.Changed:connect(function(v)
            if v and not _prev_gf and not _gf_fired then _active_target = name; fire(name) end
            if not v then _gf_fired = false end
            _prev_gf = v
        end)
    end)
end

local function arm_ao(ref, name)
    if _ao_conn then pcall(function() _ao_conn:disconnect() end); _ao_conn = nil end
    if not ref then return end
    pcall(function()
        _ao_conn = ref.Changed:connect(function(v)
            if _prev_ao >= 0 and v ~= _prev_ao and not _gf_fired then _active_target = name; fire(name) end
            _prev_ao = v
        end)
    end)
end

local function poll()
    local gf = gval(_gf)
    if gf ~= nil then
        if _armed and gf and not _prev_gf and not _gf_fired then _active_target = _gf_name; fire(_gf_name) end
        if not gf then _gf_fired = false end
        _prev_gf = gf
    end
    if _ao then
        local v = gval(_ao)
        if v ~= nil then
            if _armed and _prev_ao >= 0 and v ~= _prev_ao and not _gf_fired then _active_target = _ao_name; fire(_ao_name) end
            _prev_ao = v
        end
    end
end

local function find_gf(name)
    local ws = game.workspace;            if not iv(ws) then return nil end
    local pl = ws:find_first_child("Players"); if not iv(pl) then return nil end
    local ch = pl:find_first_child(name); if not iv(ch) then return nil end
    local be = ch:find_first_child("BodyEffects"); if not iv(be) then return nil end
    local gf = be:find_first_child("GunFiring"); return iv(gf) and gf or nil
end

local function find_ammo(plr)
    local function try(c)
        if not iv(c) then return nil end
        local gun = c:find_first_child(GUN_NAME); if not iv(gun) then return nil end
        local ao  = gun:find_first_child(AMMO_NAME); return iv(ao) and ao or nil
    end
    return try(plr:find_first_child("Backpack")) or try(plr:find_first_child("Character"))
end

local cc = 0
local function cold()
    cc = cc + 1
    local svc = game.players; if not iv(svc) then return end
    local fgf, fgf_name = nil, nil
    for name in pairs(whitelist) do
        local plr = svc:find_first_child(name)
        if plr and iv(plr) then
            local gref = gf_refs[name]
            if not gref or (cc % 100 == 0 and not iv(gref)) then
                gref = find_gf(name); gf_refs[name] = gref
                if gref then _prev_gf = gval(gref) or false; arm_gf(gref, name); print("[SD] "..name..": GF ok")
                else print("[SD] "..name..": GF not found") end
            end
            if gref and not fgf then fgf = gref; fgf_name = name end
            local aref = ammo_refs[name]
            if not aref or (cc % 100 == 0 and not iv(aref)) then
                aref = find_ammo(plr); ammo_refs[name] = aref
                if aref then _prev_ao = -1; arm_ao(aref, name) end
            end
            if aref then
                ammo_cache[name] = aref.value
                if not _ao then _ao = aref; _ao_name = name end
            end
        end
    end
    if fgf ~= _gf then _gf = fgf; _gf_name = fgf_name end
end

local thd_h, thd_c = nil, nil

function on_pre_frame()
    _armed = menu.get("sd_on") and input.is_key_down(XBUTTON2)
    poll()
end

function on_player_removed(p)
    whitelist[p.name] = nil; ammo_cache[p.name] = nil
    ammo_refs[p.name] = nil; gf_refs[p.name]    = nil
    char_addr[p.name] = nil; los_ok[p.name]     = nil
    _gf = nil; _prev_gf = false; _ao = nil; _prev_ao = -1
    _gf_name = nil; _ao_name = nil
    _gf_fired = false; _burst_n = 0
    if _click_thd then thread.stop(_click_thd); _click_thd = nil end
    if _gf_conn   then pcall(function() _gf_conn:disconnect() end);  _gf_conn = nil end
    if _ao_conn   then pcall(function() _ao_conn:disconnect() end);   _ao_conn = nil end
    if selected == p.name then selected = nil end
    if _active_target == p.name then _active_target = nil end
end

-- Refresh cached character addresses + live hitbox visibility and (optionally)
-- draw the hitbox scan overlay for whitelisted players.
local function update_hitboxes()
    local me = entity.get_local_player()
    local draw_scan = menu.get("hs_draw")
    local need_scan = draw_scan or (menu.get("rc_los") and (menu.get("rc_mode") or 0) == 1)
    local range = menu.get("hs_range") or 600

    for _, p in ipairs(entity.get_players()) do
        local name = p.name
        if not p.is_local and whitelist[name] then
            local char = p.character
            char_addr[name] = (iv(char) and char.address) or nil

            if need_scan and p.is_alive and iv(char) then
                local in_range = true
                if me then in_range = (p:distance_to(me.position) <= range) end

                if in_range then
                    local scan = hitbox_scan(char)
                    los_ok[name] = scan.any_visible

                    if draw_scan then
                        for _, e in ipairs(scan.parts) do
                            if e.on then
                                local col = e.vis and { 0.2, 1, 0.45, 0.9 } or { 1, 0.3, 0.3, 0.8 }
                                draw.circle_filled(e.sx, e.sy, 3, col)
                            end
                        end
                        if scan.best then
                            draw.circle(scan.best.sx, scan.best.sy, 6, { 1, 1, 0.2, 1 })
                            local tag = scan.best.name .. (raycast.is_ready() and "" or " ?")
                            draw.text(scan.best.sx + 8, scan.best.sy - 6, tag, { 1, 1, 0.4, 1 }, 11)
                        end
                    end
                else
                    los_ok[name] = nil
                end
            else
                los_ok[name] = nil
            end
        end
    end
end

function on_frame()
    if _do_click then
        _do_click = false
        if _burst_n > 0 then _burst_n = _burst_n - 1; click() end
        if _burst_n == 0 and _click_thd then thread.stop(_click_thd); _click_thd = nil end
    end
    if not thd_h then thd_h = thread.create(poll, 0) end
    if not thd_c then thd_c = thread.create(cold, 10) end
    _armed = menu.get("sd_on") and input.is_key_down(XBUTTON2)
    poll()

    if not menu.get("sd_on") then return end

    update_hitboxes()

    local px, py, pw    = 14, 14, 220
    local rh, hdr_h, btn_h, gap = 22, 26, 24, 4
    local list = {}
    for _, p in ipairs(entity.get_players()) do
        if not p.is_local then list[#list+1] = p end
    end
    local ph = hdr_h + #list*rh + gap + btn_h + 4
    draw.rect_filled(px, py, pw, ph,    {0.04,0.04,0.09,0.9}, 5)
    draw.rect       (px, py, pw, ph,    {0.28,0.52,1,0.7},    5)
    draw.rect_filled(px, py, pw, hdr_h, {0.1,0.22,0.52,0.95}, 5)

    local armed = input.is_key_down(XBUTTON2)
    local wl_n  = 0; for _ in pairs(whitelist) do wl_n = wl_n + 1 end
    draw.text(px+8, py+6, "Shot Detect"..(armed and " [ARMED]" or " ["..wl_n.." wl]"),
              armed and {0.2,1,0.45,1} or {0.7,0.9,1,1}, 13)

    local mx, my  = utility.get_mouse_pos()
    local lmb_now = input.is_key_down(LMB_VK)
    local clicked = lmb_now and not prev_lmb

    for i, p in ipairs(list) do
        local ry  = py + hdr_h + (i-1)*rh
        local wl  = whitelist[p.name] ~= nil
        local hov = mx >= px and mx <= px+pw and my >= ry and my <= ry+rh
        draw.rect_filled(px+2, ry, pw-4, rh,
            selected == p.name and {0.28,0.48,0.95,0.4} or
            wl  and {0.08,0.42,0.12,0.32} or
            hov and {1,1,1,0.08} or {0,0,0,0})
        -- LOS dot: bright green when the target is currently visible.
        local los = wl and los_clear(p.name)
        draw.circle_filled(px+11, ry+rh/2, 4,
            wl and (los and {0.2,1,0.45,1} or {1,0.55,0.2,1}) or {0.4,0.4,0.4,0.55})
        draw.text(px+20, ry+rh/2-6,
            wl and ammo_cache[p.name] and (p.name.."  ["..ammo_cache[p.name].."]") or p.name,
            wl and {0.32,1,0.52,1} or {1,1,1,0.85}, 12)
        if hov and clicked then selected = p.name end
    end
    if #list == 0 then draw.text(px+8, py+hdr_h+4, "No other players", {0.5,0.5,0.5,0.8}, 12) end

    local btn_y  = py + hdr_h + #list*rh + gap
    local bx, bw = px+3, pw-6
    local hov_b  = mx >= bx and mx <= bx+bw and my >= btn_y and my <= btn_y+btn_h
    local sel_wl = selected and whitelist[selected]
    local blbl   = not selected and "Select a player"
               or  sel_wl      and ("Remove: "..selected)
               or               ("Whitelist: "..selected)
    local bcol   = sel_wl and (hov_b and {0.88,0.2,0.2,0.95} or {0.65,0.12,0.12,0.88})
                           or  (hov_b and {0.25,0.6,1,0.95}   or {0.14,0.42,0.8,0.88})
    draw.rect_filled(bx, btn_y, bw, btn_h, bcol, 4)
    draw.rect       (bx, btn_y, bw, btn_h, {0.45,0.7,1,0.55}, 4)
    local tw, th = draw.get_text_size(blbl, 12)
    draw.text(bx+bw/2-tw/2, btn_y+btn_h/2-th/2, blbl, {1,1,1,1}, 12)

    if hov_b and clicked and selected then
        if whitelist[selected] then
            whitelist[selected] = nil; gf_refs[selected]   = nil
            ammo_cache[selected]= nil; ammo_refs[selected] = nil
            char_addr[selected] = nil; los_ok[selected]    = nil
            _gf = nil; _prev_gf = false; _ao = nil; _prev_ao = -1; _gf_fired = false
        else
            whitelist[selected] = true; gf_refs[selected] = nil
            _prev_gf = false; _gf_fired = false
        end
    end

    prev_lmb = lmb_now
end

print("[ShotDetect] Loaded. Burst="..BURST.." @ "..BURST_INTERVAL.."ms | raycast LOS + hitbox scan ready")
