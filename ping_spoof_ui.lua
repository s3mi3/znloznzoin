--[[
    Ping Display Spoofer  —  with UI
    --------------------------------
    Same spoofing engine as ping_spoof.lua, but with a draggable in-game
    control panel so you can tweak everything live without touching the
    console.

    Toggle the panel with the keybind (default RightShift) or by clicking
    the small floating button.

    Purely cosmetic — only changes what YOU see on your screen. Real
    network latency is unchanged.
]]

------------------------------------------------------------
-- CONFIG (initial values; everything is editable from the UI)
------------------------------------------------------------
local MODE             = "add"      -- "add" or "fixed"
local EXTRA_PING       = 50         -- ms added to your REAL ping (mode "add")
local FAKE_PING        = 35         -- used in mode "fixed"
local JITTER           = 4          -- +/- ms wiggle per refresh
local DRIFT_SPEED      = 0.6        -- how fast the wiggle moves
local SUFFIX           = " ms"
local UPDATE_INTERVAL  = 0.25
local RESCAN_INTERVAL  = 1.0
local TOGGLE_KEY       = Enum.KeyCode.RightShift

local NAME_KEYWORDS    = { "ping", "networkping", "latency", "ms" }
local TEXT_PATTERN     = "^%s*[%w%p]*%s*%d+%s*ms%s*$"
------------------------------------------------------------

------------------------------------------------------------
-- SERVICES & STATE
------------------------------------------------------------
local Players      = game:GetService("Players")
local CoreGui      = game:GetService("CoreGui")
local RunService   = game:GetService("RunService")
local Stats        = game:GetService("Stats")
local UserInput    = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui   = LocalPlayer and LocalPlayer:WaitForChild("PlayerGui", 5)

_G.PingSpoofEnabled = true
_G.PingSpoofMode    = _G.PingSpoofMode   or MODE
_G.PingSpoofExtra   = _G.PingSpoofExtra  or EXTRA_PING
_G.PingSpoofFixed   = _G.PingSpoofFixed  or FAKE_PING
_G.PingSpoofJitter  = _G.PingSpoofJitter or JITTER
_G.PingSpoofDebug   = _G.PingSpoofDebug == nil and true or _G.PingSpoofDebug

------------------------------------------------------------
-- SPOOFING ENGINE
------------------------------------------------------------
local function getRealPing()
    local ok, value = pcall(function()
        return Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
    end)
    if ok and typeof(value) == "number" then return value end
    return 0
end

local jitterSeed = math.random() * 1000
local function smoothJitter(amount)
    if amount <= 0 then return 0 end
    local t = (tick() + jitterSeed) * DRIFT_SPEED
    local wave  = math.sin(t) * 0.6 + math.sin(t * 2.3 + 1.7) * 0.4
    local nudge = (math.random() - 0.5) * 0.4
    return math.floor((wave + nudge) * amount + 0.5)
end

local function computeDisplayedPing()
    local mode   = _G.PingSpoofMode or MODE
    local jitter = smoothJitter(_G.PingSpoofJitter or JITTER)
    local base
    if mode == "fixed" then
        base = _G.PingSpoofFixed or FAKE_PING
    else
        base = getRealPing() + (_G.PingSpoofExtra or EXTRA_PING)
    end
    return math.max(1, math.floor(base + jitter + 0.5))
end

local function buildText() return tostring(computeDisplayedPing()) .. SUFFIX end

local function isPingLabel(inst)
    if not (inst:IsA("TextLabel") or inst:IsA("TextButton")) then return false end
    local name = string.lower(inst.Name or "")
    for _, kw in ipairs(NAME_KEYWORDS) do
        if string.find(name, kw, 1, true) then return true end
    end
    local text = string.lower(inst.Text or "")
    if string.match(text, TEXT_PATTERN) then return true end
    return false
end

local function safeDescendants(root)
    local ok, list = pcall(function() return root:GetDescendants() end)
    if ok and type(list) == "table" then return list end
    return {}
end

local hooked = {}
local function hookLabel(label)
    if hooked[label] then return end
    hooked[label] = true
    local conn = label:GetPropertyChangedSignal("Text"):Connect(function()
        if not _G.PingSpoofEnabled then return end
        local desired = buildText()
        if label.Text ~= desired then label.Text = desired end
    end)
    label.AncestryChanged:Connect(function(_, parent)
        if not parent then
            hooked[label] = nil
            if conn then conn:Disconnect() end
        end
    end)
    if _G.PingSpoofEnabled then label.Text = buildText() end
end

local function scanRoot(root)
    if not root then return 0 end
    local n = 0
    for _, inst in ipairs(safeDescendants(root)) do
        local ok, ping = pcall(isPingLabel, inst)
        if ok and ping then hookLabel(inst); n = n + 1 end
    end
    return n
end

local function fullScan()
    return scanRoot(PlayerGui) + scanRoot(CoreGui)
end

local function restoreAllLabels()
    -- When disabling, let the game write to .Text freely again.
    -- (We can't undo hooks once made, but skipping in the listener achieves
    -- the same result.)
    for label in pairs(hooked) do
        if label and label.Parent then
            -- Don't write anything; the game will refresh it on next tick.
        end
    end
end

fullScan()

local function watchDescendants(root)
    if not root then return end
    root.DescendantAdded:Connect(function(inst)
        task.wait()
        local ok, ping = pcall(isPingLabel, inst)
        if ok and ping then hookLabel(inst) end
    end)
end
watchDescendants(PlayerGui)
watchDescendants(CoreGui)

local refreshAccum, rescanAccum = 0, 0
RunService.RenderStepped:Connect(function(dt)
    refreshAccum = refreshAccum + dt
    if refreshAccum >= UPDATE_INTERVAL then
        refreshAccum = 0
        if _G.PingSpoofEnabled then
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

------------------------------------------------------------
-- UI
------------------------------------------------------------
-- Pick the safest parent we can manage: CoreGui (preferred for exploits
-- so games can't delete it), otherwise PlayerGui.
local function getGuiParent()
    if syn and syn.protect_gui then
        local sg = Instance.new("ScreenGui")
        syn.protect_gui(sg)
        sg.Parent = CoreGui
        return sg
    end
    if gethui then
        local sg = Instance.new("ScreenGui")
        sg.Parent = gethui()
        return sg
    end
    local ok, sg = pcall(function()
        local g = Instance.new("ScreenGui")
        g.Parent = CoreGui
        return g
    end)
    if ok and sg then return sg end
    local g = Instance.new("ScreenGui")
    g.Parent = PlayerGui
    return g
end

local screenGui = getGuiParent()
screenGui.Name = "PingSpoofUI_" .. tostring(math.random(10000, 99999))
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screenGui.IgnoreGuiInset = true

-- Theme
local THEME = {
    bg         = Color3.fromRGB(20, 22, 28),
    panel      = Color3.fromRGB(28, 30, 38),
    panelAlt   = Color3.fromRGB(36, 39, 48),
    accent     = Color3.fromRGB(98, 178, 255),
    accentDim  = Color3.fromRGB(60, 110, 170),
    danger     = Color3.fromRGB(220, 80, 80),
    text       = Color3.fromRGB(235, 238, 245),
    textDim    = Color3.fromRGB(150, 160, 175),
    success    = Color3.fromRGB(90, 200, 120),
}

local function makeCorner(parent, r)
    local c = Instance.new("UICorner", parent)
    c.CornerRadius = UDim.new(0, r or 8)
end

local function makeStroke(parent, color, thickness)
    local s = Instance.new("UIStroke", parent)
    s.Color = color or THEME.panelAlt
    s.Thickness = thickness or 1
    s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    return s
end

------------------------------------------------------------
-- Main panel
------------------------------------------------------------
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0, 280, 0, 360)
panel.Position = UDim2.new(0, 24, 0.5, -180)
panel.BackgroundColor3 = THEME.bg
panel.BorderSizePixel = 0
panel.Active = true
panel.Parent = screenGui
makeCorner(panel, 10)
makeStroke(panel, THEME.panelAlt, 1)

-- Drag
do
    local dragging, dragStart, startPos
    local function update(input)
        local delta = input.Position - dragStart
        panel.Position = UDim2.new(
            startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
    panel.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPos = panel.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)
    UserInput.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            update(input)
        end
    end)
end

------------------------------------------------------------
-- Title bar
------------------------------------------------------------
local title = Instance.new("Frame", panel)
title.Name = "Title"
title.Size = UDim2.new(1, 0, 0, 36)
title.BackgroundColor3 = THEME.panel
title.BorderSizePixel = 0
makeCorner(title, 10)

local titleFix = Instance.new("Frame", title) -- hides bottom rounded corners
titleFix.Size = UDim2.new(1, 0, 0, 10)
titleFix.Position = UDim2.new(0, 0, 1, -10)
titleFix.BackgroundColor3 = THEME.panel
titleFix.BorderSizePixel = 0

local titleText = Instance.new("TextLabel", title)
titleText.BackgroundTransparency = 1
titleText.Position = UDim2.new(0, 14, 0, 0)
titleText.Size = UDim2.new(1, -80, 1, 0)
titleText.Font = Enum.Font.GothamBold
titleText.TextSize = 14
titleText.TextXAlignment = Enum.TextXAlignment.Left
titleText.TextColor3 = THEME.text
titleText.Text = "Ping Spoofer"

local closeBtn = Instance.new("TextButton", title)
closeBtn.Size = UDim2.new(0, 28, 0, 22)
closeBtn.Position = UDim2.new(1, -36, 0.5, -11)
closeBtn.BackgroundColor3 = THEME.panelAlt
closeBtn.BorderSizePixel = 0
closeBtn.Text = "×"
closeBtn.TextColor3 = THEME.text
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextSize = 16
makeCorner(closeBtn, 6)

------------------------------------------------------------
-- Content layout helper
------------------------------------------------------------
local content = Instance.new("Frame", panel)
content.BackgroundTransparency = 1
content.Position = UDim2.new(0, 12, 0, 44)
content.Size = UDim2.new(1, -24, 1, -56)

local layout = Instance.new("UIListLayout", content)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 8)

local order = 0
local function nextOrder() order = order + 1; return order end

-- Generic section row
local function makeSection(height)
    local f = Instance.new("Frame", content)
    f.LayoutOrder = nextOrder()
    f.Size = UDim2.new(1, 0, 0, height)
    f.BackgroundColor3 = THEME.panel
    f.BorderSizePixel = 0
    makeCorner(f, 8)
    return f
end

local function makeLabel(parent, text, x, color, size, bold)
    local l = Instance.new("TextLabel", parent)
    l.BackgroundTransparency = 1
    l.Position = UDim2.new(0, x or 10, 0, 0)
    l.Size = UDim2.new(1, -(x or 10), 1, 0)
    l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham
    l.TextSize = size or 13
    l.TextColor3 = color or THEME.textDim
    l.TextXAlignment = Enum.TextXAlignment.Left
    l.Text = text
    return l
end

------------------------------------------------------------
-- Status section (real ping + displayed ping)
------------------------------------------------------------
local status = makeSection(58)
local statusTitle = makeLabel(status, "STATUS", 12, THEME.textDim, 11, true)
statusTitle.Size = UDim2.new(1, -24, 0, 18)
statusTitle.Position = UDim2.new(0, 12, 0, 6)

local realLabel = Instance.new("TextLabel", status)
realLabel.BackgroundTransparency = 1
realLabel.Position = UDim2.new(0, 12, 0, 26)
realLabel.Size = UDim2.new(0.5, -12, 0, 24)
realLabel.Font = Enum.Font.Gotham
realLabel.TextSize = 13
realLabel.TextColor3 = THEME.text
realLabel.TextXAlignment = Enum.TextXAlignment.Left
realLabel.Text = "Real: -- ms"

local fakeLabel = Instance.new("TextLabel", status)
fakeLabel.BackgroundTransparency = 1
fakeLabel.Position = UDim2.new(0.5, 0, 0, 26)
fakeLabel.Size = UDim2.new(0.5, -12, 0, 24)
fakeLabel.Font = Enum.Font.GothamBold
fakeLabel.TextSize = 13
fakeLabel.TextColor3 = THEME.accent
fakeLabel.TextXAlignment = Enum.TextXAlignment.Left
fakeLabel.Text = "Shown: -- ms"

------------------------------------------------------------
-- Mode section (Add / Fixed)
------------------------------------------------------------
local modeSec = makeSection(58)
local modeTitle = makeLabel(modeSec, "MODE", 12, THEME.textDim, 11, true)
modeTitle.Size = UDim2.new(1, -24, 0, 18)
modeTitle.Position = UDim2.new(0, 12, 0, 6)

local function makeModeButton(text, x)
    local b = Instance.new("TextButton", modeSec)
    b.Size = UDim2.new(0.5, -16, 0, 26)
    b.Position = UDim2.new(x, x == 0 and 12 or 4, 0, 26)
    b.BackgroundColor3 = THEME.panelAlt
    b.BorderSizePixel = 0
    b.Font = Enum.Font.GothamBold
    b.TextSize = 12
    b.TextColor3 = THEME.text
    b.Text = text
    b.AutoButtonColor = false
    makeCorner(b, 6)
    return b
end

local addBtn   = makeModeButton("ADD (real + extra)", 0)
local fixedBtn = makeModeButton("FIXED", 0.5)

local function refreshModeButtons()
    local mode = _G.PingSpoofMode or MODE
    addBtn.BackgroundColor3   = mode == "add"   and THEME.accent or THEME.panelAlt
    fixedBtn.BackgroundColor3 = mode == "fixed" and THEME.accent or THEME.panelAlt
    addBtn.TextColor3   = mode == "add"   and Color3.new(0, 0, 0) or THEME.text
    fixedBtn.TextColor3 = mode == "fixed" and Color3.new(0, 0, 0) or THEME.text
end
addBtn.MouseButton1Click:Connect(function()  _G.PingSpoofMode = "add";   refreshModeButtons() end)
fixedBtn.MouseButton1Click:Connect(function() _G.PingSpoofMode = "fixed"; refreshModeButtons() end)

------------------------------------------------------------
-- Number input row
------------------------------------------------------------
local function makeNumberRow(labelText, getter, setter, hint)
    local row = makeSection(42)

    local lbl = Instance.new("TextLabel", row)
    lbl.BackgroundTransparency = 1
    lbl.Position = UDim2.new(0, 12, 0, 0)
    lbl.Size = UDim2.new(0.55, -12, 1, 0)
    lbl.Font = Enum.Font.Gotham
    lbl.TextSize = 13
    lbl.TextColor3 = THEME.text
    lbl.TextXAlignment = Enum.TextXAlignment.Left
    lbl.Text = labelText

    if hint then
        local h = Instance.new("TextLabel", row)
        h.BackgroundTransparency = 1
        h.Position = UDim2.new(0, 12, 0, 22)
        h.Size = UDim2.new(0.55, -12, 0, 14)
        h.Font = Enum.Font.Gotham
        h.TextSize = 10
        h.TextColor3 = THEME.textDim
        h.TextXAlignment = Enum.TextXAlignment.Left
        h.Text = hint
        lbl.Size = UDim2.new(0.55, -12, 0, 22)
        lbl.Position = UDim2.new(0, 12, 0, 4)
    end

    local box = Instance.new("TextBox", row)
    box.Position = UDim2.new(1, -86, 0.5, -13)
    box.Size = UDim2.new(0, 74, 0, 26)
    box.BackgroundColor3 = THEME.panelAlt
    box.BorderSizePixel = 0
    box.Font = Enum.Font.GothamBold
    box.TextSize = 13
    box.TextColor3 = THEME.text
    box.PlaceholderColor3 = THEME.textDim
    box.ClearTextOnFocus = false
    box.Text = tostring(getter())
    makeCorner(box, 6)

    box.FocusLost:Connect(function()
        local n = tonumber(box.Text)
        if n then
            setter(math.max(0, math.floor(n)))
        end
        box.Text = tostring(getter())
    end)

    return box
end

local extraBox  = makeNumberRow("Extra ping",
    function() return _G.PingSpoofExtra end,
    function(v) _G.PingSpoofExtra = v end,
    "ms added to real ping  (ADD mode)")

local fixedBox  = makeNumberRow("Fixed ping",
    function() return _G.PingSpoofFixed end,
    function(v) _G.PingSpoofFixed = v end,
    "value used in FIXED mode")

local jitterBox = makeNumberRow("Jitter",
    function() return _G.PingSpoofJitter end,
    function(v) _G.PingSpoofJitter = v end,
    "+/- ms wiggle for realism")

------------------------------------------------------------
-- Enable toggle (big button)
------------------------------------------------------------
local toggleSec = makeSection(40)
local toggleBtn = Instance.new("TextButton", toggleSec)
toggleBtn.Size = UDim2.new(1, -16, 1, -8)
toggleBtn.Position = UDim2.new(0, 8, 0, 4)
toggleBtn.BackgroundColor3 = THEME.success
toggleBtn.BorderSizePixel = 0
toggleBtn.Font = Enum.Font.GothamBold
toggleBtn.TextSize = 13
toggleBtn.TextColor3 = Color3.new(0, 0, 0)
toggleBtn.Text = "SPOOF: ENABLED"
toggleBtn.AutoButtonColor = false
makeCorner(toggleBtn, 6)

local function refreshToggle()
    if _G.PingSpoofEnabled then
        toggleBtn.Text = "SPOOF: ENABLED"
        toggleBtn.BackgroundColor3 = THEME.success
        toggleBtn.TextColor3 = Color3.new(0, 0, 0)
    else
        toggleBtn.Text = "SPOOF: DISABLED"
        toggleBtn.BackgroundColor3 = THEME.danger
        toggleBtn.TextColor3 = THEME.text
    end
end
toggleBtn.MouseButton1Click:Connect(function()
    _G.PingSpoofEnabled = not _G.PingSpoofEnabled
    refreshToggle()
end)

------------------------------------------------------------
-- Footer hint
------------------------------------------------------------
local footer = Instance.new("TextLabel", content)
footer.LayoutOrder = nextOrder()
footer.BackgroundTransparency = 1
footer.Size = UDim2.new(1, 0, 0, 14)
footer.Font = Enum.Font.Gotham
footer.TextSize = 10
footer.TextColor3 = THEME.textDim
footer.Text = "Press RightShift to hide / show"

------------------------------------------------------------
-- Resize panel height to fit content
------------------------------------------------------------
panel.Size = UDim2.new(0, 280, 0, 44 + layout.AbsoluteContentSize.Y + 16)
layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    panel.Size = UDim2.new(0, 280, 0, 44 + layout.AbsoluteContentSize.Y + 16)
end)

------------------------------------------------------------
-- Show/hide
------------------------------------------------------------
local visible = true
local function setVisible(v)
    visible = v
    panel.Visible = v
end
closeBtn.MouseButton1Click:Connect(function() setVisible(false) end)

UserInput.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == TOGGLE_KEY then
        setVisible(not visible)
    end
end)

------------------------------------------------------------
-- Live status updater
------------------------------------------------------------
refreshModeButtons()
refreshToggle()

task.spawn(function()
    while screenGui.Parent do
        local real = math.floor(getRealPing() + 0.5)
        realLabel.Text = ("Real: %d ms"):format(real)
        if _G.PingSpoofEnabled then
            fakeLabel.Text = ("Shown: %d ms"):format(computeDisplayedPing())
            fakeLabel.TextColor3 = THEME.accent
        else
            fakeLabel.Text = ("Shown: %d ms (off)"):format(real)
            fakeLabel.TextColor3 = THEME.textDim
        end
        task.wait(0.2)
    end
end)

print("[PingSpoof] UI loaded. Press RightShift to toggle the panel.")
