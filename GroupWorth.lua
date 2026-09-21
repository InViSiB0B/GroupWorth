-- GroupWorth: tracks net worth (bags + gold, and bags + gold + equipped gear)
-- for you and every group member who also runs the addon.
--
-- Item value = vendor sell price. To use another price source (Auctionator,
-- TSM, ...), change GetItemValue() below.

local ADDON, ns = ...
local PREFIX = "GroupWorth"
local PROTOCOL = 1

local UPDATE_DELAY = 1 -- seconds; debounces bag/money/equipment event bursts

local floor = math.floor

-- Client API differences ----------------------------------------------------

local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetNumSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
local ContainerIDToInventoryID = (C_Container and C_Container.ContainerIDToInventoryID) or ContainerIDToInventoryID
local RegisterPrefix = (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) or RegisterAddonMessagePrefix
local SendMessage = (C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage

local LAST_BAG = (NUM_BAG_SLOTS or 4) + (NUM_REAGENTBAG_SLOTS or 0)
local FIRST_EQUIPPED = INVSLOT_FIRST_EQUIPPED or 1
local LAST_EQUIPPED = INVSLOT_LAST_EQUIPPED or 19

local function GetSlotItem(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then return info.hyperlink, info.stackCount or 1 end
    else
        local _, count, _, _, _, _, link = GetContainerItemInfo(bag, slot)
        return link, count or 1
    end
end

-- State ---------------------------------------------------------------------

local db
local mine = { bag = 0, equipped = 0 } -- copper
local others = {}                      -- [name] = { bag = copper, equipped = copper }
local incomplete = false               -- true while some item data is not cached yet
local updatePending = false
local forceBroadcast = false
local lastSent

-- Valuation -----------------------------------------------------------------

-- Returns the per-unit value of an item link in copper, or nil if the item
-- is not in the client cache yet.
local function GetItemValue(link)
    local sellPrice = select(11, GetItemInfoFn(link))
    return sellPrice
end

local function AddItem(link, count)
    local value = GetItemValue(link)
    if not value then
        incomplete = true
        return 0
    end
    return value * count
end

local function ComputeWorth()
    incomplete = false

    local bag = GetMoney()
    for b = 0, LAST_BAG do
        for slot = 1, (GetNumSlots(b) or 0) do
            local link, count = GetSlotItem(b, slot)
            if link then bag = bag + AddItem(link, count) end
        end
    end

    local equipped = 0
    for slot = FIRST_EQUIPPED, LAST_EQUIPPED do
        local link = GetInventoryItemLink("player", slot)
        if link then equipped = equipped + AddItem(link, 1) end
    end

    -- The bags themselves (including quivers/ammo pouches) count as equipped.
    for b = 1, LAST_BAG do
        local link = GetInventoryItemLink("player", ContainerIDToInventoryID(b))
        if link then equipped = equipped + AddItem(link, 1) end
    end

    mine.bag, mine.equipped = bag, equipped
end

-- Formatting ----------------------------------------------------------------

local GOLD = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local function Commas(n)
    return (tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function FormatMoney(copper)
    copper = floor(copper + 0.5)
    local g = floor(copper / 10000)
    local s = floor(copper / 100) % 100
    local c = copper % 100

    local out = {}
    if g > 0 then out[#out + 1] = Commas(g) .. GOLD end
    if s > 0 then out[#out + 1] = s .. SILVER end
    if c > 0 or #out == 0 then out[#out + 1] = c .. COPPER end
    return table.concat(out, " ")
end

local function FormatWorth(bag, equipped)
    return format("%s (%s)", FormatMoney(bag), FormatMoney(bag + equipped))
end

-- Group helpers -------------------------------------------------------------

local function UnitKey(unit)
    local name = GetUnitName(unit, true)
    return name and Ambiguate(name, "none")
end

-- Returns an ordered list of { unit =, name = } for the player and group.
local function GetRoster()
    local roster = { { unit = "player", name = UnitKey("player") } }
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if not UnitIsUnit(unit, "player") then
                roster[#roster + 1] = { unit = unit, name = UnitKey(unit) }
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local unit = "party" .. i
            roster[#roster + 1] = { unit = unit, name = UnitKey(unit) }
        end
    end
    return roster
end

local function GroupChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
        return "INSTANCE_CHAT"
    elseif IsInRaid() then
        return "RAID"
    elseif IsInGroup() then
        return "PARTY"
    end
end

-- Window --------------------------------------------------------------------

local PAD, ROW_HEIGHT, COLUMN_GAP = 10, 14, 16

local frame = CreateFrame("Frame", "GroupWorthFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
frame:SetSize(200, 40)
frame:SetPoint("CENTER")
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:Hide()

if frame.SetBackdrop then
    frame:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(0, 0, 0, 0.75)
end

frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.position = { point, relPoint, x, y }
end)

local rows = {}

local function GetRow(i)
    local row = rows[i]
    if not row then
        row = {
            name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall"),
            value = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"),
        }
        row.name:SetJustifyH("LEFT")
        row.value:SetJustifyH("RIGHT")
        row.name:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD - (i - 1) * ROW_HEIGHT)
        row.value:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, -PAD - (i - 1) * ROW_HEIGHT)
        rows[i] = row
    end
    return row
end

local function SetRow(i, nameText, valueText)
    local row = GetRow(i)
    row.name:SetText(nameText)
    row.value:SetText(valueText)
    row.name:Show()
    row.value:Show()
    return row.name:GetStringWidth(), row.value:GetStringWidth()
end

local function ClassColored(unit, name)
    local _, class = UnitClass(unit)
    local color = class and RAID_CLASS_COLORS[class]
    if color then
        return format("|cff%02x%02x%02x%s|r", color.r * 255, color.g * 255, color.b * 255, name)
    end
    return name
end

local function UpdateDisplay()
    if not frame:IsShown() then return end

    local used, maxName, maxValue = 0, 0, 0
    local totalBag, totalEquipped = 0, 0

    for _, member in ipairs(GetRoster()) do
        local data = (member.unit == "player") and mine or others[member.name]
        if data then
            used = used + 1
            totalBag = totalBag + data.bag
            totalEquipped = totalEquipped + data.equipped
            local nameW, valueW = SetRow(used, ClassColored(member.unit, member.name or UNKNOWN) .. ":", FormatWorth(data.bag, data.equipped))
            maxName, maxValue = math.max(maxName, nameW), math.max(maxValue, valueW)
        end
    end

    if used > 1 or db.goal then
        used = used + 1
        local value = FormatWorth(totalBag, totalEquipped)
        if db.goal then
            value = value .. " / " .. FormatMoney(db.goal)
            if totalBag + totalEquipped >= db.goal then
                value = "|cff40ff40" .. value .. "|r" -- goal reached
            end
        end
        local nameW, valueW = SetRow(used, "Party:", value)
        maxName, maxValue = math.max(maxName, nameW), math.max(maxValue, valueW)
    end

    for i = used + 1, #rows do
        rows[i].name:Hide()
        rows[i].value:Hide()
    end

    frame:SetSize(PAD * 2 + maxName + COLUMN_GAP + maxValue, PAD * 2 + used * ROW_HEIGHT - 2)
end

-- Networking ----------------------------------------------------------------

local function Broadcast()
    local channel = GroupChannel()
    if not channel then return end
    SendMessage(PREFIX, format("%d:%.0f:%.0f", PROTOCOL, mine.bag, mine.equipped), channel)
end

-- Goal message: "G:<copper>" (0 clears). Sent by the group leader.
local function BroadcastGoal()
    local channel = GroupChannel()
    if not channel then return end
    SendMessage(PREFIX, format("G:%.0f", db.goal or 0), channel)
end

local function IsLeaderName(name)
    for _, member in ipairs(GetRoster()) do
        if member.name == name then return UnitIsGroupLeader(member.unit) end
    end
end

local function OnAddonMessage(prefix, text, _, sender)
    if prefix ~= PREFIX then return end

    local key = Ambiguate(sender, "none")
    if key == UnitKey("player") then return end

    local goal = text:match("^G:(%d+)$")
    if goal then
        if IsLeaderName(key) then
            db.goal = tonumber(goal) > 0 and tonumber(goal) or nil
            UpdateDisplay()
        end
        return
    end

    local version, bag, equipped = text:match("^(%d+):(%d+):(%d+)$")
    if tonumber(version) ~= PROTOCOL then return end

    others[key] = { bag = tonumber(bag), equipped = tonumber(equipped) }
    UpdateDisplay()
end

-- Goals only make sense inside a group.
local function ClearGoalIfSolo()
    if not IsInGroup() then db.goal = nil end
end

local COIN_MULTIPLIER = { g = 10000, s = 100, c = 1 }

-- Parses e.g. "10s", "1g 50s", "2.5g" into copper. Returns nil if invalid.
local function ParseMoney(text)
    local total = 0
    local rest = text:lower():gsub(",", ""):gsub("([%d%.]+)%s*([gsc])", function(n, unit)
        total = total + (tonumber(n) or 0) * COIN_MULTIPLIER[unit]
        return ""
    end)
    if rest:match("%S") or total <= 0 then return nil end
    return floor(total + 0.5)
end

-- Prune data for anyone who is no longer in the group.
local function PruneOthers()
    local present = {}
    for _, member in ipairs(GetRoster()) do
        if member.name then present[member.name] = true end
    end
    for name in pairs(others) do
        if not present[name] then others[name] = nil end
    end
end

-- Update loop ---------------------------------------------------------------

local function Refresh()
    updatePending = false
    ComputeWorth()

    local signature = mine.bag .. ":" .. mine.equipped
    if forceBroadcast or signature ~= lastSent then
        if forceBroadcast and db.goal and UnitIsGroupLeader("player") then
            BroadcastGoal() -- so new members learn the goal
        end
        forceBroadcast = false
        lastSent = signature
        Broadcast()
    end
    UpdateDisplay()
end

local function ScheduleRefresh()
    if updatePending then return end
    updatePending = true
    C_Timer.After(UPDATE_DELAY, Refresh)
end

-- Events --------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local events = {}

function events.ADDON_LOADED(name)
    if name ~= ADDON then return end
    GroupWorthDB = GroupWorthDB or {}
    db = GroupWorthDB
    if db.shown == nil then db.shown = true end

    if db.position then
        frame:ClearAllPoints()
        frame:SetPoint(db.position[1], UIParent, db.position[2], db.position[3], db.position[4])
    end
    frame:SetShown(db.shown)

    RegisterPrefix(PREFIX)
    eventFrame:UnregisterEvent("ADDON_LOADED")
end

function events.PLAYER_ENTERING_WORLD()
    ClearGoalIfSolo()
    forceBroadcast = true
    ScheduleRefresh()
end

function events.GROUP_ROSTER_UPDATE()
    ClearGoalIfSolo()
    PruneOthers()
    forceBroadcast = true -- so new members receive our numbers
    ScheduleRefresh()
end

function events.GET_ITEM_INFO_RECEIVED()
    if incomplete then ScheduleRefresh() end
end

events.CHAT_MSG_ADDON = OnAddonMessage
events.BAG_UPDATE_DELAYED = ScheduleRefresh
events.PLAYER_MONEY = ScheduleRefresh
events.PLAYER_EQUIPMENT_CHANGED = ScheduleRefresh

eventFrame:SetScript("OnEvent", function(_, event, ...)
    events[event](...)
end)
for event in pairs(events) do
    eventFrame:RegisterEvent(event)
end

-- Slash commands ------------------------------------------------------------

local function SetShown(shown)
    db.shown = shown
    frame:SetShown(shown)
    if shown then UpdateDisplay() end
end

SLASH_GROUPWORTH1 = "/groupworth"
SLASH_GROUPWORTH2 = "/gw"
local function Print(text)
    print("|cffffd100GroupWorth|r: " .. text)
end

local function HandleGoal(arg)
    if arg == "" then
        Print(db.goal and ("goal is " .. FormatMoney(db.goal)) or "no goal set")
        return
    end
    if not IsInGroup() or not UnitIsGroupLeader("player") then
        Print("only the group leader can set a goal")
        return
    end
    if arg == "clear" or arg == "off" then
        db.goal = nil
    else
        db.goal = ParseMoney(arg)
        if not db.goal then
            Print("couldn't read that amount. Try /gw goal 10s, /gw goal 1g 50s, or /gw goal clear")
            return
        end
    end
    BroadcastGoal()
    UpdateDisplay()
end

SlashCmdList.GROUPWORTH = function(msg)
    msg = strlower(strtrim(msg or ""))
    local cmd, arg = msg:match("^(%S*)%s*(.-)$")
    if cmd == "goal" then
        HandleGoal(arg)
    elseif msg == "show" then
        SetShown(true)
    elseif msg == "hide" then
        SetShown(false)
    elseif msg == "reset" then
        db.position = nil
        frame:ClearAllPoints()
        frame:SetPoint("CENTER")
    elseif msg == "" or msg == "toggle" then
        SetShown(not frame:IsShown())
    else
        Print("/gw [show | hide | toggle | reset | goal <amount> | goal clear]")
    end
end
