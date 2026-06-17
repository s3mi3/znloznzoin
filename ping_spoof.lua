--[[
    Ping Display Spoofer  (v3 — realistic)
    --------------------------------------
    Overrides the on-screen ping HUD with a value that LOOKS real:
    it takes your actual current ping and adds a configurable offset
    plus small natural jitter, so the number drifts up and down the
    way a real connection does.

    Two modes:
        "add"   (default)  -> displayed = realPing + EXTRA_PING + jitter
        "fixed"            -> displayed = FAKE_PING + jitter

    This is purely a client-side visual change. Your real latency and
    what other players see are unaffected.

    LIVE CONTROL
        _G.PingSpoofMode      = "add"   -- or "fixed"
        _G.PingSpoofExtra     = 50      -- ms added to real ping
        _G.PingSpoofJitter    = 4       -- +/- random ms wiggle
        _G.PingSpoofFixed     = 35      -- value used in "fixed" mode
        _G.PingSpoofEnabled   = false   -- stop the spoof
        _G.PingSpoofDebug     = true    -- verbose logging
]]

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local MODE             = "add"     -- "add" or "fixed"
local EXTRA_PING       = 50        -- ms added to your REAL ping (mode "add")
local FAKE_PING        = 35        -- used in mode "fixed"
local JITTER           = 4         -- +/- random ms wiggle per refresh
local DRIFT_SPEED      = 0.6       -- how fast the wiggle moves (smaller = slower)
local SUFFIX           = " ms"     -- text appended after the number
local UPDATE_INTERVAL  = 0.25      -- seconds between refreshes (lower = jumpier)
local RESCAN_INTERVAL  = 1.0       -- how often we re-scan for new labels

-- Name candidates (case-insensitive contains match on Name):
local NAME_KEYWORDS    = { "ping", "networkping", "latency", "ms" }

-- Text pattern: anything that looks like "<number> ms"
local TEXT_PATTERN     = "^%s*[%w%p]*%s*%d+%s*ms%s*$"
------------------------------------------------------------

_G.PingSpoofEnabled = true
_G.PingSpoofMode    = _G.PingSpoofMode   or MODE
_G.PingSpoofExtra   = _G.PingSpoofExtra  or EXTRA_PING
_G.PingSpoofFixed   = _G.PingSpoofFixed  or FAKE_PING
_G.PingSpoofJitter  = _G.PingSpoofJitter or JITTER
_G.PingSpoofDebug   = _G.PingSpoofDebug == nil and true or _G.PingSpoofDebug

local Players      = game:GetService("Players")
local CoreGui      = game:GetService("CoreGui")
local RunService   = game:GetService("RunService")
local Stats        = game:GetService("Stats")
local LocalPlayer  = Players.LocalPlayer
local PlayerGui    = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui", 5)

local function dbg(...)
    if _G.PingSpoofDebug then
        print("[PingSpoof]", ...)
    end
end

-- Read the player's real ping in ms. Roblox exposes this through
-- Stats.Network.ServerStatsItem["Data Ping"]:GetValue(). Wrapped in
-- pcall because the path can vary slightly across client versions.
local function getRealPing()
    local ok, value = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and typeof(value) == "number" then
        return value
    end
    return 0
end

-- The displayed value is recomputed ONLY when the real ping (or a config
-- value) changes. This keeps the spoofed number perfectly in sync with
-- the actual cadence of your connection (real ping in Roblox refreshes
-- about once per second), so the HUD never looks jittery or fake.
local cachedDisplayed   = 0
local lastRealInt       = nil
local lastMode          = nil
local lastExtra         = nil
local lastFixed         = nil
local lastJitter        = nil
local lastJitterSample  = 0

local function recomputeIfChanged(force)
    local mode    = _G.PingSpoofMode   or MODE
    local extra   = _G.PingSpoofExtra  or EXTRA_PING
    local fixed   = _G.PingSpoofFixed  or FAKE_PING
    local jitter  = _G.PingSpoofJitter or JITTER
    local realInt = math.floor(getRealPing() + 0.5)

    local changed = force
        or realInt ~= lastRealInt
        or mode    ~= lastMode
        or extra   ~= lastExtra
        or fixed   ~= lastFixed
        or jitter  ~= lastJitter

    if not changed then return false end

    -- Resample jitter only when real ping (or config) actually changes.
    if jitter > 0 then
        lastJitterSample = math.random(-jitter, jitter)
    else
        lastJitterSample = 0
    end

    local base
    if mode == "fixed" then
        base = fixed
    else
        base = realInt + extra
    end

    cachedDisplayed = math.max(1, base + lastJitterSample)
    lastRealInt = realInt
    lastMode    = mode
    lastExtra   = extra
    lastFixed   = fixed
    lastJitter  = jitter
    return true
end

local function computeDisplayedPing()
    return cachedDisplayed
end

local function buildText()
    return tostring(cachedDisplayed) .. SUFFIX
end

recomputeIfChanged(true)

-- Decide whether a given Instance is a ping-displaying TextLabel/TextButton.
local function isPingLabel(inst)
    if not (inst:IsA("TextLabel") or inst:IsA("TextButton")) then
        return false
    end

    local name = string.lower(inst.Name or "")
    for _, kw in ipairs(NAME_KEYWORDS) do
        if string.find(name, kw, 1, true) then
            return true
        end
    end

    local text = string.lower(inst.Text or "")
    if string.match(text, TEXT_PATTERN) then
        return true
    end

    return false
end

-- Safely iterate descendants of a root, swallowing errors (CoreGui can
-- throw on certain executors / security contexts).
local function safeDescendants(root)
    local ok, list = pcall(function() return root:GetDescendants() end)
    if ok and type(list) == "table" then return list end
    return {}
end

local hooked = {}

local function hookLabel(label)
    if hooked[label] then return end
    hooked[label] = true

    dbg("Hooking", label:GetFullName(), "| current text:", label.Text)

    -- Lock the Text property: whenever the game writes a new value,
    -- immediately overwrite it.
    local conn
    conn = label:GetPropertyChangedSignal("Text"):Connect(function()
        if not _G.PingSpoofEnabled then return end
        local desired = buildText()
        if label.Text ~= desired then
            label.Text = desired
        end
    end)

    -- Clean up if the label is destroyed.
    label.AncestryChanged:Connect(function(_, parent)
        if not parent then
            hooked[label] = nil
            if conn then conn:Disconnect() end
        end
    end)

    label.Text = buildText()
end

local function scanRoot(root)
    if not root then return 0 end
    local found = 0
    for _, inst in ipairs(safeDescendants(root)) do
        local ok, isPing = pcall(isPingLabel, inst)
        if ok and isPing then
            hookLabel(inst)
            found = found + 1
        end
    end
    return found
end

local function fullScan()
    local total = 0
    total = total + scanRoot(PlayerGui)
    total = total + scanRoot(CoreGui)
    -- Some executors expose RobloxGui directly:
    local ok, rg = pcall(function() return CoreGui:FindFirstChild("RobloxGui") end)
    if ok and rg then total = total + scanRoot(rg) end
    return total
end

-- Initial sweep.
local hits = fullScan()
dbg(("Initial scan hooked %d label(s)."):format(hits))
if hits == 0 then
    warn("[PingSpoof] No ping label found yet. Will keep watching... If it never finds one, run _G.PingSpoofDump() to list candidates.")
end

-- Watch for newly-added labels (HUDs often get rebuilt on respawn).
local function watchDescendants(root)
    if not root then return end
    root.DescendantAdded:Connect(function(inst)
        task.wait() -- let properties initialise
        local ok, isPing = pcall(isPingLabel, inst)
        if ok and isPing then
            hookLabel(inst)
        end
    end)
end
watchDescendants(PlayerGui)
watchDescendants(CoreGui)

-- Poll real ping a few times a second; only WRITE to labels when the
-- displayed value actually changes. The effective text-update rate is
-- therefore identical to your real ping's update rate (≈1 Hz).
local pollAccum, rescanAccum = 0, 0
RunService.Heartbeat:Connect(function(dt)
    pollAccum = pollAccum + dt
    if pollAccum >= UPDATE_INTERVAL then
        pollAccum = 0
        if _G.PingSpoofEnabled and recomputeIfChanged(false) then
            local desired = buildText()
            for label in pairs(hooked) do
                if label and label.Parent and label.Text ~= desired then
                    label.Text = desired
                end
            end
        end
    end

    rescanAccum = rescanAccum + dt
    if rescanAccum >= RESCAN_INTERVAL then
        rescanAccum = 0
        fullScan()
    end
end)

-- Diagnostic helper: list every TextLabel/TextButton whose text contains
-- "ms" so you can see what to target.
_G.PingSpoofDump = function()
    print("[PingSpoof] Candidate labels (text contains 'ms'):")
    for _, root in ipairs({ PlayerGui, CoreGui }) do
        for _, inst in ipairs(safeDescendants(root)) do
            if (inst:IsA("TextLabel") or inst:IsA("TextButton"))
               and string.find(string.lower(inst.Text or ""), "ms", 1, true) then
                print(("  %-50s  Name=%-20s  Text=%q"):format(
                    inst:GetFullName(), inst.Name, inst.Text))
            end
        end
    end
    print("[PingSpoof] End of dump.")
end

do
    local mode = _G.PingSpoofMode or MODE
    if mode == "fixed" then
        print(("[PingSpoof] Active [fixed] — base %d ms (+/- %d jitter). Hooked %d label(s).")
            :format(_G.PingSpoofFixed or FAKE_PING, _G.PingSpoofJitter or JITTER, hits))
    else
        print(("[PingSpoof] Active [add] — real ping + %d ms (+/- %d jitter). Real ping right now: %d ms. Hooked %d label(s).")
            :format(_G.PingSpoofExtra or EXTRA_PING, _G.PingSpoofJitter or JITTER, math.floor(getRealPing() + 0.5), hits))
    end
end
print("[PingSpoof] If nothing changed, run:  _G.PingSpoofDump()  to see candidate labels.")
