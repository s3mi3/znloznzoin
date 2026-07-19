--[[
    Ping Display Spoofer  —  Vector Lua Engine port  (v6)
    -----------------------------------------------------
    Two spoof methods, each toggleable:

      1. OVERLAY COVER (default, most reliable)
         Uses the `draw` API to paint a fake "<number> ms" on top of the
         real ping display. Works against anything — including the
         Roblox built-in Performance Stats overlay whose ping value
         lives in native code and can't be patched via the GC API.

      2. GC PATCHING (advanced)
         For custom in-game HUDs that store ping in a plain Lua
         variable. Uses `applygc` to write the spoofed value on a
         background thread. Requires knowing the game's variable name
         (use "Dump GC to file" and search the dump if defaults miss).

    Purely cosmetic — only changes what YOU see on your screen. Real
    network latency is unchanged and other players see your true ping.
]]

------------------------------------------------------------
-- CONFIG (initial defaults; everything is editable in the menu)
------------------------------------------------------------
local DEFAULT_KEYS = "Ping,NetworkPing,DisplayPing,ClientPing,Latency,PingMS,PingValue,PingText,NetPing"
local DEFAULT_DUMP_PATH = "C:/vector_gc_dump.txt"

------------------------------------------------------------
-- MENU
------------------------------------------------------------
menu.add_tab("Ping Spoof", "P")

menu.add_group("Ping Spoof", "Method",           -1)
menu.add_group("Ping Spoof", "Value",             0)
menu.add_group("Ping Spoof", "Overlay position",  0, true)
menu.add_group("Ping Spoof", "Style",            -1)
menu.add_group("Ping Spoof", "GC patching",      -1)
menu.add_group("Ping Spoof", "Status",           -1)

-- Method
menu.add_checkbox("Ping Spoof", "Method", "overlay_on",
    "Draw overlay cover  (recommended)", true)
menu.add_checkbox("Ping Spoof", "Method", "gc_on",
    "Also patch game Lua state (advanced)", false)

-- Value
menu.add_slider_float("Ping Spoof", "Value", "shown",  "Ping to display",
    1, 999, 35, "%.0f ms")
menu.add_slider_float("Ping Spoof", "Value", "jitter", "Jitter",
    0, 50, 4, "+/-%.0f ms")
menu.add_slider_float("Ping Spoof", "Value", "resample", "Update every",
    200, 3000, 1000, "%.0f ms")

-- Overlay position — defaults roughly target Roblox's built-in
-- Performance Stats "NetworkPing" cell on a common 1920-wide screen;
-- fine-tune with the position guide.
menu.add_slider_float("Ping Spoof", "Overlay position", "ox",
    "X from right edge", 0, 2000, 250, "%.0f px")
menu.add_slider_float("Ping Spoof", "Overlay position", "oy",
    "Y from top", 0, 500, 24, "%.0f px")
menu.add_slider_float("Ping Spoof", "Overlay position", "ow",
    "Width", 20, 400, 90, "%.0f px")
menu.add_slider_float("Ping Spoof", "Overlay position", "oh",
    "Height", 10, 120, 20, "%.0f px")
menu.add_checkbox(    "Ping Spoof", "Overlay position", "guide",
    "Show position guide (yellow outline)", false)

-- Style — defaults blend into the Roblox Performance Stats bar
-- (dark semi-transparent grey background, white text).
menu.add_slider_float( "Ping Spoof", "Style", "font_size", "Font size",
    8, 32, 13, "%.0f")
menu.add_input(        "Ping Spoof", "Style", "suffix", "Suffix", " ms")
menu.add_colorpicker(  "Ping Spoof", "Style", "bgcol",  "Background",
    {0.13, 0.13, 0.14, 0.85})
menu.add_colorpicker(  "Ping Spoof", "Style", "txtcol", "Text",
    {1.00, 1.00, 1.00, 1.00})
menu.add_checkbox(     "Ping Spoof", "Style", "center",
    "Center text (else left align)", true)

-- GC patching
menu.add_input(       "Ping Spoof", "GC patching", "keys",
    "Ping key names (comma separated)", DEFAULT_KEYS)
menu.add_slider_float("Ping Spoof", "GC patching", "interval",
    "Patch interval", 50, 1000, 100, "%.0f ms")
menu.add_input(       "Ping Spoof", "GC patching", "search_val",
    "Current real ping (for search)", "59")
menu.add_button(      "Ping Spoof", "GC patching", "dumpbtn",
    "Dump GC to file", function()
        print("[PingSpoof] Dumping GC to " .. DEFAULT_DUMP_PATH .. " ...")
        local n = dumpgc(DEFAULT_DUMP_PATH)
        print("[PingSpoof] Wrote " .. tostring(n) .. " entries.")
        print("[PingSpoof] Open the file and search for '= " ..
            tostring(menu.get("search_val") or "") ..
            "' (your current real ping) to find the ping key.")
    end)
menu.add_button(      "Ping Spoof", "GC patching", "try_common",
    "Try common CoreScript ping keys", function()
        local candidates = {
            "pingMs", "PingMs", "networkPingMs",
            "dataPing", "DataPing",
            "lastPing", "LastPing",
            "Value",   -- some CoreScripts use generic value fields
        }
        local extra = {}
        for k in string.gmatch(menu.get("keys") or "", "([^,]+)") do
            local t = k:match("^%s*(.-)%s*$")
            if t ~= "" then table.insert(extra, t) end
        end
        for _, k in ipairs(candidates) do table.insert(extra, k) end
        local seen, unique = {}, {}
        for _, k in ipairs(extra) do
            if not seen[k] then seen[k] = true; table.insert(unique, k) end
        end
        menu.set("keys", table.concat(unique, ","))
        print("[PingSpoof] Expanded key list to " .. #unique .. " candidates.")
    end)

-- Status
menu.add_checkbox("Ping Spoof", "Status", "show_readout",
    "Show status readout (bottom-left)", true)

------------------------------------------------------------
-- STATE
------------------------------------------------------------
refreshgc()

local worker_thread   = nil
local worker_interval = 100
local parsed_keys     = {}
local last_keys_input = ""

local current_value    = 35    -- what the overlay + patch is displaying
local next_resample_at = 0
local last_patch_count = 0

------------------------------------------------------------
-- HELPERS
------------------------------------------------------------
local function parse_key_csv(csv)
    local out = {}
    for k in string.gmatch(csv or "", "([^,]+)") do
        local trimmed = k:match("^%s*(.-)%s*$")
        if trimmed ~= "" then table.insert(out, trimmed) end
    end
    return out
end

local function refresh_keys_if_changed()
    local csv = menu.get("keys") or ""
    if csv == last_keys_input then return end
    last_keys_input = csv
    parsed_keys = parse_key_csv(csv)
    if #parsed_keys > 0 then getgc(parsed_keys) end
end

local function resample_value()
    local base   = math.floor((menu.get("shown")  or 35) + 0.5)
    local jitter = math.floor((menu.get("jitter") or 0)  + 0.5)
    local jval   = 0
    if jitter > 0 then jval = math.random(-jitter, jitter) end
    current_value = math.max(1, base + jval)
    return current_value
end

local function tick_resample()
    local now = utility.get_time() * 1000
    if now >= next_resample_at then
        local period = menu.get("resample") or 1000
        if period < 50 then period = 50 end
        next_resample_at = now + period
        resample_value()
    end
end

local function patch_now()
    if #parsed_keys == 0 then return 0 end
    local values = {}
    for _, k in ipairs(parsed_keys) do values[k] = current_value end
    local patched = applygc(parsed_keys, values)
    last_patch_count = patched
    return patched
end

local function ensure_worker()
    local interval = math.floor((menu.get("interval") or 100) + 0.5)
    if interval < 1 then interval = 1 end
    if worker_thread and thread.is_running(worker_thread) then
        if interval ~= worker_interval then
            thread.set_interval(worker_thread, interval)
            worker_interval = interval
        end
        return
    end
    worker_interval = interval
    worker_thread = thread.create(function()
        if not menu.get("gc_on") then return end
        refresh_keys_if_changed()
        patch_now()
    end, interval)
end

local function stop_worker()
    if worker_thread and thread.is_running(worker_thread) then
        thread.stop(worker_thread)
    end
    worker_thread = nil
end

menu.set_callback("gc_on", function(v)
    if v then
        refresh_keys_if_changed()
        ensure_worker()
        tick_resample()
        patch_now()
    else
        stop_worker()
    end
end)
menu.set_callback("keys",     function(_) refresh_keys_if_changed() end)
menu.set_callback("interval", function(_) if menu.get("gc_on") then ensure_worker() end end)

------------------------------------------------------------
-- DRAW HELPERS
------------------------------------------------------------
local function draw_overlay_cover()
    if not menu.get("overlay_on") then return end

    local w, _ = utility.get_screen_size()
    local ox   = menu.get("ox") or 90
    local oy   = menu.get("oy") or 20
    local ow   = menu.get("ow") or 80
    local oh   = menu.get("oh") or 22
    local fs   = menu.get("font_size") or 13

    local x = w - ox - ow
    local y = oy

    local bg  = menu.get_color("bgcol")
    local tc  = menu.get_color("txtcol")

    draw.rect_filled(x, y, ow, oh, bg)

    local text = tostring(current_value) .. (menu.get("suffix") or " ms")
    local tw, th = draw.get_text_size(text, fs)

    local tx
    if menu.get("center") then
        tx = x + (ow - tw) * 0.5
    else
        tx = x + 4
    end
    local ty = y + (oh - th) * 0.5
    draw.text(tx, ty, text, tc, fs)

    if menu.get("guide") then
        draw.rect(x, y, ow, oh, {1, 0.85, 0.2, 1.0}, 0, 2)
    end
end

local function draw_status_readout()
    if not menu.get("show_readout") then return end

    local w, h = utility.get_screen_size()
    local x = 12
    local y = h - 12 - 46

    local overlay_on = menu.get("overlay_on")
    local gc_on      = menu.get("gc_on")
    local any_on     = overlay_on or gc_on

    local color_bg   = { 0.05, 0.06, 0.08, 0.85 }
    local color_line = { 0.20, 0.22, 0.28, 1.00 }
    local color_txt  = { 0.92, 0.94, 1.00, 1.00 }
    local color_dim  = { 0.60, 0.64, 0.72, 1.00 }
    local color_on   = { 0.35, 0.90, 0.55, 1.00 }
    local color_off  = { 0.90, 0.35, 0.35, 1.00 }

    draw.rect_filled(x, y, 210, 46, color_bg)
    draw.rect(x, y, 210, 46, color_line)

    draw.text(x + 8, y + 6, "PING SPOOF", color_dim, 12)
    draw.text(x + 8, y + 24,
        string.format("shown %d ms", current_value), color_txt, 13)

    local status_txt = any_on and "ON" or "OFF"
    local status_col = any_on and color_on or color_off
    local tw, _ = draw.get_text_size(status_txt, 12)
    draw.text(x + 210 - tw - 8, y + 6, status_txt, status_col, 12)

    local mode_bits = {}
    if overlay_on then table.insert(mode_bits, "OVL") end
    if gc_on      then table.insert(mode_bits, "GC:"..tostring(last_patch_count)) end
    if #mode_bits == 0 then table.insert(mode_bits, "-") end
    draw.text(x + 210 - 80, y + 26, table.concat(mode_bits, " "), color_dim, 11)
end

------------------------------------------------------------
-- MAIN LOOP
------------------------------------------------------------
function on_frame()
    refresh_keys_if_changed()
    tick_resample()

    if menu.get("gc_on") and not (worker_thread and thread.is_running(worker_thread)) then
        ensure_worker()
    end

    draw_overlay_cover()
    draw_status_readout()
end

print("[PingSpoof] Vector port v6 loaded. Open the 'Ping Spoof' tab to configure.")
print("[PingSpoof] Recommended: enable 'Draw overlay cover' and turn on 'Show position guide' to align it over the real ping.")
