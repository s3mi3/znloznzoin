-- Shot Detector | Vector Lua Engine
-- Detects whitelisted enemy shots from GunFiring and/or ammo changes, then
-- optionally confirms that the enemy's shot path can reach your player/hitboxes.

local XBUTTON2       = 0x06
local LMB_VK         = 0x01
local GUN_NAME       = "[Double-Barrel SG]"
local AMMO_NAME      = "Ammo"
local BURST          = 200
local BURST_INTERVAL = 4
local TRIGGER_DEBOUNCE_MS = 45

-- Hitbox groups -> recursive BasePart names to scan on your local character.
local HITGROUPS = {
    { name = "Head",  bones = { "Head" } },
    { name = "Torso", bones = { "UpperTorso", "LowerTorso", "Torso", "HumanoidRootPart" } },
    { name = "Arms",  bones = {
        "Left Arm", "Right Arm",
        "LeftUpperArm", "LeftLowerArm", "LeftHand",
        "RightUpperArm", "RightLowerArm", "RightHand",
    } },
    { name = "Legs",  bones = {
        "Left Leg", "Right Leg",
        "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
        "RightUpperLeg", "RightLowerLeg", "RightFoot",
    } },
}

local whitelist   = {}
local ammo_cache  = {}
local ammo_refs   = {}
local gf_refs     = {}
local gf_state    = {}
local ammo_state  = {}
local gf_conns    = {}
local ammo_conns  = {}
local shot_path_ok = {}
local selected    = nil
local prev_lmb    = false
local _armed      = false
local _active_target = nil
local _last_reject_ms = 0
local _last_trigger_ms = {}

local _burst_n   = 0
local _do_click  = false
local _click_thd = nil
local _poll_thd  = nil
local _cold_thd  = nil
local _cold_tick = 0

menu.add_tab("Shot Detect", "S")

menu.add_group("Shot Detect", "Settings")
menu.add_checkbox("Shot Detect", "Settings", "sd_on", "Enable", true)
menu.add_combo("Shot Detect", "Settings", "sd_trigger", "Normal trigger",
    { "GunFiring + Ammo", "GunFiring only", "Ammo only" }, 0)
menu.add_combo("Shot Detect", "Settings", "sd_method", "Shot detection",
    { "Normal values", "Incoming raycast", "Incoming hitbox", "Raycast + hitbox" }, 0)
menu.add_checkbox("Shot Detect", "Settings", "sd_fail_open", "Fail open if raycast unavailable", true)

menu.add_group("Shot Detect", "Raycast / Hitbox")
menu.add_checkbox("Shot Detect", "Raycast / Hitbox", "hs_draw", "Draw incoming hitbox scan", true)
menu.add_multicombo("Shot Detect", "Raycast / Hitbox", "hs_bones", "Scan hitboxes",
    { "Head", "Torso", "Arms", "Legs" }, { true, true, false, false })
menu.add_slider_int("Shot Detect", "Raycast / Hitbox", "hs_range", "Scan range (studs)",
    50, 2000, 600)

local function now_ms()
    return os.clock() * 1000
end

local function iv(o)
    return o and utility.is_valid(o)
end

local function safe_get_value(o)
    if not o then return nil end
    local ok, v = pcall(function() return o.value end)
    if ok then return v end
    return nil
end

local function safe_find(parent, name, recursive)
    if not iv(parent) then return nil end
    local ok, child = pcall(function() return parent:find_first_child(name, recursive) end)
    if ok and iv(child) then return child end
    return nil
end

local function read_prop(o, prop)
    if not iv(o) then return nil end
    local ok, value = pcall(function() return o[prop] end)
    if ok then return value end
    return nil
end

local function part_pos(part_ref)
    return read_prop(part_ref, "Position")
end

local function screen_center()
    local ok, x, y = pcall(function() return input.get_screen_center() end)
    if ok and x and y then return x, y end
    ok, x, y = pcall(function()
        local w, h = utility.get_screen_size()
        return w * 0.5, h * 0.5
    end)
    if ok and x and y then return x, y end
    return 0, 0
end

local function world_to_screen(pos)
    local ok, x, y, on = pcall(function() return utility.world_to_screen(pos) end)
    if not ok then return nil, nil, false end
    if type(x) == "table" then
        local t = x
        return t.x or t[1], t.y or t[2], t.on_screen or t.visible or y or false
    end
    return x, y, on
end

local function raycast_ready()
    if not raycast then return false end
    local ok, ready = pcall(function()
        if raycast.is_ready then return raycast.is_ready() end
        return true
    end)
    return ok and ready
end

local function ray_visible(from_pos, to_pos)
    if not raycast or not raycast.is_visible then return nil end
    local ok, visible = pcall(function() return raycast.is_visible(from_pos, to_pos) end)
    if ok then return visible and true or false end
    return nil
end

local function use_gunfiring()
    local mode = menu.get("sd_trigger") or 0
    return mode == 0 or mode == 1
end

local function use_ammo()
    local mode = menu.get("sd_trigger") or 0
    return mode == 0 or mode == 2
end

local function uses_hitbox_method()
    local mode = menu.get("sd_method") or 0
    return mode == 2 or mode == 3
end

local function uses_player_raycast_method()
    local mode = menu.get("sd_method") or 0
    return mode == 1 or mode == 3
end

local function fail_open()
    return menu.get("sd_fail_open") ~= false
end

local function enabled_bone_names()
    local sel = menu.get("hs_bones")
    local names = {}
    for i, grp in ipairs(HITGROUPS) do
        if not sel or sel[i] then
            for _, bone in ipairs(grp.bones) do
                names[#names + 1] = bone
            end
        end
    end
    return names
end

local function get_player_by_name(name)
    for _, p in ipairs(entity.get_players()) do
        if p.name == name then return p end
    end
    return nil
end

local function player_position(p)
    if not p then return nil end

    local ok, pos = pcall(function() return p.head_position end)
    if ok and pos then return pos end

    ok, pos = pcall(function() return p.position end)
    if ok and pos then return pos end

    local char = nil
    ok, char = pcall(function() return p.character end)
    if ok and iv(char) then
        local head = safe_find(char, "Head", true)
        pos = part_pos(head)
        if pos then return pos end

        local root = safe_find(char, "HumanoidRootPart", true)
        pos = part_pos(root)
        if pos then return pos end
    end

    return nil
end

local function local_player_position()
    return player_position(entity.get_local_player())
end

local function local_character()
    local me = entity.get_local_player()
    if not me then return nil end

    local ok, char = pcall(function() return me.character end)
    if ok and iv(char) then return char end

    ok, char = pcall(function() return me.Character end)
    if ok and iv(char) then return char end

    return nil
end

local function distance_to_local(p, local_player)
    if not p or not local_player then return nil end
    local ok, dist = pcall(function() return p:distance_to(local_player.position) end)
    if ok then return dist end
    return nil
end

-- Scans your enabled hitboxes from the shooter's origin. This is used as shot
-- detection confirmation: when the enemy fires, a clear ray to any local
-- hitbox means their shot path can hit you, so the script mirrors the shot.
local function incoming_hitbox_scan(shooter_origin)
    local res = { parts = {}, any_hit = false, best = nil }
    local char = local_character()
    if not iv(char) then return res end
    if not shooter_origin then return res end

    local cx, cy = screen_center()
    local best_d = math.huge

    for _, bone in ipairs(enabled_bone_names()) do
        local part_ref = safe_find(char, bone, true)
        local pos = part_pos(part_ref)
        if pos then
            local hit = ray_visible(shooter_origin, pos)
            if hit == nil then hit = fail_open() end

            local sx, sy, on = world_to_screen(pos)
            local entry = { name = bone, pos = pos, sx = sx, sy = sy, on = on, hit = hit }
            res.parts[#res.parts + 1] = entry

            if hit then
                res.any_hit = true
                if on and sx and sy then
                    local dx = sx - cx
                    local dy = sy - cy
                    local d = dx * dx + dy * dy
                    if d < best_d then
                        best_d = d
                        res.best = entry
                    end
                end
            end
        end
    end

    return res
end

local function incoming_player_raycast(shooter_origin)
    local target_pos = local_player_position()
    if not shooter_origin or not target_pos then
        if fail_open() then return true end
        return false
    end

    local hit = ray_visible(shooter_origin, target_pos)
    if hit == nil then return fail_open() end
    return hit
end

local function shot_path_matches(name)
    local method = menu.get("sd_method") or 0
    if method == 0 or not name then return true end

    local shooter = get_player_by_name(name)
    local shooter_origin = player_position(shooter)
    if not shooter_origin then return fail_open() end

    local checked = false
    local matches = false

    if uses_player_raycast_method() then
        checked = true
        matches = incoming_player_raycast(shooter_origin) or matches
    end

    if uses_hitbox_method() then
        checked = true
        local cached = shot_path_ok[name]
        if cached == nil then
            local scan = incoming_hitbox_scan(shooter_origin)
            cached = scan.any_hit
            if #scan.parts == 0 and fail_open() then cached = true end
        end
        matches = cached or matches
    end

    if not checked then return true end
    return matches
end

local function click()
    if not pcall(function() input.simulate_mouse_click(0) end) then
        pcall(function() utility.mouse_click() end)
    end
end

local function start_burst(name, source)
    if not _armed then return end

    local t = now_ms()
    local last = _last_trigger_ms[name] or 0
    if t - last < TRIGGER_DEBOUNCE_MS then return end
    _last_trigger_ms[name] = t
    _active_target = name

    if not shot_path_matches(name) then
        _last_reject_ms = t
        return
    end

    _burst_n = BURST
    _do_click = true
    print("[ShotDetect] " .. name .. " shot detected via " .. source)

    if _click_thd then
        thread.stop(_click_thd)
        _click_thd = nil
    end
    _click_thd = thread.create(function()
        _do_click = true
    end, BURST_INTERVAL)
end

local function handle_gunfiring(name, value)
    local now = value and true or false
    local prev = gf_state[name] or false
    if use_gunfiring() and now and not prev then
        start_burst(name, "GunFiring")
    end
    gf_state[name] = now
end

local function ammo_changed(prev, current)
    if prev == nil or current == nil then return false end
    local pn = tonumber(prev)
    local cn = tonumber(current)
    if pn and cn then
        return cn < pn
    end
    return current ~= prev
end

local function handle_ammo(name, value)
    local prev = ammo_state[name]
    if use_ammo() and ammo_changed(prev, value) then
        start_burst(name, "Ammo")
    end
    ammo_state[name] = value
    ammo_cache[name] = value
end

local function disconnect_ref(conn)
    if conn then
        pcall(function() conn:disconnect() end)
        pcall(function() conn:Disconnect() end)
    end
end

local function arm_gunfiring(name, ref)
    disconnect_ref(gf_conns[name])
    gf_conns[name] = nil
    if not iv(ref) then return end

    gf_state[name] = safe_get_value(ref) and true or false
    local ok, conn = pcall(function()
        return ref.Changed:connect(function(v)
            handle_gunfiring(name, v)
        end)
    end)
    if ok then gf_conns[name] = conn end
end

local function arm_ammo(name, ref)
    disconnect_ref(ammo_conns[name])
    ammo_conns[name] = nil
    if not iv(ref) then return end

    ammo_state[name] = safe_get_value(ref)
    ammo_cache[name] = ammo_state[name]
    local ok, conn = pcall(function()
        return ref.Changed:connect(function(v)
            handle_ammo(name, v)
        end)
    end)
    if ok then ammo_conns[name] = conn end
end

local function find_character_by_name(name)
    local ws = game.workspace
    if not iv(ws) then return nil end
    local players_folder = safe_find(ws, "Players", false)
    return safe_find(players_folder, name, false)
end

local function find_gunfiring(name)
    local char = find_character_by_name(name)
    local body_effects = safe_find(char, "BodyEffects", false)
    return safe_find(body_effects, "GunFiring", false)
end

local function find_ammo(plr, name)
    local function try(container)
        local gun = safe_find(container, GUN_NAME, false)
        return safe_find(gun, AMMO_NAME, false)
    end

    local backpack = safe_find(plr, "Backpack", false)
    local ammo = try(backpack)
    if ammo then return ammo end

    local char = read_prop(plr, "Character") or safe_find(plr, "Character", false) or find_character_by_name(name)
    return try(char)
end

local function poll_refs()
    for name in pairs(whitelist) do
        local gf_ref = gf_refs[name]
        if gf_ref and iv(gf_ref) then
            local v = safe_get_value(gf_ref)
            if v ~= nil then handle_gunfiring(name, v) end
        end

        local ammo_ref = ammo_refs[name]
        if ammo_ref and iv(ammo_ref) then
            local v = safe_get_value(ammo_ref)
            if v ~= nil then handle_ammo(name, v) end
        end
    end
end

local function cold_refresh()
    _cold_tick = _cold_tick + 1

    local players_service = game.players
    if not iv(players_service) then return end

    for name in pairs(whitelist) do
        local plr = safe_find(players_service, name, false)
        if iv(plr) then
            local gf_ref = gf_refs[name]
            if not iv(gf_ref) or _cold_tick % 50 == 0 then
                gf_ref = find_gunfiring(name)
                gf_refs[name] = gf_ref
                arm_gunfiring(name, gf_ref)
            end

            local ammo_ref = ammo_refs[name]
            if not iv(ammo_ref) or _cold_tick % 50 == 0 then
                ammo_ref = find_ammo(plr, name)
                ammo_refs[name] = ammo_ref
                arm_ammo(name, ammo_ref)
            end
        end
    end
end

local function clear_player(name)
    whitelist[name] = nil
    ammo_cache[name] = nil
    gf_refs[name] = nil
    ammo_refs[name] = nil
    gf_state[name] = nil
    ammo_state[name] = nil
    shot_path_ok[name] = nil
    _last_trigger_ms[name] = nil

    disconnect_ref(gf_conns[name])
    disconnect_ref(ammo_conns[name])
    gf_conns[name] = nil
    ammo_conns[name] = nil

    if selected == name then selected = nil end
    if _active_target == name then _active_target = nil end
end

function on_player_removed(p)
    if p and p.name then clear_player(p.name) end
end

local function update_hitboxes()
    local local_player = entity.get_local_player()
    local draw_scan = menu.get("hs_draw") == true
    local need_hitbox = draw_scan or uses_hitbox_method()
    local range = menu.get("hs_range") or 600

    for _, p in ipairs(entity.get_players()) do
        local name = p.name
        if not p.is_local and whitelist[name] then
            if need_hitbox and p.is_alive then
                local dist = distance_to_local(p, local_player)
                local in_range = not dist or dist <= range
                local shooter_origin = player_position(p)

                if in_range and shooter_origin then
                    local scan = incoming_hitbox_scan(shooter_origin)
                    shot_path_ok[name] = scan.any_hit
                    if #scan.parts == 0 and fail_open() then shot_path_ok[name] = nil end

                    if draw_scan then
                        for _, entry in ipairs(scan.parts) do
                            if entry.on and entry.sx and entry.sy then
                                local color = entry.hit and { 0.2, 1, 0.45, 0.9 } or { 1, 0.3, 0.3, 0.8 }
                                draw.circle_filled(entry.sx, entry.sy, 3, color)
                            end
                        end
                        if scan.best then
                            draw.circle(scan.best.sx, scan.best.sy, 6, { 1, 1, 0.2, 1 })
                            local tag = scan.best.name
                            if not raycast_ready() then tag = tag .. " ?" end
                            draw.text(scan.best.sx + 8, scan.best.sy - 6, tag, { 1, 1, 0.4, 1 }, 11)
                        end
                    end
                else
                    shot_path_ok[name] = nil
                end
            else
                shot_path_ok[name] = nil
            end
        end
    end
end

local function draw_panel()
    local px, py, pw = 14, 14, 232
    local row_h, hdr_h, btn_h, gap = 22, 26, 24, 4
    local list = {}

    for _, p in ipairs(entity.get_players()) do
        if not p.is_local then
            list[#list + 1] = p
        end
    end

    local panel_h = hdr_h + #list * row_h + gap + btn_h + 4
    draw.rect_filled(px, py, pw, panel_h, { 0.04, 0.04, 0.09, 0.9 }, 5)
    draw.rect(px, py, pw, panel_h, { 0.28, 0.52, 1, 0.7 }, 5)
    draw.rect_filled(px, py, pw, hdr_h, { 0.1, 0.22, 0.52, 0.95 }, 5)

    local wl_n = 0
    for _ in pairs(whitelist) do wl_n = wl_n + 1 end

    local method = menu.get("sd_method") or 0
    local method_names = { "Normal", "Incoming RC", "Incoming HB", "RC + HB" }
    local title = "Shot Detect " .. (method_names[method + 1] or "Normal")
    if _armed then
        title = title .. " [ARMED]"
    else
        title = title .. " [" .. wl_n .. " wl]"
    end
    draw.text(px + 8, py + 6, title, _armed and { 0.2, 1, 0.45, 1 } or { 0.7, 0.9, 1, 1 }, 13)

    local mx, my = utility.get_mouse_pos()
    local lmb_now = input.is_key_down(LMB_VK)
    local clicked = lmb_now and not prev_lmb

    for i, p in ipairs(list) do
        local ry = py + hdr_h + (i - 1) * row_h
        local wl = whitelist[p.name] ~= nil
        local hover = mx >= px and mx <= px + pw and my >= ry and my <= ry + row_h
        draw.rect_filled(px + 2, ry, pw - 4, row_h,
            selected == p.name and { 0.28, 0.48, 0.95, 0.4 } or
            wl and { 0.08, 0.42, 0.12, 0.32 } or
            hover and { 1, 1, 1, 0.08 } or { 0, 0, 0, 0 })

        local shot_path = wl and shot_path_matches(p.name)
        draw.circle_filled(px + 11, ry + row_h / 2, 4,
            wl and (shot_path and { 0.2, 1, 0.45, 1 } or { 1, 0.55, 0.2, 1 }) or { 0.4, 0.4, 0.4, 0.55 })

        local label = p.name
        if wl and ammo_cache[p.name] ~= nil then
            label = p.name .. "  [" .. tostring(ammo_cache[p.name]) .. "]"
        end
        draw.text(px + 20, ry + row_h / 2 - 6, label,
            wl and { 0.32, 1, 0.52, 1 } or { 1, 1, 1, 0.85 }, 12)

        if hover and clicked then selected = p.name end
    end

    if #list == 0 then
        draw.text(px + 8, py + hdr_h + 4, "No other players", { 0.5, 0.5, 0.5, 0.8 }, 12)
    end

    local btn_y = py + hdr_h + #list * row_h + gap
    local bx, bw = px + 3, pw - 6
    local hover_button = mx >= bx and mx <= bx + bw and my >= btn_y and my <= btn_y + btn_h
    local selected_whitelisted = selected and whitelist[selected]
    local button_label = not selected and "Select a player"
        or selected_whitelisted and ("Remove: " .. selected)
        or ("Whitelist: " .. selected)
    local button_color = selected_whitelisted
        and (hover_button and { 0.88, 0.2, 0.2, 0.95 } or { 0.65, 0.12, 0.12, 0.88 })
        or (hover_button and { 0.25, 0.6, 1, 0.95 } or { 0.14, 0.42, 0.8, 0.88 })

    draw.rect_filled(bx, btn_y, bw, btn_h, button_color, 4)
    draw.rect(bx, btn_y, bw, btn_h, { 0.45, 0.7, 1, 0.55 }, 4)
    local tw, th = draw.get_text_size(button_label, 12)
    draw.text(bx + bw / 2 - tw / 2, btn_y + btn_h / 2 - th / 2, button_label, { 1, 1, 1, 1 }, 12)

    if hover_button and clicked and selected then
        if whitelist[selected] then
            clear_player(selected)
        else
            whitelist[selected] = true
            gf_refs[selected] = nil
            ammo_refs[selected] = nil
            gf_state[selected] = nil
            ammo_state[selected] = nil
            shot_path_ok[selected] = nil
            cold_refresh()
        end
    end

    prev_lmb = lmb_now
end

function on_pre_frame()
    _armed = menu.get("sd_on") and input.is_key_down(XBUTTON2)
    poll_refs()
end

function on_frame()
    if _do_click then
        _do_click = false
        if _burst_n > 0 then
            _burst_n = _burst_n - 1
            click()
        end
        if _burst_n == 0 and _click_thd then
            thread.stop(_click_thd)
            _click_thd = nil
        end
    end

    if not _poll_thd then _poll_thd = thread.create(poll_refs, 5) end
    if not _cold_thd then _cold_thd = thread.create(cold_refresh, 100) end

    _armed = menu.get("sd_on") and input.is_key_down(XBUTTON2)
    poll_refs()

    if not menu.get("sd_on") then return end

    update_hitboxes()
    draw_panel()
end

print("[ShotDetect] Loaded. Trigger=GunFiring/Ammo | methods: normal, player raycast, hitbox scan")
