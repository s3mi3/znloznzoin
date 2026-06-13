-- Shot Detector | Vector Lua Engine
-- Fast GunFiring/Ammo detector for whitelisted players.
-- When a shot is detected while XBUTTON2 is held, the script waits for the
-- configured first-click delay (default 0ms), then clicks continuously until
-- the hotkey is released.

local XBUTTON2 = 0x06
local LMB_VK   = 0x01
local F8_VK    = 0x77

local GUN_NAME  = "[Double-Barrel SG]"
local AMMO_NAME = "Ammo"
local TRIGGER_NAMES = { "GunFiring + Ammo", "GunFiring only", "Ammo only" }

local CLICK_INTERVAL_MS = 1
local CLICKS_PER_TICK   = 1
local TRIGGER_DEBOUNCE_MS = 35
local FIRST_CLICK_DELAY_MAX_MS = 500

local whitelist  = {}
local whitelist_count = 0
local ammo_cache = {}
local ammo_refs  = {}
local gf_refs    = {}
local gf_state   = {}
local ammo_state = {}
local gf_conns   = {}
local ammo_conns = {}

local selected = nil
local prev_lmb = false

local _enabled = true
local _armed = false
local _gui_hidden = false
local _prev_hide_key = false
local _trigger_mode = 0
local _first_delay = 0
local _use_gunfiring = true
local _use_ammo = true
local _clicking = false
local _click_thread = nil
local _poll_thread = nil
local _cold_thread = nil
local _cold_tick = 0
local _last_trigger_ms = {}
local _trigger_override = nil
local _delay_override = nil
local _pending_click = false
local _pending_name = nil
local _pending_source = nil
local _pending_due_ms = 0
local _last_event_text = "Last: none"
local _last_event_color = { 0.75, 0.82, 1, 0.9 }
local _click_impl = nil

if input.simulate_mouse_click then
    local simulate_mouse_click = input.simulate_mouse_click
    _click_impl = function() simulate_mouse_click(0) end
elseif utility.mouse_click then
    local mouse_click = utility.mouse_click
    _click_impl = function() mouse_click() end
else
    _click_impl = function() end
end

menu.add_tab("Shot Detect", "S")
menu.add_group("Shot Detect", "Settings")
menu.add_checkbox("Shot Detect", "Settings", "sd_on", "Enable", true)
menu.add_combo("Shot Detect", "Settings", "sd_trigger", "Trigger",
    { "GunFiring + Ammo", "GunFiring only", "Ammo only" }, 0)
menu.add_slider_int("Shot Detect", "Settings", "sd_first_delay", "First click delay (ms)",
    0, FIRST_CLICK_DELAY_MAX_MS, 0)

local function now_ms()
    return os.clock() * 1000
end

local function enabled()
    return _enabled
end

local function armed()
    return _enabled and input.is_key_down(XBUTTON2)
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

local function clamp_delay(value)
    value = tonumber(value) or 0
    if value < 0 then return 0 end
    if value > FIRST_CLICK_DELAY_MAX_MS then return FIRST_CLICK_DELAY_MAX_MS end
    return math.floor(value + 0.5)
end

local function apply_trigger_mode(mode)
    _trigger_mode = mode or 0
    _use_gunfiring = _trigger_mode == 0 or _trigger_mode == 1
    _use_ammo = _trigger_mode == 0 or _trigger_mode == 2
end

local function refresh_config()
    _enabled = menu.get("sd_on") == true

    if _trigger_override == nil then
        apply_trigger_mode(menu.get("sd_trigger") or 0)
    end

    if _delay_override == nil then
        _first_delay = clamp_delay(menu.get("sd_first_delay") or 0)
    end
end

local function update_gui_toggle()
    local hide_key = input.is_key_down(F8_VK)
    if hide_key and not _prev_hide_key then
        _gui_hidden = not _gui_hidden
    end
    _prev_hide_key = hide_key
end

local function current_trigger()
    return _trigger_mode
end

local function set_trigger(mode)
    _trigger_override = mode
    apply_trigger_mode(mode)
    pcall(function() menu.set("sd_trigger", mode) end)
end

local function cycle_trigger()
    set_trigger((current_trigger() + 1) % 3)
end

local function trigger_name()
    return TRIGGER_NAMES[current_trigger() + 1] or TRIGGER_NAMES[1]
end

local function current_first_delay()
    return _first_delay
end

local function set_first_delay(value)
    _delay_override = clamp_delay(value)
    _first_delay = _delay_override
    pcall(function() menu.set("sd_first_delay", _delay_override) end)
end

local function use_gunfiring()
    return _use_gunfiring
end

local function use_ammo()
    return _use_ammo
end

local function record_event(name, source, status)
    _last_event_text = "Last: " .. source .. " " .. status
    if name then _last_event_text = _last_event_text .. " (" .. name .. ")" end

    if status == "CLICKING" then
        _last_event_color = { 0.2, 1, 0.45, 1 }
    elseif string.sub(status, 1, 5) == "DELAY" then
        _last_event_color = { 1, 0.95, 0.25, 1 }
    elseif status == "UNARMED" or status == "OFF" then
        _last_event_color = { 1, 0.55, 0.2, 1 }
    else
        _last_event_color = { 0.65, 0.7, 0.8, 1 }
    end
end

local function click_once()
    _click_impl()
end

local function click_tick()
    if not _clicking then return end
    if not _enabled or not input.is_key_down(XBUTTON2) then
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

local function begin_clicking(name, source)
    _clicking = true
    record_event(name, source, "CLICKING")
    click_once() -- fire immediately when the configured delay expires.
    ensure_click_thread()
end

local function stop_clicking()
    if not _clicking and not _pending_click and not _click_thread then return end

    _clicking = false
    _pending_click = false
    _pending_name = nil
    _pending_source = nil
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

    local delay = current_first_delay()
    if delay <= 0 then
        begin_clicking(name, source)
        return
    end

    _pending_click = true
    _pending_name = name
    _pending_source = source
    _pending_due_ms = t + delay
    record_event(name, source, "DELAY " .. delay .. "ms")
end

local function process_pending_click()
    if not _pending_click then return end

    if not armed() then
        _pending_click = false
        _pending_name = nil
        _pending_source = nil
        return
    end

    if now_ms() < _pending_due_ms then return end

    local name = _pending_name
    local source = _pending_source
    _pending_click = false
    _pending_name = nil
    _pending_source = nil
    begin_clicking(name, source)
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
    if whitelist_count == 0 then return end

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
    if whitelist_count == 0 then return end

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
    if whitelist[name] then
        whitelist_count = whitelist_count - 1
    end

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
    local trigger_h, delay_h, status_h = 24, 26, 18
    local list = {}

    for _, player in ipairs(entity.get_players()) do
        if not player.is_local then
            list[#list + 1] = player
        end
    end

    local panel_h = hdr_h + #list * row_h + gap + btn_h + gap + trigger_h + gap + delay_h + status_h + 6
    draw.rect_filled(px, py, pw, panel_h, { 0.04, 0.04, 0.09, 0.9 }, 5)
    draw.rect(px, py, pw, panel_h, { 0.28, 0.52, 1, 0.7 }, 5)
    draw.rect_filled(px, py, pw, hdr_h, { 0.1, 0.22, 0.52, 0.95 }, 5)

    local title = "Shot Detect"
    if _clicking then
        title = title .. " [CLICKING]"
    elseif _armed then
        title = title .. " [ARMED]"
    else
        title = title .. " [" .. whitelist_count .. " wl]"
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
            if not whitelist[selected] then
                whitelist_count = whitelist_count + 1
            end
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

    local delay_y = trigger_y + trigger_h + gap
    local hover_delay = mx >= bx and mx <= bx + bw and my >= delay_y and my <= delay_y + delay_h
    local delay = current_first_delay()
    local delay_label = "First delay: " .. delay .. "ms"
    local delay_color = hover_delay and { 0.25, 0.6, 1, 0.95 } or { 0.09, 0.18, 0.36, 0.9 }

    draw.rect_filled(bx, delay_y, bw, delay_h, delay_color, 4)
    draw.rect(bx, delay_y, bw, delay_h, { 0.45, 0.7, 1, 0.55 }, 4)

    local bar_x = bx + 8
    local bar_y = delay_y + delay_h - 8
    local bar_w = bw - 16
    local fill_w = bar_w * delay / FIRST_CLICK_DELAY_MAX_MS
    draw.rect_filled(bar_x, bar_y, bar_w, 3, { 0.02, 0.05, 0.1, 0.9 }, 2)
    if fill_w > 0 then
        draw.rect_filled(bar_x, bar_y, fill_w, 3, { 0.25, 0.75, 1, 1 }, 2)
    end

    local dtw, dth = draw.get_text_size(delay_label, 11)
    draw.text(bx + bw / 2 - dtw / 2, delay_y + 4, delay_label, { 1, 1, 1, 1 }, 11)

    if hover_delay and lmb_now then
        local ratio = (mx - bar_x) / bar_w
        if ratio < 0 then ratio = 0 end
        if ratio > 1 then ratio = 1 end
        set_first_delay(ratio * FIRST_CLICK_DELAY_MAX_MS)
    end

    local status_y = delay_y + delay_h + 3
    draw.text(bx + 2, status_y + 3, _last_event_text, _last_event_color, 11)

    prev_lmb = lmb_now
end

function on_pre_frame()
    refresh_config()
    _armed = armed()
    if not _armed then stop_clicking() end
    poll_refs()
    process_pending_click()
    click_tick()
end

function on_frame()
    if not _poll_thread then _poll_thread = thread.create(poll_refs, 5) end
    if not _cold_thread then _cold_thread = thread.create(refresh_refs, 100) end

    refresh_config()
    _armed = armed()
    if not _armed then stop_clicking() end

    poll_refs()
    process_pending_click()
    click_tick()

    update_gui_toggle()
    if enabled() and not _gui_hidden then
        draw_panel()
    else
        prev_lmb = input.is_key_down(LMB_VK)
    end
end

print("[ShotDetect] Loaded. Fast GunFiring/Ammo detector ready")
