local mq = require 'mq'
local imgui = require 'ImGui'
local icons = require 'mq.Icons'
local actors = require 'actors'

-- Ensure MQ2Mono is loaded for switcher functionality
if not mq.TLO.MQ2Mono then
    print('\arError: MQ2Mono plugin is not loaded. Please load it with /plugin MQ2Mono\ax')
    mq.exit()
end

------------------------------------------------------
-- GLOBAL VARIABLES FOR COMBINED UI
------------------------------------------------------
local combinedUIOpen        = true
local combinedUIInitialized = false

-- Peer Data & Settings
local peers = {}
local peer_list = {}
local lastPeerCount = 0
local cachedPeerHeight = 300
local refreshInterval   = 50
local staleDataTimeout  = 30
local lastUpdateTime    = {}
local lastPublishTime   = 0
local PUBLISH_INTERVAL  = 0.5

local sort_mode         = "Alphabetical"
local show_name         = true
local show_hp           = true
local show_distance     = true
local show_dps          = true

-- DPS tracking variables
local dmgTotalBattle    = 0
local dmgBattCounter    = 0
local critTotalBattle   = 0
local critHealsTotal    = 0
local dmgTotalDS        = 0
local dsCounter         = 0
local dmgTotalNonMelee  = 0
local nonMeleeCounter   = 0
local battleStartTime   = 0
local enteredCombat     = false
local leftCombatTime    = 0
local sequenceCounter   = 0
local damTable          = {}
local tableSize         = 0
local battleDuration    = 10

-- Buff Window Settings
local showPeerAAWindow  = { value = false }
local version = '3.5.1'
local BUFFS = 0
local SONGS = 1
local SORT_BY_SLOT = 0
local SORT_BY_NAME = 1
local SORT_BY_TYPE = 2
local FAV_SHOW_DISABLE      = 0
local FAV_SHOW_ONLY_ACTIVE  = 1
local FAV_SHOW_ONLY_MISSING = 2
local FAV_SHOW_BOTH         = 3

local WIDGET_SIZES = {
    [8]  = { progressBarHeight = 14, progressBarSpacing = 0, labelOffset = 18 },
    [9]  = { progressBarHeight = 15, progressBarSpacing = 2, labelOffset = 20 },
    [10] = { progressBarHeight = 16, progressBarSpacing = 3, labelOffset = 21 },
    [11] = { progressBarHeight = 18, progressBarSpacing = 4, labelOffset = 22 },
}

local FONT_SCALE = {
    { label = "Tiny",   size = 8 },
    { label = "Small",  size = 9 },
    { label = "Normal", size = 10 },
    { label = "Large",  size = 11 },
}

local COLORS_FROM_NAMES = {
    red   = ImVec4(0.7, 0.0, 0.0, 0.7),
    gray  = ImVec4(1.0, 1.0, 1.0, 0.2),
    green = ImVec4(0.2, 1.0, 0.6, 0.4),
    none  = ImVec4(0.2, 1.0, 0.6, 0.4),
    blue  = ImVec4(0.2, 0.6, 1.0, 0.4),
}

local A_SpellIcons = mq.FindTextureAnimation('A_SpellIcons')
local LightGrey    = ImVec4(1.0, 1.0, 1.0, 0.7)

-- Actor setup
local MyName = mq.TLO.Me.CleanName()
local actor_mailbox = actors.register('peer_status', function(message)
    local content = message()
    if not content then return end
    local name = content.name
    local hp = content.hp
    local zone = content.zone
    local distance = content.distance or 0
    local dps = content.dps or 0
    local aa = content.aa or 0
    if name and hp then
        local id = content.server .. "_" .. name
        peers[id] = {
            name = name,
            hp = hp,
            last_update = os.time(),
            distance = distance,
            inSameZone = (zone == mq.TLO.Zone.ShortName()),
            dps = dps,
            aa = aa,
            server = content.server,
            id = id
        }
        lastUpdateTime[id] = os.time()
    end
end)

local function publishHealthStatus()
    local currentTime = os.time()
    if os.difftime(currentTime, lastPublishTime) < PUBLISH_INTERVAL then
        return
    end
    local dps = 0
    if enteredCombat and battleStartTime > 0 then
        local dur = currentTime - battleStartTime
        dps = dur > 0 and (dmgTotalBattle + dmgTotalDS + dmgTotalNonMelee) / dur or 0
    end
    actor_mailbox:send({ mailbox = 'peer_status' }, {
        name = mq.TLO.Me.CleanName() or "Unknown",
        hp = mq.TLO.Me.PctHPs() or 0,
        zone = mq.TLO.Zone.ShortName() or "unknown",
        server = mq.TLO.EverQuest.Server() or "unknown",
        distance = 0,
        dps = dps,
        aa = mq.TLO.Me.AAPoints() or 0
    })
    lastPublishTime = currentTime
end

------------------------------------------------------
-- HELPER FUNCTIONS
------------------------------------------------------
local function safeTLO(fn, default)
    return (fn and fn() or default)
end

local function getHealthColor(percent)
    if percent < 35 then
        return ImVec4(1, 0, 0, 1)
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1)
    else
        return ImVec4(0, 1, 0, 1)
    end
end

local function cleanNumber(num, precision, percAlways)
    if num == nil then return "0" end
    if precision == nil then precision = 0 end
    if percAlways == nil then percAlways = false end
    local label = ""
    local floatNum = 0
    if num >= 1000000000 then
        floatNum = num / 1000000
        if precision == 2 then
            label = string.format("%.2f b", floatNum)
        elseif precision == 1 then
            label = string.format("%.1f b", floatNum)
        elseif precision == 0 then
            label = string.format("%.0f b", floatNum)
        end
    elseif num >= 1000000 then
        floatNum = num / 1000000
        if precision == 2 then
            label = string.format("%.2f m", floatNum)
        elseif precision == 1 then
            label = string.format("%.1f m", floatNum)
        elseif precision == 0 then
            label = string.format("%.0f m", floatNum)
        end
    elseif num >= 1000 then
        floatNum = num / 1000
        if precision == 2 then
            label = string.format("%.2f k", floatNum)
        elseif precision == 1 then
            label = string.format("%.1f k", floatNum)
        else
            label = string.format("%.0f k", floatNum)
        end
    else
        if not percAlways then
            label = string.format("%.0f", num)
        else
            if precision == 2 then
                label = string.format("%.2f", num)
            elseif precision == 1 then
                label = string.format("%.1f", num)
            else
                label = string.format("%.0f", num)
            end
        end
    end
    return label
end

------------------------------------------------------
-- DPS TRACKING
------------------------------------------------------
local function parseCurrentBattle(dur)
    if not enteredCombat then return end
    if dur > 0 then
        local totalDmg = dmgTotalBattle + dmgTotalDS + dmgTotalNonMelee
        local dps = dur > 0 and (totalDmg / dur) or 0
        local my_id = (mq.TLO.EverQuest.Server() or "unknown") .. "_" .. (mq.TLO.Me.CleanName() or "Unknown")
        if peers[my_id] then
            peers[my_id].dps = dps
        end
    end
end

local function meleeCallBack(line, dType, target, dmg)
    if string.find(line, "have been healed") then return end
    local type = dType or nil
    if type == nil then return end
    if not enteredCombat then
        enteredCombat = true
        dmgBattCounter = 0
        dmgTotalBattle = 0
        critTotalBattle = 0
        critHealsTotal = 0
        dmgTotalDS = 0
        dsCounter = 0
        dmgTotalNonMelee = 0
        nonMeleeCounter = 0
        battleStartTime = os.time()
        leftCombatTime = 0
    end
    if dmg == nil then
        dmg = 'MISSED'
        type = 'miss'
    end
    dmgTotalBattle = dmgTotalBattle + (tonumber(dmg) or 0)
    dmgBattCounter = dmgBattCounter + 1
    if type == 'miss' then target = 'YOU' end
    sequenceCounter = sequenceCounter + 1
    table.insert(damTable, {
        type = type,
        target = target,
        damage = dmg,
        timestamp = os.time(),
        sequence = sequenceCounter,
    })
    tableSize = tableSize + 1
    parseCurrentBattle(os.time() - battleStartTime)
end

local function critCallBack(line, dmg)
    if not tonumber(dmg) then return end
    if not enteredCombat then
        enteredCombat = true
        dmgBattCounter = 0
        dmgTotalBattle = 0
        critTotalBattle = 0
        critHealsTotal = 0
        dmgTotalDS = 0
        dsCounter = 0
        dmgTotalNonMelee = 0
        nonMeleeCounter = 0
        battleStartTime = os.time()
        leftCombatTime = 0
    end
    critTotalBattle = critTotalBattle + (tonumber(dmg) or 0)
    sequenceCounter = sequenceCounter + 1
    table.insert(damTable, {
        type = "crit",
        target = mq.TLO.Target.CleanName(),
        damage = string.format("CRIT <%d>", dmg),
        timestamp = os.time(),
        sequence = sequenceCounter,
    })
    tableSize = tableSize + 1
    parseCurrentBattle(os.time() - battleStartTime)
end

local function critHealCallBack(line, dmg)
    if not tonumber(dmg) then return end
    if not enteredCombat then
        enteredCombat = true
        battleStartTime = os.time()
        leftCombatTime = 0
        dmgBattCounter = 0
        dmgTotalBattle = 0
        critTotalBattle = 0
        critHealsTotal = 0
        dmgTotalDS = 0
        dsCounter = 0
        dmgTotalNonMelee = 0
        nonMeleeCounter = 0
    end
    critHealsTotal = critHealsTotal + (tonumber(dmg) or 0)
    sequenceCounter = sequenceCounter + 1
    table.insert(damTable, {
        type = "critHeals",
        target = "You",
        damage = string.format("CRIT_HEAL <%d>", dmg),
        timestamp = os.time(),
        sequence = sequenceCounter,
    })
    tableSize = tableSize + 1
    parseCurrentBattle(os.time() - battleStartTime)
end

local function nonMeleeCallBack(line, target, dmg)
    if not tonumber(dmg) then return end
    if not enteredCombat then
        enteredCombat = true
        dmgBattCounter = 0
        critHealsTotal = 0
        critTotalBattle = 0
        dmgTotalBattle = 0
        dmgTotalDS = 0
        dsCounter = 0
        dmgTotalNonMelee = 0
        nonMeleeCounter = 0
        battleStartTime = os.time()
        leftCombatTime = 0
    end
    local type = "non-melee"
    if target == nil then
        target = 'YOU'
        type = "hit-by-non-melee"
    end
    if string.find(line, "was hit") then
        target = string.sub(line, 1, string.find(line, "was") - 2)
        type = "dShield"
    end
    if type == 'dShield' then
        dmgTotalDS = dmgTotalDS + (tonumber(dmg) or 0)
        dsCounter = dsCounter + 1
    else
        dmgTotalNonMelee = dmgTotalNonMelee + (tonumber(dmg) or 0)
        nonMeleeCounter = nonMeleeCounter + 1
    end
    sequenceCounter = sequenceCounter + 1
    table.insert(damTable, {
        type = type,
        target = target,
        damage = dmg,
        timestamp = os.time(),
        sequence = sequenceCounter,
    })
    tableSize = tableSize + 1
    parseCurrentBattle(os.time() - battleStartTime)
end

local function cleanTable()
    if tableSize > 0 then
        local currentTime = os.time()
        local i = 1
        while i <= tableSize do
            if currentTime - damTable[i].timestamp > 10 then
                table.remove(damTable, i)
                tableSize = tableSize - 1
            else
                i = i + 1
            end
        end
    end
end

------------------------------------------------------
-- SWITCHER FUNCTIONS
------------------------------------------------------
local function switchTo(name)
    if name and type(name) == 'string' then
        mq.cmdf('/dex %s /foreground', name)
    end
end

local function targetCharacter(name)
    if name and type(name) == 'string' then
        mq.cmdf('/target pc %s', name)
    end
end

local function cleanupPeers()
    local currentTime = os.time()
    for id, data in pairs(peers) do
        if os.difftime(currentTime, data.last_update) > staleDataTimeout then
            peers[id] = nil
            lastUpdateTime[id] = nil
        end
    end
end

local function refreshPeers()
    local new_peer_list = {}
    local currentTime = os.time()
    local myID = mq.TLO.Me.ID()
    local myZone = mq.TLO.Zone.ShortName()
    for id, data in pairs(peers) do
        if os.difftime(currentTime, data.last_update) <= staleDataTimeout then
            local spawn = mq.TLO.Spawn(string.format("pc =%s", data.name))
            if spawn() and spawn.ID() and spawn.ID() ~= myID and data.inSameZone then
                data.distance = spawn.Distance3D() or 0
            else
                data.distance = 0
            end
            table.insert(new_peer_list, data)
        end
    end
    peer_list = new_peer_list
    cleanupPeers()
end

local function show_Peers()
    if sort_mode == "Alphabetical" then
        table.sort(peer_list, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    local column_count = (show_name and 1 or 0) + (show_hp and 1 or 0) + (show_distance and 1 or 0) + (show_dps and 1 or 0)
    if imgui.BeginTable("##PeerTable", column_count, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders)) then
        if show_name then imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch) end
        if show_hp then imgui.TableSetupColumn("HP (%)", ImGuiTableColumnFlags.WidthFixed, 50) end
        if show_distance then imgui.TableSetupColumn("Distance", ImGuiTableColumnFlags.WidthFixed, 60) end
        if show_dps then imgui.TableSetupColumn("DPS", ImGuiTableColumnFlags.WidthFixed, 60) end
        imgui.TableHeadersRow()
        for _, peer in ipairs(peer_list) do
            imgui.TableNextRow()
            if show_name then
                imgui.TableNextColumn()
                local zoneColor = peer.inSameZone and ImVec4(0, 1, 0, 1) or ImVec4(1, 0, 0, 1)
                imgui.PushStyleColor(ImGuiCol.Text, zoneColor)
                if imgui.Selectable(peer.name) then switchTo(peer.name) end
                if imgui.IsItemClicked(ImGuiMouseButton.Right) then targetCharacter(peer.name) end
                if imgui.IsItemHovered() then
                    imgui.BeginTooltip()
                    imgui.Text("Left-click to switch. Right-click to target.")
                    imgui.EndTooltip()
                end
                imgui.PopStyleColor()
            end
            if show_hp then
                imgui.TableNextColumn()
                local hpColor = getHealthColor(peer.hp or 0)
                imgui.PushStyleColor(ImGuiCol.Text, hpColor)
                imgui.Text(string.format("%.0f%%", peer.hp or 0))
                imgui.PopStyleColor()
            end
            if show_distance then
                imgui.TableNextColumn()
                local distance = peer.distance or 0
                local distColor = distance < 100 and ImVec4(0, 1, 0, 1)
                               or distance < 175 and ImVec4(1, 0.5, 0, 1)
                               or ImVec4(1, 0, 0, 1)
                imgui.PushStyleColor(ImGuiCol.Text, distColor)
                imgui.Text(string.format("%.1f", distance))
                imgui.PopStyleColor()
            end
            if show_dps then
                imgui.TableNextColumn()
                imgui.PushStyleColor(ImGuiCol.Text, ImVec4(1, 1, 1, 1))
                imgui.Text(cleanNumber(peer.dps, 1, true))
                imgui.PopStyleColor()
            end
        end
        imgui.EndTable()
    end
end

------------------------------------------------------
-- PLAYER STATS
------------------------------------------------------
local function DrawPlayerStats()
    local name = safeTLO(mq.TLO.Me.CleanName, "Unknown")
    local level = safeTLO(mq.TLO.Me.Level, 0)
    local hp = safeTLO(mq.TLO.Me.HP, 0)
    local max_hp = safeTLO(mq.TLO.Me.MaxHP, 0)
    local pct_hp = safeTLO(mq.TLO.Me.PctHPs, 0)
    local mana = safeTLO(mq.TLO.Me.CurrentMana, 0)
    local max_mana = safeTLO(mq.TLO.Me.MaxMana, 0)
    local pct_mana = safeTLO(mq.TLO.Me.PctMana, 0)
    local endurance = safeTLO(mq.TLO.Me.Endurance, 0)
    local max_endurance = safeTLO(mq.TLO.Me.MaxEndurance, 0)
    local pct_endurance = (max_endurance > 0) and (endurance / max_endurance * 100) or 0
    imgui.TextColored(ImVec4(1, 1, 0, 1), string.format("Name: %s", name))
    imgui.Text(string.format("Level: %d", level))
    imgui.SameLine(120)
    imgui.Text(string.format("HP: %.0f%%", pct_hp))
    if max_mana > 0 then
        imgui.TextColored(ImVec4(1, 0.5, 0, 1), string.format("Mana: %d%%", pct_mana))
    else
        imgui.TextColored(ImVec4(1, 0.5, 0, 1), "Mana: N/A")
    end
    imgui.SameLine(120)
    imgui.Text(string.format("Endurance: %.0f%%", pct_endurance))
end

------------------------------------------------------
-- BUFF WINDOW
------------------------------------------------------
local DEFAULT_SETTINGS = {
    buffWindow = {
        alpha     = 70,
        title     = true,
        locked    = false,
        sizeX     = 176,
        sizeY     = 890,
        posX      = 236,
        posY      = 60,
        favShow   = 3,
        hide      = false,
        sortBy    = SORT_BY_SLOT,
        favorites = {},
    },
    songWindow = {
        alpha     = 70,
        title     = true,
        locked    = false,
        sizeX     = 176,
        sizeY     = 650,
        posX      = 60,
        posY      = 60,
        favShow   = 3,
        hide      = false,
        sortBy    = SORT_BY_SLOT,
        favorites = {},
    },
    font = 10,
    showDebugWindow = false,
}

local function MakeDefaults() return utils.deepcopy(DEFAULT_SETTINGS) end
local function GetSettingsFilename() return string.format("Alphabuff_%s.lua", mq.TLO.Me.Name()) end
local function SaveSettings() mq.pickle(GetSettingsFilename(), settings) end

local function LoadSettings()
    local configData, err = loadfile(mq.configDir .. '/'.. GetSettingsFilename())
    local settings
    if err then
        settings = MakeDefaults()
        print('\at[Alphabuff]\aw Creating config file...')
    elseif configData then
        print('\at[Alphabuff]\aw Loading config file...')
        local conf = configData()
        if type(conf) ~= 'table' then conf = {} end
        if conf.settings ~= nil then
            local oldSettings = conf.settings
            settings = MakeDefaults()
            settings.buffWindow.alpha   = oldSettings.alphaB
            settings.buffWindow.title   = oldSettings.titleB
            settings.buffWindow.locked  = oldSettings.lockedB
            settings.buffWindow.sizeX   = oldSettings.sizeBX
            settings.buffWindow.sizeY   = oldSettings.sizeBY
            settings.buffWindow.posX    = oldSettings.posBX
            settings.buffWindow.posY    = oldSettings.posBY
            settings.buffWindow.favShow = oldSettings.favBShow
            settings.buffWindow.hide    = oldSettings.hideB
            settings.buffWindow.favorites = conf.favbuffs
            settings.songWindow.alpha   = oldSettings.alphaS
            settings.songWindow.title   = oldSettings.titleS
            settings.songWindow.locked  = oldSettings.lockedS
            settings.songWindow.sizeX   = oldSettings.sizeSX
            settings.songWindow.sizeY   = oldSettings.sizeSY
            settings.songWindow.posX    = oldSettings.posSX
            settings.songWindow.posY    = oldSettings.posSY
            settings.songWindow.favShow = oldSettings.favSShow
            settings.songWindow.hide    = oldSettings.hideS
            settings.songWindow.favorites = conf.favsongs
            settings.font = oldSettings.font
        else
            settings = conf
        end
        if type(settings.font) ~= 'number' or settings.font < 8 or settings.font > 11 then
            settings.font = DEFAULT_SETTINGS.font
        end
        if type(settings.showDebugWindow) ~= 'boolean' then
            settings.showDebugWindow = DEFAULT_SETTINGS.showDebugWindow
        end
        for _, window in ipairs({"buffWindow", "songWindow"}) do
            local src = DEFAULT_SETTINGS[window]
            if settings[window] == nil then
                settings[window] = {}
            end
            local dst = settings[window]
            for k, v in pairs(src) do
                if dst[k] == nil or type(dst[k]) ~= type(v) then
                    dst[k] = v
                end
            end
        end
    end
    return settings
end

local settings = LoadSettings()
SaveSettings()

local BuffItem = {}
BuffItem.__index   = BuffItem
BuffItem.name      = nil
BuffItem.denom     = 0
BuffItem.favorite  = false
BuffItem.valid     = false
BuffItem.remaining = 0
BuffItem.duration  = 0
BuffItem.hitCount  = 0
BuffItem.spellIcon = nil
BuffItem.ratio     = 0
BuffItem.barColor  = 'none'

function BuffItem.new(slot, type)
    local newItem = setmetatable({}, BuffItem)
    newItem.slot = slot
    newItem.type = type
    newItem.buff = newItem:_GetSpell()
    newItem.valid = false
    newItem:Update()
    return newItem
end

function BuffItem:Update()
    local changed = false
    local name = self.buff.Name()
    if name ~= self.name then
        self.valid = (name ~= nil)
        self.name  = name
        self.duration  = self:_GetDuration()
        self.remaining = self:_GetRemaining()
        self.denom     = math.max(self.duration, self.remaining)
        self.hitCount  = self.buff.HitCount()
        self.spellIcon = self.buff.SpellIcon()
        self.barColor  = self:_GetBarColor()
        self.ratio     = self:_CalcRatio()
        self.favorite  = false
        changed = true
    else
        local remaining = self:_GetRemaining()
        if remaining ~= self.remaining then
            self.remaining = remaining
            self.duration  = self:_GetDuration()
            self.denom     = math.max(self.duration, self.remaining)
            self.barColor  = self:_GetBarColor()
            self.ratio     = self:_CalcRatio()
            changed = true
        end
        local hitCount = self.buff.HitCount() or 0
        if hitCount ~= self.hitCount then
            self.hitCount = hitCount
            changed = true
        end
    end
    return changed
end

function BuffItem:_GetSpell()
    if self.type == BUFFS then
        return mq.TLO.Me.Buff(self.slot)
    else
        return mq.TLO.Me.Song(self.slot)
    end
end

function BuffItem:_GetRemaining()
    local remaining = self.buff.Duration() or 0
    remaining = remaining / 1000
    local trunc = tonumber(string.format("%.0f", remaining))
    return trunc or 0
end

function BuffItem:_GetDuration()
    return self.buff.MyDuration.TotalSeconds() or 0
end

function BuffItem:_GetBarColor()
    if self.buff.SpellType() == 'Detrimental' then
        return 'red'
    end
    if self.duration < 0 or self.duration > 36000 then
        return 'gray'
    end
    if self.duration > 0 and self.duration < 1200 then
        return 'green'
    end
    if self.duration == 0 then
        return 'none'
    end
    return 'blue'
end

function BuffItem:_CalcRatio()
    if self.barColor == 'gray' then
        return 1
    end
    if self.barColor == 'green' or self.barColor == 'red' then
        return self.remaining / self.denom
    end
    if self.barColor == 'blue' then
        local remaining = self.remaining / 60
        if remaining >= 20 then
            return 1
        end
        return remaining / 20
    end
    return 0
end

function BuffItem:DrawIcon()
    if self.spellIcon ~= nil then
        A_SpellIcons:SetTextureCell(self.spellIcon)
        imgui.DrawTextureAnimation(A_SpellIcons, 17, 17)
    end
end

local BuffWindow = {}
BuffWindow.__index = BuffWindow

function BuffWindow.new(title, type, windowSettings, maxBuffs)
    local newWindow = setmetatable({}, BuffWindow)
    local toon   = mq.TLO.Me.Name() or ''
    local server = mq.TLO.EverQuest.Server() or ''
    newWindow.title  = string.format("%s##%s_%s", title, server, toon)
    newWindow.type   = type
    newWindow.settings = windowSettings
    newWindow.favorites = windowSettings.favorites
    newWindow.alphaSliderChanged = false
    newWindow.onLoad = true
    newWindow.open   = true
    newWindow.show   = true
    newWindow.windowFlags = newWindow:CalculateWindowFlags()
    newWindow.maxBuffs = maxBuffs or 15
    newWindow.favoritesMap = {}
    for index, favorite in ipairs(newWindow.favorites) do
        newWindow.favoritesMap[favorite] = index
    end
    newWindow:LoadBuffs()
    return newWindow
end

function BuffWindow:CalculateWindowFlags()
    local windowFlags = bit32.bor(
        ImGuiWindowFlags.NoFocusOnAppearing,
        (not self.settings.title) and ImGuiWindowFlags.NoTitleBar or 0,
        self.settings.locked and bit32.bor(ImGuiWindowFlags.NoMove, ImGuiWindowFlags.NoResize) or 0
    )
    return windowFlags
end

function BuffWindow:LoadBuffs()
    self.buffs = {}
    for i = 1, self.maxBuffs do
        local newBuff = BuffItem.new(i, self.type)
        if newBuff.valid then
            newBuff.favorite = self.favoritesMap[newBuff.name] ~= nil
        end
        table.insert(self.buffs, newBuff)
    end
end

function BuffWindow:UpdateBuffs()
    local buffsChanged = false
    for _, item in ipairs(self.buffs) do
        if item:Update() then
            if item.name ~= nil then
                item.favorite = self.favoritesMap[item.name] ~= nil
            else
                item.favorite = false
            end
            buffsChanged = true
        end
    end
    if buffsChanged then
        self:SortBuffs()
    end
end

function BuffWindow:SortBuffs()
    if self.settings.sortBy == SORT_BY_NAME then
        table.sort(self.buffs, function(a, b)
            if a.name == b.name then return a.slot - b.slot < 0 end
            if a.name == nil then return false end
            if b.name == nil then return true end
            local delta = 0
            if a.name < b.name then
                delta = -1
            elseif b.name < a.name then
                delta = 1
            end
            if delta == 0 then
                delta = a.slot - b.slot
            end
            return delta < 0
        end)
    elseif self.settings.sortBy == SORT_BY_SLOT then
        table.sort(self.buffs, function(a, b) return a.slot - b.slot < 0 end)
    end
end

function BuffWindow:SetSortMethod(sortBy)
    self.settings.sortBy = sortBy
    self:SortBuffs()
end

function BuffWindow:MoveFavoriteUp(name)
    local index = self.favoritesMap[name]
    if index == nil or index <= 1 then return end
    local newIndex = index - 1
    self.favoritesMap[self.favorites[newIndex]] = index
    self.favoritesMap[name] = newIndex
    table.remove(self.favorites, index)
    table.insert(self.favorites, newIndex, name)
    SaveSettings()
end

function BuffWindow:MoveFavoriteDown(name)
    local index = self.favoritesMap[name]
    if index == nil or index >= #self.favorites then return end
    local newIndex = index + 1
    self.favoritesMap[self.favorites[newIndex]] = index
    self.favoritesMap[name] = newIndex
    table.remove(self.favorites, index)
    table.insert(self.favorites, newIndex, name)
    SaveSettings()
end

function BuffWindow:AddFavorite(name)
    if self.favoritesMap[name] ~= nil then return end
    table.insert(self.favorites, name)
    self.favoritesMap[name] = #self.favorites
    for _, item in ipairs(self.buffs) do
        if item.name == name then
            item.favorite = true
        end
    end
    SaveSettings()
end

function BuffWindow:RemoveFavorite(name)
    local index = self.favoritesMap[name]
    if index == nil then return end
    table.remove(self.favorites, index)
    self.favoritesMap[name] = nil
    for i = index, #self.favorites do
        self.favoritesMap[self.favorites[i]] = i
    end
    for _, item in ipairs(self.buffs) do
        if item.name == name then
            item.favorite = false
        end
    end
    SaveSettings()
end

function BuffWindow:DrawSpellContextMenu(item)
    imgui.SetWindowFontScale(1)
    if imgui.BeginPopupContextItem('BuffContextMenu') then
        if item.favorite then
            imgui.BeginDisabled(self.favoritesMap[item.name] <= 1)
            if imgui.Selectable(string.format('%s Move up', icons.FA_CHEVRON_UP)) then self:MoveFavoriteUp(item.name) end
            imgui.EndDisabled()
            imgui.BeginDisabled(self.favoritesMap[item.name] >= #self.favorites)
            if imgui.Selectable(string.format('%s Move down', icons.FA_CHEVRON_DOWN)) then self:MoveFavoriteDown(item.name) end
            imgui.EndDisabled()
            imgui.Separator()
            if imgui.Selectable(string.format('%s Unfavorite', icons.FA_HEART_O)) then
                self:RemoveFavorite(item.name)
            end
            imgui.Separator()
        else
            if imgui.Selectable(string.format('%s Favorite', icons.MD_FAVORITE)) then
                self:AddFavorite(item.name)
            end
            imgui.Separator()
        end
        if imgui.Selectable(string.format('%s Inspect', icons.MD_SEARCH)) then
            item.buff.Inspect()
        end
        if imgui.Selectable(string.format('%s Remove', icons.MD_DELETE)) then
            mq.cmdf('/removebuff %s', item.name)
        end
        imgui.Separator()
        if imgui.Selectable(string.format('%s Block spell', icons.MD_CLOSE)) then
            mq.cmdf('/blockspell add me %s', item.buff.ID())
        end
        imgui.EndPopup()
    end
    imgui.SetWindowFontScale(settings.font / 10)
end

function BuffWindow:DrawPlaceholderContextMenu(name)
    imgui.SetWindowFontScale(1)
    if imgui.BeginPopupContextItem('BuffContextMenuPlaceholder') then
        imgui.BeginDisabled(self.favoritesMap[name] <= 1)
        if imgui.Selectable(string.format('%s Move up', icons.FA_CHEVRON_UP)) then self:MoveFavoriteUp(name) end
        imgui.EndDisabled()
        imgui.BeginDisabled(self.favoritesMap[name] >= #self.favorites)
        if imgui.Selectable(string.format('%s Move down', icons.FA_CHEVRON_DOWN)) then self:MoveFavoriteDown(name) end
        imgui.EndDisabled()
        imgui.Separator()
        if imgui.Selectable(string.format('%s Inspect', icons.MD_SEARCH)) then
            mq.TLO.Spell(name).Inspect()
        end
        imgui.Separator()
        if imgui.Selectable(string.format('%s Unfavorite', icons.FA_HEART_O)) then self:RemoveFavorite(name) end
        imgui.EndPopup()
    end
    imgui.SetWindowFontScale(settings.font / 10)
end

function BuffWindow:DrawBuffRow(item)
    local widgetSizes = WIDGET_SIZES[settings.font]
    imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 1, widgetSizes.progressBarSpacing)
    imgui.PushID(item.slot)
    if item.valid then
        local hitCountStr = ''
        if item.hitCount ~= 0 then
            hitCountStr = string.format('[%s] ', item.hitCount)
        end
        imgui.BeginGroup()
            item:DrawIcon()
            imgui.SameLine()
            imgui.PushStyleColor(ImGuiCol.PlotHistogram, COLORS_FROM_NAMES[item.barColor])
                imgui.ProgressBar(item.ratio, imgui.GetContentRegionAvail(), widgetSizes.progressBarHeight, "")
                imgui.SetCursorPosY(imgui.GetCursorPosY() - widgetSizes.labelOffset)
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 20)
                imgui.Text("%s%s", hitCountStr, item.name)
            imgui.PopStyleColor()
        imgui.EndGroup()
        imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8, 8)
            self:DrawSpellContextMenu(item)
        imgui.PopStyleVar()
        if imgui.IsItemClicked(ImGuiMouseButton.Left) then
            mq.cmdf('/removebuff %s', item.name)
        end
        if imgui.IsItemHovered() and item.valid then
            local hms
            if item.barColor == 'gray' then
                hms = 'Permanent'
            else
                hms = item.buff.Duration.TimeHMS() or 0
            end
            imgui.SetTooltip("%02d %s%s (%s)", item.slot, hitCountStr, item.name, hms)
        end
    else
        imgui.TextColored(ImVec4(1, 1, 1, .5), "%02d", item.slot)
    end
    imgui.PopID()
    imgui.PopStyleVar()
end

function BuffWindow:DrawPlaceholderRow(name)
    local widgetSizes = WIDGET_SIZES[settings.font]
    imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 1, widgetSizes.progressBarSpacing)
    imgui.PushID(name)
        imgui.BeginGroup()
            local spellIcon = mq.TLO.Spell(name).SpellIcon()
            if spellIcon ~= nil then
                A_SpellIcons:SetTextureCell(spellIcon)
            end
            imgui.DrawTextureAnimation(A_SpellIcons, 17, 17)
            imgui.SameLine()
            imgui.ProgressBar(0, imgui.GetContentRegionAvail(), widgetSizes.progressBarHeight, "")
            imgui.SetCursorPosY(imgui.GetCursorPosY() - widgetSizes.labelOffset)
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 20)
            imgui.TextColored(1, 1, 1, .3, name)
            imgui.SetCursorPosY(imgui.GetCursorPosY() - 19)
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 1)
            imgui.TextColored(.5, .5, .5, .5, icons.MD_INDETERMINATE_CHECK_BOX)
        imgui.EndGroup()
        imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8, 8)
            self:DrawPlaceholderContextMenu(name)
        imgui.PopStyleVar()
    imgui.PopID()
    imgui.PopStyleVar()
end

function BuffWindow:DrawBuffTable(sortBy, filterColor)
    if sortBy ~= self.settings.sortBy and sortBy ~= SORT_BY_TYPE then
        self:SetSortMethod(sortBy)
    end
    for _, item in ipairs(self.buffs) do
        if not self.settings.hide or item.barColor == 'red' then
            if (not item.favorite or self.settings.favShow == FAV_SHOW_DISABLE or self.settings.favShow == FAV_SHOW_ONLY_MISSING)
                and (filterColor == nil or item.barColor == filterColor)
            then
                self:DrawBuffRow(item)
            end
        end
    end
end

function BuffWindow:GetBuffByName(name)
    for _, item in ipairs(self.buffs) do
        if item.name == name then
            return item
        end
    end
    return nil
end

function BuffWindow:DrawFavorites()
    if #self.favorites == 0 then return end
    imgui.PushID("Favorites")
    for _, favName in ipairs(self.favorites) do
        local item = self:GetBuffByName(favName)
        if item ~= nil then
            if self.settings.favShow ~= FAV_SHOW_ONLY_MISSING then
                self:DrawBuffRow(item)
            end
        else
            if self.settings.favShow ~= FAV_SHOW_ONLY_ACTIVE then
                self:DrawPlaceholderRow(favName)
            end
        end
    end
    imgui.PopID()
    imgui.Separator()
end

function BuffWindow:DrawSettingsMenu()
    imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 8, 5)
    imgui.PushStyleVar(ImGuiStyleVar.ItemInnerSpacing, 4, 0)
    if imgui.BeginPopupContextItem('Settings Menu') then
        local changed = false
        imgui.Text('Settings')
        imgui.Separator()
        self.settings.locked, changed = imgui.Checkbox('Lock window', self.settings.locked)
        if changed then
            self.windowFlags = self:CalculateWindowFlags()
            SaveSettings()
        end
        self.settings.title, changed = imgui.Checkbox('Show title bar', self.settings.title)
        if changed then
            self.windowFlags = self:CalculateWindowFlags()
            SaveSettings()
        end
        imgui.SetNextItemWidth(100)
        self.settings.alpha, changed = imgui.SliderInt('Alpha', self.settings.alpha, 0, 100)
        if changed then
            self.alphaSliderChanged = true
        end
        if self.alphaSliderChanged and imgui.IsMouseReleased(ImGuiMouseButton.Left) then
            self.alphaSliderChanged = false
            SaveSettings()
        end
        imgui.Separator()
        if imgui.BeginMenu("Font Scale") then
            for _, v in ipairs(FONT_SCALE) do
                local checked = settings.font == v.size
                if imgui.MenuItem(v.label, nil, checked) then
                    settings.font = v.size
                    SaveSettings()
                    break
                end
            end
            imgui.EndMenu()
        end
        imgui.Separator()
        imgui.Text('Favorites')
        self.settings.favShow, changed = imgui.RadioButton('Disable', self.settings.favShow, FAV_SHOW_DISABLE)
        if changed then SaveSettings() end
        self.settings.favShow, changed = imgui.RadioButton('Only active', self.settings.favShow, FAV_SHOW_ONLY_ACTIVE)
        if changed then SaveSettings() end
        self.settings.favShow, changed = imgui.RadioButton('Only missing', self.settings.favShow, FAV_SHOW_ONLY_MISSING)
        if changed then SaveSettings() end
        self.settings.favShow, changed = imgui.RadioButton('Show both', self.settings.favShow, FAV_SHOW_BOTH)
        if changed then SaveSettings() end
        imgui.Separator()
        self.settings.hide, changed = imgui.Checkbox('Hide non-favorites', self.settings.hide)
        if changed then SaveSettings() end
        imgui.EndPopup()
    end
    imgui.PopStyleVar(2)
end

function BuffWindow:DrawTabs()
    imgui.SetWindowFontScale(settings.font / 10)
    if imgui.BeginTabBar('sortbar') then
        local sortMethod = self.settings.sortBy
        if imgui.BeginTabItem('Slot') then
            sortMethod = SORT_BY_SLOT
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Name') then
            sortMethod = SORT_BY_NAME
            imgui.EndTabItem()
        end
        if imgui.BeginTabItem('Type') then
            sortMethod = SORT_BY_TYPE
            imgui.EndTabItem()
        end
        if self.settings.favShow ~= FAV_SHOW_DISABLE then
            imgui.PushStyleVar(ImGuiStyleVar.ItemSpacing, 1, 7)
                self:DrawFavorites()
            imgui.PopStyleVar()
        end
        if sortMethod ~= SORT_BY_TYPE then
            self:DrawBuffTable(sortMethod)
        else
            self:DrawBuffTable(sortMethod, 'gray')
            self:DrawBuffTable(sortMethod, 'blue')
            self:DrawBuffTable(sortMethod, 'green')
            self:DrawBuffTable(sortMethod, 'red')
            self:DrawBuffTable(sortMethod, 'none')
        end
        imgui.EndTabBar()
    end
    imgui.SetWindowFontScale(1)
end

------------------------------------------------------
-- COMBINED UI WINDOW
------------------------------------------------------
local function CombinedUI()
    if not combinedUIInitialized then
        imgui.SetNextWindowSize(ImVec2(600, 700))
        combinedUIInitialized = true
    end
    if imgui.Begin("Player & Switcher", combinedUIOpen) then
        if imgui.BeginMenuBar() then
            if imgui.BeginMenu("Switcher Options") then
                if imgui.MenuItem("Show Name", nil, show_name) then show_name = not show_name end
                if imgui.MenuItem("Show HP (%)", nil, show_hp) then show_hp = not show_hp end
                if imgui.MenuItem("Show Distance", nil, show_distance) then show_distance = not show_distance end
                if imgui.MenuItem("Show DPS", nil, show_dps) then show_dps = not show_dps end
                imgui.EndMenu()
            end
            if imgui.BeginMenu("Sort") then
                if imgui.MenuItem("Alphabetical", nil, sort_mode == "Alphabetical") then sort_mode = "Alphabetical" end
                imgui.EndMenu()
            end
            imgui.EndMenuBar()
        end
        DrawPlayerStats()
        imgui.Separator()
        imgui.Spacing()
        local peerCount = #peer_list
        imgui.TextColored(ImVec4(0.2, 0.7, 1, 1), string.format("Switcher (%d)", peerCount))
        imgui.SameLine()
        local myAAPoints = mq.TLO.Me.AAPoints() or 0
        imgui.TextColored(ImVec4(0.2, 0.7, 1, 1), string.format("AA: %d", myAAPoints))
        if imgui.IsItemClicked() then
            showPeerAAWindow.value = not showPeerAAWindow.value
        end
        imgui.Separator()
        if peerCount ~= lastPeerCount then
            lastPeerCount = peerCount
            local peerRowHeight = 20
            local extraHeight = 38
            cachedPeerHeight = math.min((peerCount * peerRowHeight) + extraHeight, 750)
        end
        if imgui.BeginChild("PeerListChild", ImVec2(0, cachedPeerHeight), true) then
            show_Peers()
        end
        imgui.EndChild()
        imgui.Separator()
        imgui.Spacing()
        imgui.Text("Buff Display")
        if imgui.BeginChild("BuffDisplaySection", ImVec2(0, 550)) then
            buffWindow:DrawTabs()
        end
        imgui.EndChild()
    end
    imgui.End()
    if showPeerAAWindow.value then
        local open = showPeerAAWindow.value
        if imgui.Begin("Peer AA Counts", open, ImGuiWindowFlags.AlwaysAutoResize) then
            if imgui.Button("Close") then
                showPeerAAWindow.value = false
            end
            table.sort(peer_list, function(a, b) return a.name:lower() < b.name:lower() end)
            if imgui.BeginTable("PeerAA", 2, ImGuiTableFlags.Borders) then
                imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
                imgui.TableSetupColumn("AA Points", ImGuiTableColumnFlags.WidthFixed, 80)
                imgui.TableHeadersRow()
                for _, peer in ipairs(peer_list) do
                    imgui.TableNextRow()
                    imgui.TableNextColumn()
                    imgui.Text(peer.name or "Unknown")
                    imgui.TableNextColumn()
                    imgui.Text(tostring(peer.aa or 0))
                end
                imgui.EndTable()
            end
        end
        imgui.End()
        if not open then
            showPeerAAWindow.value = false
        end
    end
end

------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------
local MyName = mq.TLO.Me.CleanName()
mq.event("melee_crit", "#*#You score a critical hit! #*#(#1#)", critCallBack)
mq.event("melee_crit2", "#*#You deliver a critical blast! #*#(#1#)", critCallBack)
mq.event("melee_crit3", string.format("#*#%s scores a critical hit! #*#(#1#)", MyName), critCallBack)
mq.event("melee_deadly_strike", string.format("#*#%s scores a Deadly Strike! #*#(#1#)", MyName), critCallBack)
mq.event("melee_do_damage", "#*#You #1# #2# for #3# points of damage#*#", meleeCallBack)
mq.event("melee_miss", "#*#You try to #1# #2#, but miss#*#", meleeCallBack)
mq.event("melee_non_melee", string.format("#*#%s hit #1# for #2# points of non-melee damage#*#", MyName), nonMeleeCallBack)
mq.event("melee_damage_shield", "#*# was hit by non-melee for #2# points of damage#*#", nonMeleeCallBack)
mq.event("melee_you_hit_non-melee", "#*#You were hit by non-melee for #2# damage#*#", nonMeleeCallBack)
mq.event("melee_crit_heal", "#*#You perform an exceptional heal! #*#(#1#)", critHealCallBack)

buffWindow = BuffWindow.new("Alphabuff", BUFFS, settings.buffWindow, mq.TLO.Me.MaxBuffSlots())
mq.imgui.init("CombinedUI", CombinedUI)

------------------------------------------------------
-- MAIN EVENT LOOP
------------------------------------------------------
while mq.TLO.MacroQuest.GameState() == "INGAME" do
    local currentTime = os.time()
    publishHealthStatus()
    refreshPeers()
    buffWindow:UpdateBuffs()
    if mq.TLO.Me.CombatState() ~= 'COMBAT' and enteredCombat then
        if leftCombatTime == 0 then
            leftCombatTime = os.time()
        end
        local endOfCombat = os.time() - leftCombatTime
        if endOfCombat > battleDuration then
            enteredCombat = false
            battleStartTime = 0
            leftCombatTime = 0
            dmgTotalBattle = 0
            dmgBattCounter = 0
            critTotalBattle = 0
            critHealsTotal = 0
            dmgTotalDS = 0
            dsCounter = 0
            dmgTotalNonMelee = 0
            nonMeleeCounter = 0
        end
    end
    cleanTable()
    if battleStartTime > 0 then
        parseCurrentBattle(currentTime - battleStartTime)
    end
    mq.doevents()
    mq.delay(refreshInterval)
end