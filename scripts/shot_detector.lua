-- Shot Detector | Vector Lua Engine
-- Fast GunFiring/Ammo detector for whitelisted players.
-- When a shot is detected while XBUTTON2 is held, the script clicks immediately
-- and keeps clicking as fast as the engine allows until the hotkey is released.

local XBUTTON2 = 0x06
local LMB_VK   = 0x01

local GUN_NAME  = "[Double-Barrel SG]"
local AMMO_NAME = "Ammo"

local CLICK_INTERVAL_MS = 1
local CLICKS_PER_TICK   = 1
local TRIGGER_DEBOUNCE_MS = 35

local whitelist  = {}
local ammo_cache = {}
local ammo_refs  = {}
local gf_refs    = {}
local gf_state   = {}
local ammo_state = {}
local gf_conns   = {}
local ammo_conns = {}

local selected = nil
local prev_lmb = false

local _armed = false
local _clicking = false
local _click_thread = nil
local _poll_thread = nil
local _cold_thread = nil
local _cold_tick = 0
local _last_trigger_ms = {}
local _trigger_override = nil
local _last_event_text = "Last: none"
local _last_event_color = { 0.75, 0.82, 1, 0.9 }
local _click_impl = nil

menu.add_tab("Shot Detect", "S")
menu.add_group("Shot Detect", "Settings")
menu.add_checkbox("Shot Detect", "Settings", "sd_on", "Enable", true)
menu.add_combo("Shot Detect", "Settings", "sd_trigger", "Trigger",
    { "GunFiring + Ammo", "GunFiring only", "Ammo only" }, 0)

local function now_ms()
    return os.clock() * 1000
end

local function enabled()
    return menu.get("sd_on") == true
end

local function armed()
    return enabled() and input.is_key_down(XBUTTON2)
end

local function iv(o)
    return o and utility.is_valid(o)
end

local function safe_value(o)
    if not o then return nil end
    local ok, value = pcall(function() return o.value end)
    if ok then return value end
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

local function current_trigger()
    if _trigger_override ~= nil then return _trigger_override end
    return menu.get("sd_trigger") or 0
end

local function set_trigger(mode)
    _trigger_override = mode
    pcall(function() menu.set("sd_trigger", mode) end)
end

local function cycle_trigger()
    set_trigger((current_trigger() + 1) % 3)
end

local function trigger_name()
    local names = { "GunFiring + Ammo", "GunFiring only", "Ammo only" }
    return names[current_trigger() + 1] or "GunFiring + Ammo"
end

local function use_gunfiring()
    local mode = current_trigger()
    return mode == 0 or mode == 1
end

local function use_ammo()
    local mode = current_trigger()
    return mode == 0 or mode == 2
end

local function record_event(name, source, status)
    _last_event_text = "Last: " .. source .. " " .. status
    if name then _last_event_text = _last_event_text .. " (" .. name .. ")" end

    if status == "CLICKING" then
        _last_event_color = { 0.2, 1, 0.45, 1 }
    elseif status == "UNARMED" or status == "OFF" then
        _last_event_color = { 1, 0.55, 0.2, 1 }
    else
        _last_event_color = { 0.65, 0.7, 0.8, 1 }
    end
end

local function click_once()
    if _click_impl then
        _click_impl()
        return
    end

    if pcall(function() input.simulate_mouse_click(0) end) then
        _click_impl = function() input.simulate_mouse_click(0) end
    else
        if pcall(function() utility.mouse_click() end) then
            _click_impl = function() utility.mouse_click() end
        else
            _click_impl = function() end
        end
    end
end

local function click_tick()
    if not _clicking then return end
    if not armed() then
        _clicking = false
        return
    end

    for _ = 1, CLICKS_PER_TICK do
        click_once()
    end
end

local function ensure_click_thread()
    if _click_thread then return end
    _click_thread = thread.create(function()
        click_tick()
    end, CLICK_INTERVAL_MS)
end

local function stop_clicking()
    _clicking = false
    if _click_thread then
        thread.stop(_click_thread)
        _click_thread = nil
    end
end

local function start_clicking(name, source)
    if not enabled() then
        record_event(name, source, "OFF")
        return
    end
    if not armed() then
        record_event(name, source, "UNARMED")
        return
    end

    local t = now_ms()
    local last = _last_trigger_ms[name] or 0
    if t - last < TRIGGER_DEBOUNCE_MS then return end
    _last_trigger_ms[name] = t

    _clicking = true
    record_event(name, source, "CLICKING")
    click_once() -- fire immediately on the detection frame.
    ensure_click_thread()
end

local function handle_gunfiring(name, value)
    local current = value and true or false
    local previous = gf_state[name] or false

    if use_gunfiring() and current and not previous then
        start_clicking(name, "GunFiring")
    end

    gf_state[name] = current
end

local function ammo_decreased(previous, current)
    if previous == nil or current == nil then return false end

    local p = tonumber(previous)
    local c = tonumber(current)
    if p and c then return c < p end

    return current ~= previous
end

local function handle_ammo(name, value)
    local previous = ammo_state[name]

    if use_ammo() and ammo_decreased(previous, value) then
        start_clicking(name, "Ammo")
    end

    ammo_state[name] = value
    ammo_cache[name] = value
end

local function disconnect(conn)
    if not conn then return end
    pcall(function() conn:disconnect() end)
    pcall(function() conn:Disconnect() end)
end

local function arm_gunfiring(name, ref)
    disconnect(gf_conns[name])
    gf_conns[name] = nil
    if not iv(ref) then return end

    gf_state[name] = safe_value(ref) and true or false
    local ok, conn = pcall(function()
        return ref.Changed:connect(function(value)
            handle_gunfiring(name, value)
        end)
    end)
    if ok then gf_conns[name] = conn end
end

local function arm_ammo(name, ref)
    disconnect(ammo_conns[name])
    ammo_conns[name] = nil
    if not iv(ref) then return end

    ammo_state[name] = safe_value(ref)
    ammo_cache[name] = ammo_state[name]
    local ok, conn = pcall(function()
        return ref.Changed:connect(function(value)
            handle_ammo(name, value)
        end)
    end)
    if ok then ammo_conns[name] = conn end
end

local function workspace_character(name)
    local ws = game.workspace
    if not iv(ws) then return nil end
    local players_folder = safe_find(ws, "Players", false)
    return safe_find(players_folder, name, false)
end

local function find_gunfiring(name)
    local char = workspace_character(name)
    local body_effects = safe_find(char, "BodyEffects", false)
    return safe_find(body_effects, "GunFiring", false)
end

local function find_ammo(plr, name)
    local function try(container)
        local gun = safe_find(container, GUN_NAME, false)
        return safe_find(gun, AMMO_NAME, false)
    end

    local ammo = try(safe_find(plr, "Backpack", false))
    if ammo then return ammo end

    local char = read_prop(plr, "Character") or safe_find(plr, "Character", false) or workspace_character(name)
    return try(char)
end

local function poll_refs()
    for name in pairs(whitelist) do
        local gf_ref = gf_refs[name]
        if gf_ref and iv(gf_ref) then
            local value = safe_value(gf_ref)
            if value ~= nil then handle_gunfiring(name, value) end
        end

        local ammo_ref = ammo_refs[name]
        if ammo_ref and iv(ammo_ref) then
            local value = safe_value(ammo_ref)
            if value ~= nil then handle_ammo(name, value) end
        end
    end
end

local function refresh_refs()
    _cold_tick = _cold_tick + 1

    local players_service = game.players
    if not iv(players_service) then return end

    for name in pairs(whitelist) do
        local plr = safe_find(players_service, name, false)
        if iv(plr) then
            local gf_ref = gf_refs[name]
            if not iv(gf_ref) or _cold_tick % 40 == 0 then
                gf_ref = find_gunfiring(name)
                gf_refs[name] = gf_ref
                arm_gunfiring(name, gf_ref)
            end

            local ammo_ref = ammo_refs[name]
            if not iv(ammo_ref) or _cold_tick % 40 == 0 then
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
    ammo_refs[name] = nil
    gf_refs[name] = nil
    gf_state[name] = nil
    ammo_state[name] = nil
    _last_trigger_ms[name] = nil

    disconnect(gf_conns[name])
    disconnect(ammo_conns[name])
    gf_conns[name] = nil
    ammo_conns[name] = nil

    if selected == name then selected = nil end
end

function on_player_removed(player)
    if player and player.name then clear_player(player.name) end
end

local function draw_panel()
    local px, py, pw = 14, 14, 232
    local row_h, hdr_h, btn_h, gap = 22, 26, 24, 4
    local trigger_h, status_h = 24, 18
    local list = {}

    for _, player in ipairs(entity.get_players()) do
        if not player.is_local then
            list[#list + 1] = player
        end
    end

    local panel_h = hdr_h + #list * row_h + gap + btn_h + gap + trigger_h + status_h + 6
    draw.rect_filled(px, py, pw, panel_h, { 0.04, 0.04, 0.09, 0.9 }, 5)
    draw.rect(px, py, pw, panel_h, { 0.28, 0.52, 1, 0.7 }, 5)
    draw.rect_filled(px, py, pw, hdr_h, { 0.1, 0.22, 0.52, 0.95 }, 5)

    local wl_n = 0
    for _ in pairs(whitelist) do wl_n = wl_n + 1 end

    local title = "Shot Detect"
    if _clicking then
        title = title .. " [CLICKING]"
    elseif _armed then
        title = title .. " [ARMED]"
    else
        title = title .. " [" .. wl_n .. " wl]"
    end
    draw.text(px + 8, py + 6, title,
        _clicking and { 1, 0.95, 0.25, 1 } or _armed and { 0.2, 1, 0.45, 1 } or { 0.7, 0.9, 1, 1 }, 13)

    local mx, my = utility.get_mouse_pos()
    local lmb_now = input.is_key_down(LMB_VK)
    local clicked = lmb_now and not prev_lmb

    for i, player in ipairs(list) do
        local ry = py + hdr_h + (i - 1) * row_h
        local name = player.name
        local wl = whitelist[name] ~= nil
        local hover = mx >= px and mx <= px + pw and my >= ry and my <= ry + row_h

        draw.rect_filled(px + 2, ry, pw - 4, row_h,
            selected == name and { 0.28, 0.48, 0.95, 0.4 } or
            wl and { 0.08, 0.42, 0.12, 0.32 } or
            hover and { 1, 1, 1, 0.08 } or { 0, 0, 0, 0 })

        draw.circle_filled(px + 11, ry + row_h / 2, 4,
            wl and { 0.2, 1, 0.45, 1 } or { 0.4, 0.4, 0.4, 0.55 })

        local label = name
        if wl and ammo_cache[name] ~= nil then
            label = name .. "  [" .. tostring(ammo_cache[name]) .. "]"
        end

        draw.text(px + 20, ry + row_h / 2 - 6, label,
            wl and { 0.32, 1, 0.52, 1 } or { 1, 1, 1, 0.85 }, 12)

        if hover and clicked then selected = name end
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
            refresh_refs()
        end
    end

    local trigger_y = btn_y + btn_h + gap
    local hover_trigger = mx >= bx and mx <= bx + bw and my >= trigger_y and my <= trigger_y + trigger_h
    local trigger_label = "Trigger: " .. trigger_name()
    local trigger_color = hover_trigger and { 0.25, 0.6, 1, 0.95 } or { 0.11, 0.22, 0.42, 0.9 }

    draw.rect_filled(bx, trigger_y, bw, trigger_h, trigger_color, 4)
    draw.rect(bx, trigger_y, bw, trigger_h, { 0.45, 0.7, 1, 0.55 }, 4)
    local gtw, gth = draw.get_text_size(trigger_label, 12)
    draw.text(bx + bw / 2 - gtw / 2, trigger_y + trigger_h / 2 - gth / 2, trigger_label, { 1, 1, 1, 1 }, 12)

    if hover_trigger and clicked then
        cycle_trigger()
    end

    local status_y = trigger_y + trigger_h + 3
    draw.text(bx + 2, status_y + 3, _last_event_text, _last_event_color, 11)

    prev_lmb = lmb_now
end

function on_pre_frame()
    _armed = armed()
    if not _armed then stop_clicking() end
    poll_refs()
    click_tick()
end

function on_frame()
    if not _poll_thread then _poll_thread = thread.create(poll_refs, 5) end
    if not _cold_thread then _cold_thread = thread.create(refresh_refs, 100) end

    _armed = armed()
    if not _armed then stop_clicking() end

    poll_refs()
    click_tick()

    if enabled() then draw_panel() end
end

print("[ShotDetect] Loaded. Fast GunFiring/Ammo detector ready")
