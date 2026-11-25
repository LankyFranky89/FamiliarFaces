local function Secret(v) -- chat hidden by the game (or faked by /cc secret)
  if CopyCatFakeSecret and CopyCatFakeSecret > GetTime() then return true end
  return issecretvalue ~= nil and issecretvalue(v) == true
end
-- Familiar Faces: remembers who you grouped with, where, and on which quests.
local ADDON = ...
local f = CreateFrame("Frame")
local DB
local MAX_SESSIONS = 25
local active = {}        -- key -> session table currently open
local wasParty = false   -- last group was a 5-man (rating popup only for those)
local questTitles = {}   -- questID -> title cache

local function now() return time() end

local function Key(unit)
  local name, realm = UnitName(unit)
  if not name or name == UNKNOWNOBJECT then return nil end
  if not realm or realm == "" then realm = GetRealmName() end
  return name .. "-" .. realm, name
end

local function Zone()
  local z = GetRealZoneText() or GetZoneText() or "?"
  local sub = GetSubZoneText()
  return z, sub
end

local function Ago(t)
  local d = now() - t
  if d < 60 then return "just now" end
  if d < 3600 then return math.floor(d/60) .. " min ago" end
  if d < 86400 then return math.floor(d/3600) .. " h ago" end
  local days = math.floor(d/86400)
  return days .. (days == 1 and " day ago" or " days ago")
end

local function AddUnique(list, v)
  if not v or v == "" then return end
  for _, x in ipairs(list) do if x == v then return end end
  table.insert(list, v)
end

local DONE = " ✓"   -- storage marker, never shown raw (chat font lacks the glyph)
local CHECK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"

local function AddQuest(list, title, done)
  if not title or title == "" then return end
  if done then
    for i = #list, 1, -1 do if list[i] == title then table.remove(list, i) end end
    AddUnique(list, title .. DONE)
  else
    for _, x in ipairs(list) do if x == title or x == title .. DONE then return end end
    table.insert(list, title)
  end
end

-- Clean list for display: done quests first, no duplicates, checkmark icon, optional limit.
local function QuestText(list, limit)
  local done, open, seen = {}, {}, {}
  for _, q in ipairs(list) do
    local base = q:gsub(DONE .. "$", "")
    local isDone = base ~= q
    if isDone then seen[base] = true end
  end
  local added = {}
  for _, q in ipairs(list) do
    local base = q:gsub(DONE .. "$", "")
    if not added[base] then
      if seen[base] then done[#done+1] = base .. " " .. CHECK
      else open[#open+1] = base end
      added[base] = true
    end
  end
  local all = {}
  for _, v in ipairs(done) do all[#all+1] = v end
  for _, v in ipairs(open) do all[#all+1] = v end
  if limit and #all > limit then
    local extra = #all - limit
    local short = {}
    for i = 1, limit do short[i] = all[i] end
    return table.concat(short, ", ") .. (" |cff999999+%d more|r"):format(extra), #all
  end
  return table.concat(all, ", "), #all
end

local UP = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local DOWN = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"
local function RateIcon(p)
  if not p then return "" end
  if p.rating == 1 then return " " .. UP elseif p.rating == -1 then return " " .. DOWN end
  return ""
end

local function DungeonText(list)
  local out = {}
  for _, d in ipairs(list or {}) do
    local t = "|cffa335ee" .. d.name .. "|r"
    if d.bosses and #d.bosses > 0 then
      t = t .. (" |cff999999(%d boss%s)|r"):format(#d.bosses, #d.bosses == 1 and "" or "es")
    end
    out[#out+1] = t
  end
  return table.concat(out, ", ")
end

local function QuestTitle(id)
  if not id then return nil end
  if questTitles[id] then return questTitles[id] end
  if C_QuestLog and C_QuestLog.GetQuestInfo then
    local t = C_QuestLog.GetQuestInfo(id)
    if t and t ~= "" then questTitles[id] = t; return t end
  end
  if C_QuestLog and C_QuestLog.GetTitleForQuestID then
    local t = C_QuestLog.GetTitleForQuestID(id)
    if t and t ~= "" then questTitles[id] = t; return t end
  end
  return nil
end

local function ScanQuestLog()
  if not GetNumQuestLogEntries then return end
  for i = 1, GetNumQuestLogEntries() do
    local title, _, _, isHeader, _, _, _, id = GetQuestLogTitle(i)
    if title and not isHeader and id then questTitles[id] = title end
  end
end

local function GroupUnits()
  local units = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do units[#units+1] = "raid"..i end
  elseif IsInGroup() then
    for i = 1, GetNumSubgroupMembers() do units[#units+1] = "party"..i end
  end
  return units
end

local function Notify(msg)
  DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffFamiliar Faces:|r " .. msg)
end

local function Summary(p)
  local last = p.sessions[#p.sessions]
  if not last then return "" end
  local s = ("%d time%s, last seen %s in %s"):format(#p.sessions, #p.sessions == 1 and "" or "s",
    Ago(last.last or last.start), last.zones[#last.zones] or "?")
  if last.dungeons and #last.dungeons > 0 then s = s .. " · " .. DungeonText(last.dungeons) end
  if #last.quests > 0 then
    local txt = QuestText(last.quests, 3)
    s = s .. " · " .. txt
  end
  s = s .. "  |cff999999(/ff " .. (p.name or "") .. " for all)|r"
  return s
end

local function OpenSession(unit)
  local key, name = Key(unit)
  if not key or active[key] then return end
  local p = DB.players[key]
  local isNew = not p
  if not p then
    p = { name = name, sessions = {} }
    DB.players[key] = p
  elseif DB.alerts then
    Notify("You've played with |cffffff00" .. name .. "|r" .. RateIcon(p) .. " before: " .. Summary(p))
  end
  local _, class = UnitClass(unit)
  p.class = class or p.class
  p.level = UnitLevel(unit) or p.level
  local z = Zone()
  local s = { start = now(), last = now(), zones = {}, quests = {}, dungeons = {} }
  AddUnique(s.zones, z)
  table.insert(p.sessions, s)
  while #p.sessions > MAX_SESSIONS do table.remove(p.sessions, 1) end
  active[key] = s
end

local ShowRatePopup
local function RefreshGroup()
  local present = {}
  for _, u in ipairs(GroupUnits()) do
    if UnitExists(u) and UnitIsPlayer(u) and not UnitIsUnit(u, "player") then
      local key = Key(u)
      if key then
        present[key] = true
        if not active[key] then OpenSession(u) end
        local p = DB.players[key]
        if p then p.level = UnitLevel(u) or p.level end
      end
    end
  end
  local ended = {}
  for key, s in pairs(active) do
    if not present[key] then
      s.last = now(); active[key] = nil
      if s.last - s.start >= 180 then ended[#ended+1] = key end
    end
  end
  if #ended > 0 and not IsInGroup() and wasParty and DB.ratePopup then
    ShowRatePopup(ended)
  end
  if IsInGroup() then wasParty = not IsInRaid() end
end

local function ForActive(fn)
  for _, s in pairs(active) do s.last = now(); fn(s) end
end

-- Dungeons -----------------------------------------------------------
local function CurrentDungeon()
  local inInst, kind = IsInInstance()
  if inInst and (kind == "party" or kind == "raid") then return (GetInstanceInfo()) end
end
local function TrackDungeon()
  local name = CurrentDungeon()
  if not name then return end
  ForActive(function(s)
    s.dungeons = s.dungeons or {}
    local last = s.dungeons[#s.dungeons]
    if not last or last.name ~= name then
      s.dungeons[#s.dungeons+1] = { name = name, bosses = {} }
    end
  end)
end
local function BossKilled(boss)
  if not CurrentDungeon() or not boss then return end
  ForActive(function(s)
    s.dungeons = s.dungeons or {}
    local d = s.dungeons[#s.dungeons]
    if d then AddUnique(d.bosses, boss) end
  end)
end

-- Rating ---------------------------------------------------------------
local function SetRating(key, value)
  local p = DB.players[key]
  if not p then return end
  p.rating = value
end

local ratePopup
ShowRatePopup = function(keys)
  if not ratePopup then
    ratePopup = CreateFrame("Frame", "FamiliarFacesRate", UIParent, "BackdropTemplate")
    ratePopup:SetSize(270, 60); ratePopup:SetPoint("TOP", 0, -140)
    ratePopup:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    ratePopup:SetBackdropColor(0, 0, 0, 0.9)
    ratePopup:SetMovable(true); ratePopup:EnableMouse(true); ratePopup:RegisterForDrag("LeftButton")
    ratePopup:SetScript("OnDragStart", ratePopup.StartMoving)
    ratePopup:SetScript("OnDragStop", ratePopup.StopMovingOrSizing)
    ratePopup:SetFrameStrata("DIALOG")
    local t = ratePopup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("TOP", 0, -10); t:SetText("Familiar Faces – rate your group")
    local close = CreateFrame("Button", nil, ratePopup, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    ratePopup.rows = {}
  end
  for _, r in ipairs(ratePopup.rows) do r:Hide() end
  for i, key in ipairs(keys) do
    if i > 5 then break end
    local r = ratePopup.rows[i]
    if not r then
      r = CreateFrame("Frame", nil, ratePopup); r:SetSize(240, 22)
      r:SetPoint("TOPLEFT", 14, -30 - (i-1) * 24)
      r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      r.name:SetPoint("LEFT"); r.name:SetWidth(150); r.name:SetJustifyH("LEFT")
      local function Btn(tex, x)
        local b = CreateFrame("Button", nil, r); b:SetSize(20, 20); b:SetPoint("LEFT", x, 0)
        b:SetNormalTexture(tex); b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        return b
      end
      r.up = Btn("Interface\\RaidFrame\\ReadyCheck-Ready", 160)
      r.down = Btn("Interface\\RaidFrame\\ReadyCheck-NotReady", 188)
      r.mark = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
      r.mark:SetPoint("LEFT", 214, 0)
      ratePopup.rows[i] = r
    end
    local p = DB.players[key]
    local c = RAID_CLASS_COLORS[p and p.class or ""]
    r.name:SetText(p and p.name or key)
    if c then r.name:SetTextColor(c.r, c.g, c.b) else r.name:SetTextColor(1, 1, 1) end
    local function Mark() r.mark:SetText(RateIcon(DB.players[key])) end
    r.up:SetScript("OnClick", function() SetRating(key, 1); Mark() end)
    r.down:SetScript("OnClick", function() SetRating(key, -1); Mark() end)
    Mark(); r:Show()
  end
  ratePopup:SetHeight(40 + math.min(#keys, 5) * 24)
  ratePopup:Show()
end

-- Note popup -------------------------------------------------------------
StaticPopupDialogs["FAMILIARFACES_NOTE"] = {
  text = "Familiar Faces note for %s:",
  button1 = ACCEPT, button2 = CANCEL, hasEditBox = true, maxLetters = 200,
  OnShow = function(self, key)
    local p = DB.players[key]
    local eb = self.editBox or self.EditBox
    eb:SetText(p and p.note or ""); eb:HighlightText()
  end,
  OnAccept = function(self, key)
    local eb = self.editBox or self.EditBox
    local txt = eb:GetText()
    local p = DB.players[key]
    if not p then
      p = { name = key:match("^[^-]+"), sessions = {} }; DB.players[key] = p
    end
    p.note = txt ~= "" and txt or nil
  end,
  EditBoxOnEnterPressed = function(self)
    local parent = self:GetParent()
    StaticPopupDialogs.FAMILIARFACES_NOTE.OnAccept(parent, parent.data)
    parent:Hide()
  end,
  EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
  timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- Right-click menu --------------------------------------------------------
local ShowWindow -- forward
local function KeyFromNameRealm(name, realm)
  if not name then return nil end
  if name:find("-") then return name end
  if not realm or realm == "" then realm = GetRealmName() end
  return name .. "-" .. realm
end
local function MenuActions(key)
  local name = key:match("^[^-]+")
  return {
    { "Show history", function() ShowWindow(name:lower()) end },
    { "Edit note", function() StaticPopup_Show("FAMILIARFACES_NOTE", name, nil, key) end },
    { "Rate " .. UP .. " good", function()
        DB.players[key] = DB.players[key] or { name = name, sessions = {} }
        SetRating(key, 1); Notify(name .. " rated " .. UP) end },
    { "Rate " .. DOWN .. " avoid", function()
        DB.players[key] = DB.players[key] or { name = name, sessions = {} }
        SetRating(key, -1); Notify(name .. " rated " .. DOWN) end },
    { "Clear rating", function()
        if DB.players[key] then DB.players[key].rating = nil end; Notify(name .. " rating cleared") end },
  }
end

local function SetupMenus()
  if Menu and Menu.ModifyMenu then
    local tags = { "MENU_UNIT_PLAYER", "MENU_UNIT_PARTY", "MENU_UNIT_RAID_PLAYER",
      "MENU_UNIT_RAID", "MENU_UNIT_FRIEND", "MENU_UNIT_TARGET", "MENU_UNIT_FOCUS",
      "MENU_UNIT_COMMUNITIES_GUILD_MEMBER", "MENU_UNIT_GUILD" }
    for _, tag in ipairs(tags) do
      pcall(Menu.ModifyMenu, tag, function(owner, root, ctx)
        local key
        if ctx.unit and UnitIsPlayer(ctx.unit) and not UnitIsUnit(ctx.unit, "player") then
          key = Key(ctx.unit)
        elseif ctx.name and ctx.name ~= UnitName("player") then
          key = KeyFromNameRealm(ctx.name, ctx.server)
        end
        if not key then return end
        root:CreateDivider()
        root:CreateTitle("Familiar Faces")
        for _, a in ipairs(MenuActions(key)) do root:CreateButton(a[1], a[2]) end
      end)
    end
  elseif UnitPopup_ShowMenu then
    hooksecurefunc("UnitPopup_ShowMenu", function(dropdown, which, unit, name, server)
      if UIDROPDOWNMENU_MENU_LEVEL ~= 1 then return end
      local key
      if unit and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then key = Key(unit)
      elseif name and name ~= UnitName("player") and
        (which == "FRIEND" or which == "PARTY" or which == "PLAYER" or which == "RAID_PLAYER") then
        key = KeyFromNameRealm(name, server)
      end
      if not key then return end
      local info = UIDropDownMenu_CreateInfo()
      info.text = "Familiar Faces"; info.isTitle = true; info.notCheckable = true
      UIDropDownMenu_AddButton(info, 1)
      for _, a in ipairs(MenuActions(key)) do
        info = UIDropDownMenu_CreateInfo()
        info.text = a[1]; info.notCheckable = true; info.func = a[2]
        UIDropDownMenu_AddButton(info, 1)
      end
    end)
  end
end

-- Whisper alert -----------------------------------------------------------
local whisperSeen = {}
local function OnWhisper(sender)
  if not DB.whisper or not sender or Secret(sender) then return end
  local key = KeyFromNameRealm(sender, nil)
  if not key or active[key] then return end
  local p = DB.players[key]
  if not p or #p.sessions == 0 then return end
  if whisperSeen[key] then return end   -- once per player per session
  whisperSeen[key] = true
  local name = p.name or key:match("^[^-]+")
  -- print after the whisper line itself
  C_Timer.After(0, function()
    Notify("|cffff80ff" .. name .. "|r" .. RateIcon(p) .. " whispered you – " .. Summary(p) ..
      (p.note and ("  |cff99ff99note: " .. p.note .. "|r") or ""))
  end)
end

-- Tooltip --------------------------------------------------------------
local CLASS_COLORS = RAID_CLASS_COLORS
local function OnUnitTooltip(tt)
  if tt ~= GameTooltip then return end
  if not DB or not DB.tooltip then return end
  local _, unit = tt:GetUnit()
  if not unit and UnitExists("mouseover") then unit = "mouseover" end
  if not unit or not UnitIsPlayer(unit) or UnitIsUnit(unit, "player") then return end
  local key = Key(unit)
  local p = key and DB.players[key]
  if not p or #p.sessions == 0 then return end
  tt:AddLine(" ")
  tt:AddLine(("|cff66ccffPlayed with you %d time%s|r"):format(#p.sessions, #p.sessions == 1 and "" or "s") .. RateIcon(p))
  for i = #p.sessions, math.max(1, #p.sessions - 2), -1 do
    local s = p.sessions[i]
    tt:AddLine(("%s – %s"):format(Ago(s.last or s.start), table.concat(s.zones, ", ")), 1, 1, 1, true)
    if s.dungeons and #s.dungeons > 0 then
      tt:AddLine("   Dungeons: " .. DungeonText(s.dungeons), 1, 1, 1, true)
    end
    if #s.quests > 0 then
      tt:AddLine("   Quests: " .. (QuestText(s.quests, 4)), 1, 0.82, 0, true)
    end
  end
  if p.note then tt:AddLine("Note: " .. p.note, 0.6, 1, 0.6, true) end
  tt:Show()
end
if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, OnUnitTooltip)
elseif GameTooltip:HasScript("OnTooltipSetUnit") then
  GameTooltip:HookScript("OnTooltipSetUnit", OnUnitTooltip)
end

-- Window ---------------------------------------------------------------
local win
local function Lines(filter)
  local out = {}
  local list = {}
  for key, p in pairs(DB.players) do
    if #p.sessions > 0 and (not filter or key:lower():find(filter, 1, true)) then
      list[#list+1] = { key = key, p = p, t = p.sessions[#p.sessions].last or 0 }
    end
  end
  table.sort(list, function(a, b) return a.t > b.t end)
  for _, e in ipairs(list) do
    local p = e.p
    local c = CLASS_COLORS[p.class or ""]
    local hex = c and ("|cff%02x%02x%02x"):format(c.r*255, c.g*255, c.b*255) or "|cffffffff"
    out[#out+1] = ("%s%s|r%s  |cff999999lvl %s · %d time%s|r"):format(hex, e.key, RateIcon(p), p.level or "?",
      #p.sessions, #p.sessions == 1 and "" or "s")
    for i = #p.sessions, 1, -1 do
      local s = p.sessions[i]
      out[#out+1] = ("   |cffccccccdate:|r %s  |cffcccccczone:|r %s"):format(date("%d.%m.%Y %H:%M", s.start), table.concat(s.zones, ", "))
      if s.dungeons and #s.dungeons > 0 then out[#out+1] = "      " .. DungeonText(s.dungeons) end
      if #s.quests > 0 then out[#out+1] = "      |cffffd100" .. (QuestText(s.quests)) .. "|r" end
    end
    if p.note then out[#out+1] = "   |cff99ff99note: " .. p.note .. "|r" end
    out[#out+1] = " "
  end
  if #out == 0 then out[1] = "Nobody yet — go group up!" end
  return table.concat(out, "\n")
end

ShowWindow = function(filter)
  if not win then
    win = CreateFrame("Frame", "FamiliarFacesFrame", UIParent, "BackdropTemplate")
    win:SetSize(520, 420); win:SetPoint("CENTER")
    win:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    win:SetBackdropColor(0, 0, 0, 0.9)
    win:SetMovable(true); win:EnableMouse(true); win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving); win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetFrameStrata("DIALOG")
    tinsert(UISpecialFrames, "FamiliarFacesFrame")
    local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", 0, -10); title:SetText("Familiar Faces")
    local close = CreateFrame("Button", nil, win, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    local search = CreateFrame("EditBox", nil, win, "InputBoxTemplate")
    search:SetSize(200, 20); search:SetPoint("TOPLEFT", 16, -34); search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
      local t = self:GetText(); win.Refresh(t ~= "" and t:lower() or nil)
    end)
    search:SetScript("OnEscapePressed", search.ClearFocus)
    local hint = win:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", search, "RIGHT", 8, 0); hint:SetText("search name")
    local sf = CreateFrame("ScrollFrame", nil, win, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 12, -62); sf:SetPoint("BOTTOMRIGHT", -32, 12)
    local child = CreateFrame("Frame", nil, sf); child:SetSize(470, 10); sf:SetScrollChild(child)
    local text = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT"); text:SetWidth(470); text:SetJustifyH("LEFT"); text:SetSpacing(2)
    win.Refresh = function(flt)
      text:SetText(Lines(flt)); child:SetHeight(text:GetStringHeight() + 10)
    end
    win.search = search
  end
  win.search:SetText(filter or "")
  win.Refresh(filter); win:Show()
end

-- Events ---------------------------------------------------------------
f:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    FamiliarFacesDB = FamiliarFacesDB or {}
    DB = FamiliarFacesDB
    DB.players = DB.players or {}
    if DB.alerts == nil then DB.alerts = true end
    if DB.tooltip == nil then DB.tooltip = true end
    if DB.ratePopup == nil then DB.ratePopup = true end
    if DB.whisper == nil then DB.whisper = true end
    SetupMenus()
  elseif event == "PLAYER_ENTERING_WORLD" or event == "GROUP_ROSTER_UPDATE" then
    ScanQuestLog(); RefreshGroup(); TrackDungeon()
  elseif event == "CHAT_MSG_WHISPER" then
    local _, sender = ...
    OnWhisper(sender)
  elseif event == "ENCOUNTER_END" then
    local _, bossName, _, _, success = ...
    if success == 1 then BossKilled(bossName) end
  elseif event == "BOSS_KILL" then
    local _, bossName = ...
    BossKilled(bossName)
  elseif event == "ZONE_CHANGED_NEW_AREA" then
    local z = Zone()
    ForActive(function(s) AddUnique(s.zones, z) end)
    TrackDungeon()
  elseif event == "QUEST_ACCEPTED" then
    local a, b = ...
    local id = b or a
    ScanQuestLog()
    local t = QuestTitle(id)
    if t then ForActive(function(s) AddQuest(s.quests, t, false) end) end
  elseif event == "QUEST_TURNED_IN" then
    local id = ...
    local t = QuestTitle(id)
    if t then ForActive(function(s) AddQuest(s.quests, t, true) end) end
  elseif event == "QUEST_LOG_UPDATE" then
    ScanQuestLog()
  end
end)
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_ENTERING_WORLD", "GROUP_ROSTER_UPDATE",
  "ZONE_CHANGED_NEW_AREA", "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE", "ENCOUNTER_END", "BOSS_KILL", "CHAT_MSG_WHISPER" }) do
  pcall(f.RegisterEvent, f, e)
end

-- Slash ----------------------------------------------------------------
SLASH_FAMILIARFACES1 = "/ff"
SLASH_FAMILIARFACES2 = "/faces"
SlashCmdList.FAMILIARFACES = function(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower()
  if cmd == "alerts" then
    DB.alerts = not DB.alerts; Notify("join alerts " .. (DB.alerts and "ON" or "OFF"))
  elseif cmd == "tooltip" then
    DB.tooltip = not DB.tooltip; Notify("tooltip info " .. (DB.tooltip and "ON" or "OFF"))
  elseif cmd == "whisper" then
    DB.whisper = not DB.whisper; Notify("whisper alerts " .. (DB.whisper and "ON" or "OFF"))
  elseif cmd == "rate" then
    DB.ratePopup = not DB.ratePopup; Notify("rate popup after groups " .. (DB.ratePopup and "ON" or "OFF"))
  elseif cmd == "note" then
    if not UnitIsPlayer("target") then Notify("target a player first"); return end
    local key, name = Key("target")
    DB.players[key] = DB.players[key] or { name = name, sessions = {} }
    DB.players[key].note = rest ~= "" and rest or nil
    Notify(rest ~= "" and ("note saved for " .. name) or ("note cleared for " .. name))
  elseif cmd == "purge" then
    local days = tonumber(rest) or 90
    local cutoff = now() - days * 86400
    local removed = 0
    for key, p in pairs(DB.players) do
      local last = p.sessions[#p.sessions]
      local t = last and (last.last or last.start) or 0
      if not active[key] and not p.note and t < cutoff then
        DB.players[key] = nil; removed = removed + 1
      end
    end
    Notify(("purged %d player%s not seen in %d days (players with notes are kept)"):format(
      removed, removed == 1 and "" or "s", days))
    if win and win:IsShown() then win.Refresh(nil) end
  elseif cmd == "help" then
    Notify("/ff [name] – open list (optionally searched) · /ff note <text> – note on target · /ff purge [days] – remove players not seen in 90 (or given) days · /ff rate – toggle rate popup · /ff whisper – toggle whisper alerts · right-click a player for menu · /ff alerts · /ff tooltip")
  else
    ShowWindow(msg ~= "" and msg:lower() or nil)
  end
end
