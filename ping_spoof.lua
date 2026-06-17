--[[
    Ping Display Spoofer  (v2 — robust)
    -----------------------------------
    Changes whatever on-screen label is showing your ping ("NetworkPing",
    "35 ms", etc.) to any value you want. Works for both the built-in
    Roblox Performance Stats overlay AND custom in-game HUDs that live
    in PlayerGui.

    This is purely a client-side visual change. Your real latency and
    what other players see are unaffected.

    USAGE
        1. Edit FAKE_PING below (or set _G.FakePing at runtime).
        2. Run the script in your executor.
        3. Watch the output — it prints which labels it hooked.

    LIVE CONTROL
        _G.FakePing = 12              -- change shown value
        _G.PingSpoofEnabled = false   -- stop the spoof
        _G.PingSpoofDebug = true      -- verbose logging
]]

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local FAKE_PING        = 35       -- the number that will be shown
local SUFFIX           = " ms"    -- text appended after the number
local RANDOM_JITTER    = 0        -- +/- random variation each update
local UPDATE_INTERVAL  = 0.1      -- seconds between refreshes
local RESCAN_INTERVAL  = 1.0      -- how often we re-scan for new labels

-- Name candidates (case-insensitive contains match on Name):
local NAME_KEYWORDS    = { "ping", "networkping", "latency", "ms" }

-- Text pattern: anything that looks like "<number> ms" (with optional
-- surrounding whitespace / leading text). This is what catches custom
-- HUDs like the one in the screenshot.
local TEXT_PATTERN     = "^%s*[%w%p]*%s*%d+%s*ms%s*$"
------------------------------------------------------------

_G.PingSpoofEnabled = true
_G.FakePing         = _G.FakePing or FAKE_PING
_G.PingSpoofDebug   = _G.PingSpoofDebug == nil and true or _G.PingSpoofDebug

local Players      = game:GetService("Players")
local CoreGui      = game:GetService("CoreGui")
local RunService   = game:GetService("RunService")
local LocalPlayer  = Players.LocalPlayer
local PlayerGui    = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui", 5)

local function dbg(...)
    if _G.PingSpoofDebug then
        print("[PingSpoof]", ...)
    end
end

local function buildText()
    local value = _G.FakePing or FAKE_PING
    if RANDOM_JITTER > 0 then
        value = value + math.random(-RANDOM_JITTER, RANDOM_JITTER)
    end
    return tostring(value) .. SUFFIX
end

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

-- Refresh + periodic rescan loop.
local refreshAccum, rescanAccum = 0, 0
RunService.RenderStepped:Connect(function(dt)
    if not _G.PingSpoofEnabled then return end

    refreshAccum = refreshAccum + dt
    if refreshAccum >= UPDATE_INTERVAL then
        refreshAccum = 0
        local desired = buildText()
        for label in pairs(hooked) do
            if label and label.Parent then
                if label.Text ~= desired then
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

print(("[PingSpoof] Active — target text: %s. Hooked %d label(s)."):format(buildText(), hits))
print("[PingSpoof] If nothing changed, run:  _G.PingSpoofDump()  to see candidate labels.")
