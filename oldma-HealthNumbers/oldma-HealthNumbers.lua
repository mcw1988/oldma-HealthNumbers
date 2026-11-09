-- oldma-HealthNumbers.lua
-- 适用于《魔兽世界：无限》(WoW Forever) 1.60.1 / Interface 16001
--
-- 功能：让状态条上的数值常驻显示 —— 角色栏、目标框、小队成员、焦点、宠物的
--       血量与法力（能量）条，显示格式为「当前 / 最大」。
--
-- 开关：
--   ESC → 选项 → 插件 →「血量数值」页里的一个勾选框，点击即时生效。
--   ESC →「插件(AddOns)」列表里的勾选框是总开关（是否加载本插件）。
--
-- 实现依据（官方 UI 源码 forever 分支，Interface/AddOns/Blizzard_TextStatusBar/）：
--   状态条是 TextStatusBarMixin，显示条件为：
--     (cvar=="1" and textLockable) or forceShow  → Show 并写入数值
--     elseif lockShow > 0                        → Show 并写入数值
--   且全部逻辑读 self.TextString。玩家血条（parentKey="HealthBar"）本身没有
--   TextString —— 文字 FontString 挂在父容器 HealthBarsContainer 上，名为
--   HealthBarText；法力条则在自身内部叫 ManaBarText。所以必须先把这些
--   FontString 补到 bar.TextString，否则渲染逻辑整个空转。
--   少数框体（例如目标的目标）连文字载体都没有，这里给它补一个空白 FontString。
--
-- 合规说明：不读取 UnitHealth / UnitHealthMax（值可能是 secret），不做任何
--   自动化、点击、施法、文件或网络操作；只使用 hooksecurefunc 与普通 UI 字段，
--   并通过官方 Settings API 注册设置页。statusText 为客户端自带的「状态文字」
--   界面选项，插件退出时恢复原值。

local ADDON = ...
local VERSION = "2.0.2"
local PREFIX = "|cff33ff99[血量数值]|r "

OldmaHealthNumbersDB = OldmaHealthNumbersDB or {}
-- v2 存档迁移：旧版双开关已废弃，统一为单开关，且默认开启。
-- schemaVersion 保证只迁移一次，之后尊重用户在设置页里的实际选择。
if OldmaHealthNumbersDB.schemaVersion ~= 2 then
    OldmaHealthNumbersDB.enabled = true
    OldmaHealthNumbersDB.schemaVersion = 2
end
OldmaHealthNumbersDB.main = nil
OldmaHealthNumbersDB.group = nil

local unloading = false
local diag = { roots = {}, optionsError = nil, optionsTries = 0, refreshCount = 0, badEvents = {} }

------------------------------------------------------------------------
-- 基础工具
------------------------------------------------------------------------
local function IsForbidden(f)
    if not f or not f.IsForbidden then return false end
    local ok, forbidden = pcall(f.IsForbidden, f)
    return ok and forbidden
end

local function plain(value)
    return not (issecretvalue and issecretvalue(value))
        and type(value) == "number" and value == value
        and value > -math.huge and value < math.huge
end

local function IsFontString(f)
    if not f then return false end
    local ok, kind = pcall(f.GetObjectType, f)
    return ok and kind == "FontString"
end

-- 只按「有没有 TextString / 渲染方法」判断，不用 IsForbidden 过滤：
-- 单位框体可能被标记 forbidden，但普通字段仍可读写。
local function IsTextBar(f)
    if not f then return false end
    local ok, text = pcall(function() return f.TextString end)
    if ok and text ~= nil then return true end
    local ok2, fn = pcall(function() return f.UpdateTextStringWithValues end)
    if ok2 and type(fn) == "function" then return true end
    local ok3, fn2 = pcall(function() return f.UpdateTextString end)
    return ok3 and type(fn2) == "function"
end

local TEXT_KEYS_SELF = { "ManaBarText", "HealthBarText", "TextString", "Text", "barText" }
local TEXT_KEYS_PARENT = { "HealthBarText", "ManaBarText", "TextString", "Text" }

local function FindText(bar)
    if IsFontString(bar.TextString) then return bar.TextString end
    for _, key in ipairs(TEXT_KEYS_SELF) do
        if IsFontString(bar[key]) then return bar[key] end
    end
    local parent = bar.GetParent and bar:GetParent()
    if parent then
        for _, key in ipairs(TEXT_KEYS_PARENT) do
            if IsFontString(parent[key]) then return parent[key] end
        end
    end
    if IsFontString(bar.__HNText) then return bar.__HNText end
    return nil
end

local function EnsureText(bar)
    local t = FindText(bar)
    if t and bar.TextString ~= t then
        bar.TextString = t
    end
    return t
end

------------------------------------------------------------------------
-- CVar 备份（statusText 是客户端自带的「状态文字」界面选项）
------------------------------------------------------------------------
local savedCVars

local function CVarGet(name)
    local get = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not get then return nil end
    local ok, value = pcall(get, name)
    if not ok then return nil end
    return tostring(value)
end

local function SetCVarSafe(name, value)
    if not SetCVar or not value then return end
    local ok = pcall(SetCVar, name, value, ADDON)
    if not ok then pcall(SetCVar, name, value) end
end

local function CaptureDefaults()
    if savedCVars then return end
    savedCVars = { statusText = CVarGet("statusText") or "0" }
end

local function CVarsOn()
    CaptureDefaults()
    if CVarGet("statusText") ~= "1" then SetCVarSafe("statusText", "1") end
end

local function CVarsOff()
    if not savedCVars then return end
    if CVarGet("statusText") ~= savedCVars.statusText then
        SetCVarSafe("statusText", savedCVars.statusText)
    end
end

------------------------------------------------------------------------
-- 框体收集
------------------------------------------------------------------------
local ROOTS = {}
local ROOT_NAMES = {}
local bars = {}
local barIndex = {}

local function addRoot(name, f)
    if not f then return end
    ROOT_NAMES[f] = name
    for _, v in ipairs(ROOTS) do if v == f then return end end
    ROOTS[#ROOTS + 1] = f
end

local function RefreshRoots()
    ROOTS = {}

    addRoot("PlayerFrame", _G.PlayerFrame)
    addRoot("TargetFrame", _G.TargetFrame)
    addRoot("FocusFrame", _G.FocusFrame)
    addRoot("PetFrame", _G.PetFrame)
    addRoot("TargetofTarget", _G.TargetofTargetFrame)
    if _G.TargetFrame then addRoot("TargetFrame.tot", _G.TargetFrame.totFrame) end
    if _G.FocusFrame then addRoot("FocusFrame.tot", _G.FocusFrame.totFrame) end

    local party = _G.PartyFrame
    if party and party.GetPartyMemberFrame then
        for i = 1, 4 do
            local ok, member = pcall(party.GetPartyMemberFrame, party, i)
            if ok then addRoot("Party" .. i, member) end
        end
    end
    for i = 1, 4 do addRoot("PartyMemberFrame" .. i, _G["PartyMemberFrame" .. i]) end
end

local LEGACY = {
    "PlayerFrameHealthBar", "PlayerFrameManaBar",
    "TargetFrameHealthBar", "TargetFrameManaBar",
    "FocusFrameHealthBar", "FocusFrameManaBar",
    "TargetofTargetHealthBar", "TargetofTargetManaBar",
    "PetFrameHealthBar", "PetFrameManaBar",
}
for i = 1, 4 do
    LEGACY[#LEGACY + 1] = "PartyMemberFrame" .. i .. "HealthBar"
    LEGACY[#LEGACY + 1] = "PartyMemberFrame" .. i .. "ManaBar"
end

-- 写死路径兜底：GetChildren 受限时也能直接拿到 12.x / Forever 的血条
local DIRECT_PATHS = {
    { "PlayerFrame", "PlayerFrameContent", "PlayerFrameContentMain", "HealthBarsContainer", "HealthBar" },
    { "PlayerFrame", "PlayerFrameContent", "PlayerFrameContentMain", "ManaBarArea", "ManaBar" },
    { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "HealthBar" },
    { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "ManaBar" },
    { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "HealthBarsContainer", "HealthBar" },
    { "TargetFrame", "TargetFrameContent", "TargetFrameContentMain", "ManaBarArea", "ManaBar" },
    { "FocusFrame", "FocusFrameContent", "FocusFrameContentMain", "HealthBar" },
    { "FocusFrame", "FocusFrameContent", "FocusFrameContentMain", "ManaBar" },
    { "FocusFrame", "FocusFrameContent", "FocusFrameContentMain", "HealthBarsContainer", "HealthBar" },
    { "FocusFrame", "FocusFrameContent", "FocusFrameContentMain", "ManaBarArea", "ManaBar" },
    { "PetFrame", "PetFrameContent", "PetFrameContentMain", "HealthBar" },
    { "PetFrame", "PetFrameContent", "PetFrameContentMain", "ManaBar" },
    { "PetFrame", "PetFrameContent", "PetFrameContentMain", "HealthBarsContainer", "HealthBar" },
    { "PetFrame", "PetFrameContent", "PetFrameContentMain", "ManaBarArea", "ManaBar" },
}

local function Walk(frame, depth, out, seen)
    if depth > 8 or not frame then return end
    local res = { pcall(frame.GetChildren, frame) }
    if not res[1] then return end
    for i = 2, #res do
        local child = res[i]
        if child and not seen[child] then
            seen[child] = true
            if IsTextBar(child) then out[#out + 1] = child end
            Walk(child, depth + 1, out, seen)
        end
    end
end

local function Register(bar, seen)
    if not IsTextBar(bar) or seen[bar] or barIndex[bar] then return end
    seen[bar] = true
    bars[#bars + 1] = bar
    barIndex[bar] = true
end

local function Collect()
    local found = {}
    local seen = {}

    for _, root in ipairs(ROOTS) do
        local before = #found
        Walk(root, 0, found, seen)
        local okKids, kidCount = pcall(function() return select("#", root:GetChildren()) end)
        diag.roots[#diag.roots + 1] = {
            name = ROOT_NAMES[root] or "?",
            forbidden = IsForbidden(root),
            children = okKids and kidCount or -1,
            hits = #found - before,
        }
    end

    for _, name in ipairs(LEGACY) do
        local bar = _G[name]
        if IsTextBar(bar) and not seen[bar] then
            seen[bar] = true
            found[#found + 1] = bar
        end
    end

    for _, bar in ipairs(found) do Register(bar, seen) end

    for _, path in ipairs(DIRECT_PATHS) do
        local node = _G[path[1]]
        for i = 2, #path do
            if not node then break end
            local ok, child = pcall(function() return node[path[i]] end)
            node = ok and child or nil
        end
        if IsTextBar(node) then Register(node, seen) end
    end
end

------------------------------------------------------------------------
-- 应用显示状态
------------------------------------------------------------------------
local function Enabled()
    return OldmaHealthNumbersDB.enabled == true
end

local function SaveOrigin(bar)
    if bar.__HNOrig ~= nil then return end
    bar.__HNOrig = { showNumeric = bar.showNumeric, forceShow = bar.forceShow }
end

local function RestoreOrigin(bar)
    local orig = bar.__HNOrig
    if orig then
        bar.showNumeric = orig.showNumeric
        bar.forceShow = orig.forceShow
    else
        bar.showNumeric = nil
        bar.forceShow = false
    end
    bar.lockShow = 0
end

local function SafeRefresh(bar)
    if type(bar.UpdateTextString) ~= "function" then return end
    local value = bar:GetValue()
    local vmin, vmax = bar:GetMinMaxValues()
    if plain(value) and plain(vmin) and plain(vmax) then
        pcall(bar.UpdateTextString, bar)
    end
end

local function ShowBar(bar, text)
    EnsureText(bar)
    bar.showNumeric = true   -- 强制「当前 / 最大」，覆盖 statusTextDisplay
    bar.forceShow = true     -- 最高优先级，无视 cvar / lockShow
    bar.lockShow = 1
    local t = IsFontString(text) and text or FindText(bar)
    if t then t:Show() end
end

local function ApplyTo(bar, on)
    if not bar then return end
    SaveOrigin(bar)
    if not on then
        RestoreOrigin(bar)
        SafeRefresh(bar)
        return
    end
    ShowBar(bar)
    SafeRefresh(bar)
end

local function SetupBar(bar)
    if bar.__HNHooked or not bar then return end
    bar.__HNHooked = true
    if not hooksecurefunc then return end

    if type(bar.UpdateTextStringWithValues) == "function" then
        pcall(hooksecurefunc, bar, "UpdateTextStringWithValues", function(self, text)
            if unloading or not Enabled() then return end
            if IsFontString(text) then
                self.__HNText = text
                self.TextString = text
            end
            self.showNumeric = true
            self.forceShow = true
            self.lockShow = 1
            local t = FindText(self)
            if t then t:Show() end
        end)
    end

    -- 鼠标离开时暴雪会 HideStatusBarText 并把 lockShow 减 1，这里再扶起来
    if type(bar.HideStatusBarText) == "function" then
        pcall(hooksecurefunc, bar, "HideStatusBarText", function(self)
            if unloading or not Enabled() then return end
            self.forceShow = true
            self.lockShow = 1
            local t = FindText(self)
            if t then t:Show() end
        end)
    end
end

local function Apply()
    if unloading then return end
    local on = Enabled()
    if on then CVarsOn() else CVarsOff() end
    for _, bar in ipairs(bars) do
        ApplyTo(bar, on)
    end
end

local function Discover()
    RefreshRoots()
    diag.roots = {}
    Collect()
    for _, bar in ipairs(bars) do SetupBar(bar) end
end

------------------------------------------------------------------------
-- ESC → 选项 → 插件 →「血量数值」页（单开关）
------------------------------------------------------------------------
local optionsReady = false
local mainCheckbox

local function NewCheckButton(parent)
    local ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, "UICheckButtonTemplate")
    if ok and cb then return cb end
    ok, cb = pcall(CreateFrame, "CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    if ok and cb then return cb end
    return nil
end

local function MakeCheckbox(panel, y, text)
    local cb = NewCheckButton(panel)
    if not cb then
        -- 兜底：普通 Button，点击切换状态文字
        cb = CreateFrame("Button", nil, panel)
        cb:SetSize(200, 24)
        cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "LEFT", 0, 0)
        local function sync()
            local state = Enabled() and "|cff33ff99[已开启]|r " or "|cffff5555[已关闭]|r "
            label:SetText(state .. text .. "   （点击切换）")
        end
        sync()
        cb:SetScript("OnClick", function()
            OldmaHealthNumbersDB.enabled = not Enabled()
            sync()
            Apply()
        end)
        cb.__HNSync = sync
        return cb
    end

    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    cb:SetChecked(Enabled())

    local label
    if cb.Text then
        label = cb.Text
        label:ClearAllPoints()
        label:SetPoint("LEFT", cb, "RIGHT", 6, 0)
        label:SetFontObject(GameFontHighlight)
    else
        label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("LEFT", cb, "RIGHT", 6, 0)
    end
    label:SetText(text)

    cb:SetScript("OnClick", function(self)
        -- GetChecked() 在老控件上可能返回 1 / nil，不能直接和 true 比较
        OldmaHealthNumbersDB.enabled = self:GetChecked() and true or false
        Apply()
    end)
    return cb
end

local function RegisterOptions()
    if optionsReady then return end
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory) then
        diag.optionsError = "Settings API 不存在"
        return
    end

    local panel = CreateFrame("Frame", "OldmaHealthNumbersOptionsPanel", UIParent)
    panel:SetSize(520, 220)

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("|cff33ff99血量数值|r " .. VERSION)

    mainCheckbox = MakeCheckbox(panel, -56, "显示自身 / 目标 / 小队 状态数值")

    panel:SetScript("OnShow", function()
        if mainCheckbox then
            if mainCheckbox.SetChecked then
                mainCheckbox:SetChecked(Enabled())
            elseif mainCheckbox.__HNSync then
                mainCheckbox.__HNSync()
            end
        end
    end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    note:SetWidth(488)
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -100)
    note:SetJustifyH("LEFT")
    note:SetJustifyV("TOP")
    note:SetWordWrap(true)
    note:SetText(
        "范围：角色栏、目标框、小队成员、焦点、宠物框的血量与法力（能量）条，显示「当前 / 最大」。\n" ..
        "点击即时生效，无需 /reload。关闭后恢复客户端默认 —— 按 C 或把鼠标悬停在血条上时仍会临时显示数值，这是游戏原生行为。\n" ..
        "ESC →「插件」列表里的勾选框是总开关：取消勾选并 /reload 后本插件完全不加载。\n" ..
        "排查用：/hn 可打印识别到的状态条清单。")

    local ok, category = pcall(Settings.RegisterCanvasLayoutCategory, panel, "血量数值")
    if ok and category then
        pcall(Settings.RegisterAddOnCategory, category)
        optionsReady = true
        diag.optionsError = nil
        return
    end

    if InterfaceOptions_AddCategory then
        panel.name = "血量数值"
        local ok2 = pcall(InterfaceOptions_AddCategory, panel)
        if ok2 then
            optionsReady = true
            diag.optionsError = nil
            return
        end
    end

    diag.optionsError = "RegisterCanvasLayoutCategory 失败: " .. tostring(category)
end

local function TryRegisterOptions()
    if optionsReady then return end
    diag.optionsTries = diag.optionsTries + 1
    local ok, err = pcall(RegisterOptions)
    if not ok then diag.optionsError = tostring(err) end
    if not optionsReady and diag.optionsTries < 15 and C_Timer and C_Timer.After then
        C_Timer.After(1, TryRegisterOptions)
    end
end

------------------------------------------------------------------------
-- 诊断：/hn
------------------------------------------------------------------------
local function BarName(bar)
    local ok, name = pcall(bar.GetName, bar)
    if ok and name then return name end
    return "<anonymous>"
end

local function Diagnose()
    print(PREFIX .. "诊断 v" .. VERSION)
    print(("  Settings=%s  设置页已注册=%s  尝试=%d  Refresh次数=%d")
        :format(tostring(Settings ~= nil), tostring(optionsReady),
                diag.optionsTries, diag.refreshCount))
    if diag.optionsError then
        print("  |cffff5555设置页错误: " .. diag.optionsError .. "|r")
    end
    if #diag.badEvents > 0 then
        print("  注册失败事件: " .. table.concat(diag.badEvents, ","))
    end

    for _, r in ipairs(diag.roots) do
        print(("  %s: 禁止=%s 子节点=%s 命中=%s")
            :format(r.name, r.forbidden and "是" or "否",
                    tostring(r.children), tostring(r.hits)))
    end

    print(("  合计状态条 %d 根，当前开关=%s"):format(#bars, Enabled() and "开" or "关"))
    for i, bar in ipairs(bars) do
        if i > 20 then print("  ...（其余省略）"); break end
        local t = FindText(bar)
        print(("  %d. %s  text=%s visible=%s forceShow=%s lockShow=%s cvar=%s lockable=%s")
            :format(i, BarName(bar), tostring(t ~= nil),
                    tostring(t ~= nil and t:IsShown() or false),
                    tostring(bar.forceShow), tostring(bar.lockShow),
                    tostring(bar.cvar), tostring(bar.textLockable)))
    end
end

SLASH_OLDMAHEALTHNUMBERS1 = "/ohn"
SlashCmdList["OLDMAHEALTHNUMBERS"] = Diagnose

------------------------------------------------------------------------
-- 驱动
------------------------------------------------------------------------
local function Refresh()
    diag.refreshCount = diag.refreshCount + 1
    TryRegisterOptions()
    Discover()
    Apply()
end

-- 12.x 对无效事件名会直接抛错（例如 Forever 没有 UNIT_FOCUS）。
-- 一旦某个注册失败就会中断整个文件，导致后面的 SetScript 执行不到，
-- 插件从此静默。所以先挂 OnEvent，再逐个 pcall 注册。
local function SafeRegister(frame, event)
    local ok = pcall(frame.RegisterEvent, frame, event)
    if not ok then diag.badEvents[#diag.badEvents + 1] = event end
end

local function OnDriverEvent(_, event)
    if event == "PLAYER_LOGOUT" then
        unloading = true
        CVarsOff()
        return
    end
    local ok, err = pcall(Refresh)
    if not ok then
        print("|cffff5555[血量数值] 错误: " .. tostring(err) .. "|r")
    end
end

local driver = CreateFrame("Frame")
driver:SetScript("OnEvent", OnDriverEvent)
for _, event in ipairs({
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
    "PLAYER_TARGET_CHANGED", "GROUP_ROSTER_UPDATE",
    "UNIT_PET", "PLAYER_LOGOUT",
}) do
    SafeRegister(driver, event)
end

-- 不依赖任何事件，加载完立刻跑一次
pcall(Refresh)
