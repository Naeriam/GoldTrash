local ADDON_NAME = ...
local f = CreateFrame("Frame")

-------------------------------------------------------
-- Defaults (stored in GoldTrashDB)
-------------------------------------------------------
local DEFAULTS = {
    minGold             = 10,    -- Minimum vendor value (in gold) for poor items
    highlightTrash      = true,  -- Gold background on valuable poor items
    highlightProfession = true,  -- Green background on profession items
    announce            = true,  -- Print highlighted items in chat
    autoLoot            = false, -- Auto-loot highlighted items
}

local db

-------------------------------------------------------
-- Stable item class IDs
-------------------------------------------------------
local ITEM_CLASS_TRADEGOODS = 7
local ITEM_CLASS_RECIPE     = 9
local ITEM_QUALITY_POOR     = 0
local COPPER_PER_GOLD       = 10000

-------------------------------------------------------
-- Colors
-------------------------------------------------------
local COLORS = {
    trash      = { r = 1.00, g = 0.78, b = 0.10, hex = "ffffc81a" },
    profession = { r = 0.20, g = 0.90, b = 0.35, hex = "ff33e659" },
}

-------------------------------------------------------
-- Localization (English default, Spanish if available)
-------------------------------------------------------
local L = {
    TITLE          = "GoldTrash",
    MIN_GOLD       = "Minimum vendor value for poor items (gold):",
    HL_TRASH       = "Gold background on poor items above the minimum",
    HL_PROFESSION  = "Green background on profession items",
    ANNOUNCE       = "Announce highlighted items in chat",
    AUTOLOOT       = "Auto-loot highlighted items",
    AUTOLOOT_NOTE  = "Only works when the game's own auto-loot is off.",
    LOADED         = "Loaded. Type |cffffff00/goldtrash|r to configure.",
    VALUABLE       = "Valuable trash",
    PROFESSION     = "Profession item",
    LOOTED         = "Auto-looted",
}

local locale = GetLocale()
if locale == "esES" or locale == "esMX" then
    L.MIN_GOLD      = "Valor mínimo en vendedor de objetos pobres (oro):"
    L.HL_TRASH      = "Fondo dorado en objetos pobres que superen el mínimo"
    L.HL_PROFESSION = "Fondo verde en objetos de profesión"
    L.ANNOUNCE      = "Avisar en el chat de los objetos marcados"
    L.AUTOLOOT      = "Despojar automáticamente los objetos marcados"
    L.AUTOLOOT_NOTE = "Solo funciona si el despojo automático del juego está desactivado."
    L.LOADED        = "Cargado. Escribe |cffffff00/goldtrash|r para configurarlo."
    L.VALUABLE      = "Basura valiosa"
    L.PROFESSION    = "Objeto de profesión"
    L.LOOTED        = "Despojado"
end

local PREFIX = "|cffffd100[GoldTrash]|r "

-------------------------------------------------------
-- Classification
-- Returns "trash", "profession", or nil.
-- Second return is true when item info is not cached yet.
-------------------------------------------------------
local function ClassifyItem(link, quantity)
    if not link then return nil end

    local _, _, quality, _, _, _, _, _, _, _, sellPrice, classID,
          _, _, _, _, isCraftingReagent = C_Item.GetItemInfo(link)

    if not quality then return nil, true end

    if db.highlightTrash and quality == ITEM_QUALITY_POOR then
        local total = (sellPrice or 0) * math.max(quantity or 1, 1)
        if total >= db.minGold * COPPER_PER_GOLD then
            return "trash"
        end
    end

    if db.highlightProfession then
        if classID == ITEM_CLASS_TRADEGOODS or classID == ITEM_CLASS_RECIPE or isCraftingReagent then
            return "profession"
        end
    end

    return nil
end

local function ClassifySlot(slot)
    if GetLootSlotType(slot) ~= Enum.LootSlotType.Item then return nil end
    local link = GetLootSlotLink(slot)
    local _, _, quantity = GetLootSlotInfo(slot)
    local kind, pending = ClassifyItem(link, quantity)
    return kind, pending, link, quantity
end

-------------------------------------------------------
-- Loot window highlight
-------------------------------------------------------
local function GetHighlight(button)
    if button.GoldTrashBG then return button.GoldTrashBG end

    -- Sits on top of Blizzard's name bar but below the item name text
    local anchor = button.NameFrame or button
    local bg = button:CreateTexture(nil, "OVERLAY", nil, -8)
    bg:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    bg:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetBlendMode("ADD")
    bg:Hide()

    local stripe = button:CreateTexture(nil, "OVERLAY", nil, -7)
    stripe:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    stripe:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
    stripe:SetWidth(3)
    stripe:SetTexture("Interface\\Buttons\\WHITE8X8")
    stripe:Hide()

    bg.stripe = stripe
    button.GoldTrashBG = bg
    return bg
end

local UpdateButton

local function ApplyHighlight(button, kind)
    local bg = GetHighlight(button)
    local color = kind and COLORS[kind]

    if not color then
        bg:Hide()
        bg.stripe:Hide()
        return
    end

    bg:SetGradient("HORIZONTAL",
        CreateColor(color.r, color.g, color.b, 0.55),
        CreateColor(color.r, color.g, color.b, 0.05))
    bg.stripe:SetVertexColor(color.r, color.g, color.b, 1)
    bg:Show()
    bg.stripe:Show()
end

UpdateButton = function(button)
    local data = button.GetElementData and button:GetElementData()
    local slot = data and data.slotIndex
    if not slot or not db then
        ApplyHighlight(button, nil)
        return
    end

    local kind, pending, link = ClassifySlot(slot)
    ApplyHighlight(button, kind)

    -- Item info not cached yet: retry once it loads
    if pending and link then
        Item:CreateFromItemLink(link):ContinueOnItemLoad(function()
            local current = button:GetElementData()
            if current and current.slotIndex == slot and LootFrame:IsShown() then
                UpdateButton(button)
            end
        end)
    end
end

local function RefreshLootFrame()
    if not (LootFrame and LootFrame.ScrollBox and LootFrame:IsShown()) then return end
    LootFrame.ScrollBox:ForEachFrame(UpdateButton)
end

local function HookLootFrame()
    if not (LootFrame and LootFrame.ScrollBox) then return end
    ScrollUtil.AddInitializedFrameCallback(LootFrame.ScrollBox, function(_, button)
        UpdateButton(button)
    end, f, true)
end

-------------------------------------------------------
-- Announce + auto-loot
-------------------------------------------------------
local processedThisLoot = false -- LOOT_READY can fire more than once per loot

local function ProcessLoot(gameAutoLoot)
    if processedThisLoot then return end
    processedThisLoot = true

    local doAnnounce = db.announce
    local doLoot = db.autoLoot and not gameAutoLoot
    if not doAnnounce and not doLoot then return end

    -- Iterate backwards so looting a slot doesn't shift the remaining ones
    for slot = GetNumLootItems(), 1, -1 do
        local kind, _, link, quantity = ClassifySlot(slot)
        if kind then
            local color = COLORS[kind]
            local label = kind == "trash" and L.VALUABLE or L.PROFESSION
            local qty = (quantity and quantity > 1) and (" x" .. quantity) or ""

            if doLoot then
                LootSlot(slot)
                if db.announce then
                    print(PREFIX .. string.format("|c%s%s:|r %s%s", color.hex, L.LOOTED, link, qty))
                end
            elseif doAnnounce then
                print(PREFIX .. string.format("|c%s%s:|r %s%s", color.hex, label, link, qty))
            end
        end
    end
end

-------------------------------------------------------
-- Config window (/goldtrash)
-------------------------------------------------------
local configFrame

local function CreateCheckbox(parent, label, key, anchor, offsetY)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, offsetY or -4)

    local text = cb:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    text:SetText(label)

    cb:SetScript("OnShow", function(self) self:SetChecked(db[key]) end)
    cb:SetScript("OnClick", function(self)
        db[key] = self:GetChecked()
        RefreshLootFrame()
    end)
    return cb
end

local function CreateConfigFrame()
    local cf = CreateFrame("Frame", "GoldTrashConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    cf:SetSize(400, 250)
    cf:SetPoint("CENTER")
    cf:SetFrameStrata("DIALOG")
    cf:SetMovable(true)
    cf:EnableMouse(true)
    cf:SetClampedToScreen(true)
    cf:RegisterForDrag("LeftButton")
    cf:SetScript("OnDragStart", cf.StartMoving)
    cf:SetScript("OnDragStop", cf.StopMovingOrSizing)
    cf:Hide()
    tinsert(UISpecialFrames, cf:GetName()) -- Close with ESC

    cf.TitleText:SetText("Gold |cFFFFD100Trash|r")

    -- Minimum gold
    local minLabel = cf:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    minLabel:SetPoint("TOPLEFT", 18, -38)
    minLabel:SetText(L.MIN_GOLD)

    local minBox = CreateFrame("EditBox", nil, cf, "InputBoxTemplate")
    minBox:SetSize(70, 22)
    minBox:SetPoint("TOPLEFT", minLabel, "BOTTOMLEFT", 6, -6)
    minBox:SetAutoFocus(false)
    minBox:SetNumeric(true)
    minBox:SetMaxLetters(6)

    local coin = cf:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    coin:SetPoint("LEFT", minBox, "RIGHT", 6, 0)
    coin:SetText("|TInterface\\MoneyFrame\\UI-GoldIcon:14:14:0:0|t")

    local function SaveMinGold(self)
        local value = tonumber(self:GetText())
        if value then db.minGold = value end
        self:SetText(db.minGold)
        self:ClearFocus()
        RefreshLootFrame()
    end
    minBox:SetScript("OnShow", function(self) self:SetText(db.minGold) end)
    minBox:SetScript("OnEnterPressed", SaveMinGold)
    minBox:SetScript("OnEditFocusLost", SaveMinGold)
    minBox:SetScript("OnEscapePressed", function(self)
        self:SetText(db.minGold)
        self:ClearFocus()
    end)

    -- Checkboxes
    local spacer = CreateFrame("Frame", nil, cf)
    spacer:SetSize(1, 1)
    spacer:SetPoint("TOPLEFT", minBox, "BOTTOMLEFT", -10, -6)

    local cb1 = CreateCheckbox(cf, L.HL_TRASH, "highlightTrash", spacer, 0)
    local cb2 = CreateCheckbox(cf, L.HL_PROFESSION, "highlightProfession", cb1)
    local cb3 = CreateCheckbox(cf, L.ANNOUNCE, "announce", cb2)
    local cb4 = CreateCheckbox(cf, L.AUTOLOOT, "autoLoot", cb3)

    local note = cf:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", cb4, "BOTTOMLEFT", 30, 0)
    note:SetText(L.AUTOLOOT_NOTE)

    -- Color legend on the checkboxes
    for cb, kind in pairs({ [cb1] = "trash", [cb2] = "profession" }) do
        local swatch = cb:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(10, 10)
        swatch:SetPoint("RIGHT", cb, "LEFT", 0, 0)
        swatch:SetColorTexture(COLORS[kind].r, COLORS[kind].g, COLORS[kind].b, 1)
    end

    return cf
end

local function ToggleConfig()
    configFrame = configFrame or CreateConfigFrame()
    configFrame:SetShown(not configFrame:IsShown())
end

SLASH_GOLDTRASH1 = "/goldtrash"
SlashCmdList["GOLDTRASH"] = ToggleConfig

-------------------------------------------------------
-- Events
-------------------------------------------------------
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("LOOT_READY")
f:RegisterEvent("LOOT_CLOSED")

f:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        GoldTrashDB = GoldTrashDB or {}
        db = GoldTrashDB
        for k, v in pairs(DEFAULTS) do
            if db[k] == nil then db[k] = v end
        end
        HookLootFrame()
        print(PREFIX .. L.LOADED)
        f:UnregisterEvent("ADDON_LOADED")

    elseif event == "LOOT_READY" and db then
        ProcessLoot(arg1)

    elseif event == "LOOT_CLOSED" then
        processedThisLoot = false
    end
end)
