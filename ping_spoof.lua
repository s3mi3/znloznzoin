--[[
    Ping Display Spoofer
    --------------------
    Changes the "NetworkPing" text on the in-game performance HUD to any
    value you want. This is purely a client-side visual change — it only
    affects what YOU see on your own screen. Your real network latency
    is unchanged and other players still see your true ping.

    HOW TO USE
        1. Set FAKE_PING below to whatever number you want displayed.
        2. (Optional) tweak the other config values.
        3. Execute the script in your Roblox executor of choice.

    To stop the spoof at runtime:
        _G.PingSpoofEnabled = false
]]

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local FAKE_PING        = 35      -- the number that will be shown
local SUFFIX           = " ms"   -- text appended after the number
local RANDOM_JITTER    = 0       -- +/- random variation each update (0 = static)
local UPDATE_INTERVAL  = 0.1     -- seconds between refreshes
local LABEL_NAME       = "NetworkPing" -- name of the TextLabel to override
------------------------------------------------------------

_G.PingSpoofEnabled = true

local CoreGui    = game:GetService("CoreGui")
local RunService = game:GetService("RunService")

-- Pull the latest config from globals every tick so you can change the
-- value live from the console without re-running the whole script:
_G.FakePing = _G.FakePing or FAKE_PING

local function buildText()
    local value = _G.FakePing or FAKE_PING
    if RANDOM_JITTER > 0 then
        value = value + math.random(-RANDOM_JITTER, RANDOM_JITTER)
    end
    return tostring(value) .. SUFFIX
end

local function findPingLabels()
    local labels = {}
    for _, descendant in ipairs(CoreGui:GetDescendants()) do
        if descendant:IsA("TextLabel") and descendant.Name == LABEL_NAME then
            table.insert(labels, descendant)
        end
    end
    return labels
end

-- Lock a single label so the game cannot overwrite the text we put on it.
local hookedLabels = {}
local function hookLabel(label)
    if hookedLabels[label] then return end
    hookedLabels[label] = true

    -- Whenever the game tries to set .Text, immediately put our value back.
    label:GetPropertyChangedSignal("Text"):Connect(function()
        if not _G.PingSpoofEnabled then return end
        local desired = buildText()
        if label.Text ~= desired then
            label.Text = desired
        end
    end)
end

-- Main loop: refresh value, find new labels (CoreGui can rebuild them).
local accumulator = 0
RunService.RenderStepped:Connect(function(dt)
    if not _G.PingSpoofEnabled then return end
    accumulator = accumulator + dt
    if accumulator < UPDATE_INTERVAL then return end
    accumulator = 0

    for _, label in ipairs(findPingLabels()) do
        hookLabel(label)
        label.Text = buildText()
    end
end)

print(("[PingSpoof] Active — displaying %s. Set _G.FakePing to change, _G.PingSpoofEnabled=false to stop."):format(buildText()))
