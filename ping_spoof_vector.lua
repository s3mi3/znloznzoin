--[[
    Ping Display Spoofer  —  Vector Lua Engine port
    -----------------------------------------------
    This is a port of the Roblox-executor version for the external Vector
    engine (https://project-vector-1.gitbook.io/vector-lua-engine).

    Constraints of the Vector Game API that shape this port:
      * No `Instance.new`, no `RunService`, no `Stats` service — we run
        under `on_frame()` and `thread.create()`.
      * `GuiObject.Text` is read-only through this API, so we cannot
        overwrite the HUD label directly.
      * Numbers that live in the game's Lua heap CAN be patched via the
        GC API (`applygc`). Most custom Roblox HUDs cache the current
        ping in a plain Lua variable each frame before writing it to the
        label — that's the value we patch.

    Workflow:
      1. Load this script in the Vector engine.
      2. Open the "Ping Spoof" tab in the menu.
      3. Enable the spoof and pick a mode + values.
      4. If nothing changes, click "Dump GC to file" to write every
         Lua key in the process to disk. Open the file, find the key
         name your game uses for ping (search for "ping", "ms", or a
         number matching what the HUD shows), and paste it into the
         "Ping key names" input.

    Purely cosmetic — only changes what YOU see on your screen. Real
    network latency is unchanged and other players see your true ping.
]]

------------------------------------------------------------
-- CONFIG (initial values; everything is editable from the menu)
------------------------------------------------------------
local DEFAULT_KEYS = "Ping,NetworkPing,DisplayPing,ClientPing,Latency,PingMS,PingValue,PingText,NetPing"
local DEFAULT_MODE_INDEX  = 0     -- 0 = Add to real, 1 = Fixed
local DEFAULT_EXTRA       = 50    -- ms added to real ping
local DEFAULT_FIXED       = 35
local DEFAULT_JITTER      = 4
local DEFAULT_INTERVAL_MS = 100
local DEFAULT_DUMP_PATH   = "C:/vector_gc_dump.txt"

------------------------------------------------------------
-- MENU
------------------------------------------------------------
menu.add_tab("Ping Spoof", "P")

menu.add_group("Ping Spoof", "Spoof",   0)
menu.add_group("Ping Spoof", "Values",  0, true)
menu.add_group("Ping Spoof", "Keys",   -1)
menu.add_group("Ping Spoof", "Status", -1)

menu.add_checkbox(   "Ping Spoof", "Spoof", "enabled", "Enable Spoof", false)
menu.add_combo(      "Ping Spoof", "Spoof", "mode", "Mode",
    {"Add to real", "Fixed value"}, DEFAULT_MODE_INDEX, { parent = "enabled" })
menu.add_slider_float("Ping Spoof", "Spoof", "interval", "Patch interval (ms)",
    50, 1000, DEFAULT_INTERVAL_MS, "%.0f ms", { parent = "enabled" })

menu.add_slider_float("Ping Spoof", "Values", "extra",  "Extra ping",
    0, 500,  DEFAULT_EXTRA,  "+%.0f ms",   { parent = "enabled" })
menu.add_slider_float("Ping Spoof", "Values", "fixed",  "Fixed ping",
    1, 1000, DEFAULT_FIXED,  "%.0f ms",    { parent = "enabled" })
menu.add_slider_float("Ping Spoof", "Values", "jitter", "Jitter",
    0, 50,   DEFAULT_JITTER, "+/-%.0f ms", { parent = "enabled" })

menu.add_input( "Ping Spoof", "Keys", "keys",
    "Ping key names (comma separated)", DEFAULT_KEYS)
menu.add_button("Ping Spoof", "Keys", "dumpbtn", "Dump GC to file", function()
    print("[PingSpoof] Dumping GC to " .. DEFAULT_DUMP_PATH .. " ...")
    local n = dumpgc(DEFAULT_DUMP_PATH)
    print("[PingSpoof] Wrote " .. tostring(n) .. " entries.")
end)
menu.add_button("Ping Spoof", "Keys", "warmbtn", "Warm key cache", function()
    local keys = ({})
    for k in string.gmatch(menu.get("keys") or "", "([^,]+)") do
        local trimmed = k:match("^%s*(.-)%s*$")
        if trimmed ~= "" then table.insert(keys, trimmed) end
    end
    if #keys > 0 then
        local n = getgc(keys)
        print("[PingSpoof] Warmed cache — " .. tostring(n) .. " node(s) found.")
    else
        print("[PingSpoof] No keys configured.")
    end
end)

menu.add_label( "Ping Spoof", "Status", "Real ping is sampled from the visible HUD label.")

------------------------------------------------------------
-- STATE
------------------------------------------------------------
refreshgc()

local worker_thread    = nil
local worker_interval  = DEFAULT_INTERVAL_MS

local parsed_keys      = {}
local last_keys_input  = ""

local cached_real_ping = 0    -- last real value read from the HUD text
local cached_shown     = 0    -- last value we wrote via applygc
local last_jitter_ms   = 0
local last_write_time  = 0
local last_write_count = 0

local cached_label     = nil  -- last TextLabel matched (Instance)
local label_scan_time  = 0

local LABEL_NAME_KEYWORDS = {
    "ping", "networkping", "latency", "netping", "displayping",
}

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
    if #parsed_keys > 0 then
        getgc(parsed_keys)   -- non-blocking warm
    end
end

-- Walk the local player's Instance tree to find a TextLabel whose Name
-- or Text looks like a ping display. Cached — we only rescan every
-- ~2 seconds or when the cached one becomes invalid.
local function find_ping_label()
    local now = utility.get_time()
    if cached_label and utility.is_valid(cached_label) then
        return cached_label
    end
    if now - label_scan_time < 2.0 then return nil end
    label_scan_time = now

    local roots = {}
    if game.local_player and utility.is_valid(game.local_player) then
        table.insert(roots, game.local_player)
    end
    local ok, sg = pcall(function() return game.get_service("StarterGui") end)
    if ok and sg then table.insert(roots, sg) end
    if game.workspace then table.insert(roots, game.workspace) end

    for _, root in ipairs(roots) do
        local ok2, descs = pcall(function() return root:get_descendants() end)
        if ok2 and type(descs) == "table" then
            for _, inst in ipairs(descs) do
                if utility.is_valid(inst) and (inst:is_a("TextLabel") or inst:is_a("TextButton")) then
                    local name = string.lower(inst.Name or "")
                    local matched = false
                    for _, kw in ipairs(LABEL_NAME_KEYWORDS) do
                        if string.find(name, kw, 1, true) then matched = true; break end
                    end
                    if not matched then
                        local text = string.lower(inst.Text or "")
                        if string.match(text, "^%s*[%w%p]*%s*%d+%s*ms%s*$") then
                            matched = true
                        end
                    end
                    if matched then
                        cached_label = inst
                        return inst
                    end
                end
            end
        end
    end
    return nil
end

-- Best-effort read of the "real" current ping.
-- If the label text is different from what we last wrote via applygc,
-- we treat it as a genuine game update (the game slipped an update in
-- between our patches) and cache it. Otherwise keep the last known value.
local function sample_real_ping()
    local label = find_ping_label()
    if not label or not utility.is_valid(label) then return cached_real_ping end
    local text = label.Text or ""
    local n = tonumber(string.match(text, "(%-?%d+%.?%d*)"))
    if not n then return cached_real_ping end
    n = math.floor(n + 0.5)
    if not menu.get("enabled") or n ~= cached_shown then
        cached_real_ping = n
    end
    return cached_real_ping
end

local function compute_shown()
    local mode   = menu.get("mode") or 0
    local jitter = math.floor((menu.get("jitter") or 0) + 0.5)
    local jval   = 0
    if jitter > 0 then jval = math.random(-jitter, jitter) end
    last_jitter_ms = jval

    local base
    if mode == 1 then
        base = math.floor((menu.get("fixed") or DEFAULT_FIXED) + 0.5)
    else
        base = sample_real_ping() + math.floor((menu.get("extra") or DEFAULT_EXTRA) + 0.5)
    end
    return math.max(1, base + jval)
end

local function patch_now()
    if #parsed_keys == 0 then return 0 end
    local desired = compute_shown()

    local values = {}
    for _, k in ipairs(parsed_keys) do values[k] = desired end

    local patched = applygc(parsed_keys, values)
    cached_shown     = desired
    last_write_time  = utility.get_time()
    last_write_count = patched
    return patched
end

local function ensure_worker()
    local interval = math.floor((menu.get("interval") or DEFAULT_INTERVAL_MS) + 0.5)
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
        if not menu.get("enabled") then return end
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

------------------------------------------------------------
-- CALLBACKS — refresh caches / worker whenever config changes
------------------------------------------------------------
menu.set_callback("enabled", function(v)
    if v then
        refresh_keys_if_changed()
        ensure_worker()
        patch_now()                     -- instant application
    else
        stop_worker()
    end
end)

menu.set_callback("keys", function(_) refresh_keys_if_changed() end)
menu.set_callback("interval", function(_) ensure_worker() end)

-- Mode / value changes take effect on the next worker tick automatically.

------------------------------------------------------------
-- on_frame — kept lightweight: sample real ping + update status label.
-- Actual patching happens on the background thread.
------------------------------------------------------------
local status_last_update = 0
function on_frame()
    refresh_keys_if_changed()

    -- Keep our best-effort real-ping cache warm.
    sample_real_ping()

    -- Update the status label at ~5 Hz.
    local now = utility.get_time()
    if now - status_last_update >= 0.2 then
        status_last_update = now
        -- Nothing to draw from a label element — but we can print into
        -- the console if debug ever gets flipped on. Leaving intentional
        -- room here for future draw.text() based on-screen readouts.
    end

    -- If the user enabled the spoof but the worker died (rare —
    -- e.g. after the engine reset threads), restart it.
    if menu.get("enabled") and not (worker_thread and thread.is_running(worker_thread)) then
        ensure_worker()
    end
end

------------------------------------------------------------
-- Optional on-screen readout — small floating text so you can see
-- what's happening without opening the menu.
------------------------------------------------------------
menu.add_checkbox("Ping Spoof", "Status", "show_readout",
    "Show on-screen readout", true)

local READOUT_OFFSET_X = 12
local READOUT_OFFSET_Y = 12

local original_on_frame = on_frame
function on_frame()
    original_on_frame()
    if not menu.get("show_readout") then return end

    local w, h = utility.get_screen_size()
    local x = READOUT_OFFSET_X
    local y = h - READOUT_OFFSET_Y - 46

    local enabled = menu.get("enabled")
    local color_bg   = { 0.05, 0.06, 0.08, 0.85 }
    local color_line = { 0.20, 0.22, 0.28, 1.00 }
    local color_txt  = { 0.92, 0.94, 1.00, 1.00 }
    local color_dim  = { 0.60, 0.64, 0.72, 1.00 }
    local color_on   = { 0.35, 0.90, 0.55, 1.00 }
    local color_off  = { 0.90, 0.35, 0.35, 1.00 }

    draw.rect_filled(x, y, 210, 46, color_bg)
    draw.rect(x, y, 210, 46, color_line)

    draw.text(x + 8, y + 6, "PING SPOOF",  color_dim, 12)
    draw.text(x + 8, y + 24,
        string.format("real %d  shown %d", cached_real_ping, cached_shown),
        color_txt, 13)

    local status_txt = enabled and "ON" or "OFF"
    local status_col = enabled and color_on or color_off
    local tw, _ = draw.get_text_size(status_txt, 12)
    draw.text(x + 210 - tw - 8, y + 6, status_txt, status_col, 12)

    local patch_txt = string.format("%d node(s)", last_write_count)
    draw.text(x + 210 - 60, y + 26, patch_txt, color_dim, 11)
end

print("[PingSpoof] Vector port loaded. Open the 'Ping Spoof' tab to configure.")
