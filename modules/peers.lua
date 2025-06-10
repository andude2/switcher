-- peers.lua
-- Handles peer status, DPS tracking, and switching logic
-- Enhanced with traditional group window display option

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local utils = require('switcher.modules.utils')
local json = require('dkjson')
local config = {}
local config_path = string.format('%s/peer_ui_config.json', mq.configDir)
local myName = mq.TLO.Me.CleanName() or "Unknown"

local M = {} -- Module table
local aa_said = false

-- Configuration
local REFRESH_INTERVAL_MS = 50 -- How often to run the update loop (in ms)
local PUBLISH_INTERVAL_S  = 0.5 -- How often to publish own status (in seconds)
local STALE_DATA_TIMEOUT_S= 30  -- How long before peer data is considered stale (in seconds)
local BATTLE_DURATION_S   = 5  -- How long after combat ends before DPS resets (in seconds)

-- State Variables
M.peers      = {}       -- Stores data received from other peers [id] = {data}
M.peer_list  = {}       -- Filtered and processed list of peers for display
M.options = {           -- Options controlled by the main UI menu
    sort_mode   = "Alphabetical", -- or "HP", "Distance", "DPS" (Add sorting logic if needed)
    show_name     = true,
    show_hp       = true,
    show_mana     = true,
    show_distance = true,
    show_dps      = true,
    show_target   = true,
    show_combat   = true,
    show_casting  = true,
    borderless    = false,
    show_player_stats = true,
    use_class     = false,
    font_scale = 1.0,
    -- New options for group window
    display_style = "auto", -- "auto", "table" or "group" - changed default to auto
    group_window_threshold = 8, -- Switch to group style when <= this many peers
    show_endurance = true,
    show_pet_bars = false,
    compact_mode = false,
}
M.show_aa_window = { value = false } -- Control the visibility of the AA window

local lastPeerCount    = 0
local lastDisplayStyle = "" -- Track display style changes
local cachedPeerHeight = 150 -- Default height - reduced from 300
local lastUpdateTime   = {} -- [id] = timestamp of last message received
local lastPublishTime  = 0  -- Timestamp of last published message
local actor_mailbox    = nil
local MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
local MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")
local actualAAPoints = nil -- Stores the actual AA from chat, nil if not captured yet
local lastAACheckTime = 0  -- Timestamp of last AA check
local AA_CHECK_INTERVAL = 300 -- Check AA every 5 minutes (300 seconds)

-- DPS Tracking Variables
local dmgTotalBattle    = 0
local dmgBattCounter    = 0
local critTotalBattle   = 0
local critHealsTotal    = 0 -- Note: Crit heals aren't DPS but were tracked
local dmgTotalDS        = 0
local dsCounter         = 0
local dmgTotalNonMelee  = 0
local nonMeleeCounter   = 0
local battleStartTime   = 0 -- Timestamp combat started
local enteredCombat     = false
local leftCombatTime    = 0 -- Timestamp combat ended

-------------------------------------------
---AA Functions with Server-Specific Logic
-------------------------------------------

local function isEZLinuxServer()
    local serverName = utils.safeTLO(mq.TLO.EverQuest.Server, "")
    return serverName == "EZ (Linux) x4 Exp"
end

local function aaGainCallback(line, totalAmount)
    local cleanTotal = string.gsub(totalAmount, ",", "")  -- Remove commas
    local total = tonumber(cleanTotal)  -- Convert to number

    if total then
        actualAAPoints = total
        --print(string.format("[Peers] AA Update: Gained, now have %d total AA points", total))
    else
        print(string.format("[Peers] Warning: Could not parse AA total from: %s", totalAmount or "nil"))
    end
end

local function aaDisplayCallback(line, aaAmount)
    local cleanAmount = string.gsub(aaAmount, ",", "")
    local points = tonumber(cleanAmount)
    if points then
        actualAAPoints = points
        print(string.format("[Peers] Captured actual AA points: %s", aaAmount))
    else
        print(string.format("[Peers] Warning: Could not parse AA amount from: %s", aaAmount or "nil"))
    end
end

local function getActualAAPoints()
    if isEZLinuxServer() then
        -- Use captured AA from chat for EZ Linux server
        if actualAAPoints then
            return actualAAPoints
        end
        return utils.safeTLO(mq.TLO.Me.AAPoints, 0) -- Fallback to TLO if no chat capture yet
    else
        -- Use TLO directly for all other servers
        return utils.safeTLO(mq.TLO.Me.AAPoints, 0)
    end
end

function requestAAUpdate()
    if not isEZLinuxServer() then
        return -- Don't request AA updates on non-EZ servers
    end
    
    if M.aa_said then
        return
    end
    mq.cmd('/say AA')
    M.aa_said = true
end

local function formatNumberWithCommas(num)
    if not num or num == 0 then return "0" end
    local formatted = tostring(num)
    local k
    while true do
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", '%1,%2')
        if k == 0 then break end
    end
    return formatted
end

-- Helper: Check if class uses mana
local function classUsesMana(class)
    if not class then return true end -- Default to showing mana if unknown
    local noManaClasses = {
        "WAR", "ROG", "MNK", "BER" -- Warrior, Rogue, Monk, Berserker
    }
    for _, noManaClass in ipairs(noManaClasses) do
        if class == noManaClass then
            return false
        end
    end
    return true
end

-- Helper: Get health bar color - simple red for group view
local function getHealthColor(percent)
    return ImVec4(0.8, 0.2, 0.2, 1) -- Consistent red for group view bars
end

-- Helper: Get health text color - dynamic for table view
local function getHealthTextColor(percent)
    percent = percent or 0
    if percent < 30 then
        return ImVec4(1, 0.2, 0.2, 1) -- Red for low HP
    elseif percent <= 80 then
        return ImVec4(1, 1, 0.2, 1) -- Yellow for medium HP
    else
        return ImVec4(0.2, 1, 0.2, 1) -- Green for high HP
    end
end

-- Helper: Get mana bar color - simple blue for all mana
local function getManaColor(percent)
    return ImVec4(0.2, 0.4, 0.8, 1) -- Consistent blue for all mana levels
end

-- Helper: Get endurance bar color - simple yellow for all endurance
local function getEnduranceColor(percent)
    return ImVec4(0.8, 0.8, 0.2, 1) -- Consistent yellow for all endurance levels
end

-- Helper: Calculate current DPS
local function calculateCurrentDPS()
    if not enteredCombat or battleStartTime <= 0 then return 0 end

    local currentTime = os.time()
    local duration = currentTime - battleStartTime
    if duration <= 0 then return 0 end -- Avoid division by zero

    local totalDmg = dmgTotalBattle + dmgTotalDS + dmgTotalNonMelee
    return totalDmg / duration
end

local function publishHealthStatus()
    local currentTime = os.time()
    if os.difftime(currentTime, lastPublishTime) < PUBLISH_INTERVAL_S then
        return
    end
    if not actor_mailbox then
        print('\ar[Peers] Actor mailbox not initialized. Cannot publish status.\ax')
        return
    end
    requestAAUpdate()
    local status = {
        name = MyName,
        server = MyServer,
        hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
        mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
        endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0),
        zone = utils.safeTLO(mq.TLO.Zone.ShortName, "unknown"),
        distance = 0,
        dps = calculateCurrentDPS(),
        aa = getActualAAPoints(),
        class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "UNK"),
        level = utils.safeTLO(mq.TLO.Me.Level, 1),
        target = utils.safeTLO(mq.TLO.Target.CleanName, "None"),
        combat_state = utils.safeTLO(mq.TLO.Me.CombatState, "UNKNOWN") == "COMBAT",
        casting = utils.safeTLO(mq.TLO.Me.Casting.Name, "None")
    }
    actor_mailbox:send({ mailbox = 'peer_status' }, status)
    lastPublishTime = currentTime
end

local function peer_message_handler(message)
    local content = message()
    if not content or type(content) ~= 'table' then
        print('\ay[Peers] Received invalid or empty message\ax')
        return
    end
    --print(string.format("[Peers] Received from %s/%s: HP=%d%% DPS=%.1f Zone=%s", content.name or "?", content.server or "?", content.hp or 0, content.dps or 0, content.zone or "?"))
    if not content.name or not content.server then
        print('\ay[Peers] Missing name or server in message\ax')
        return
    end
    local id = content.server .. "_" .. content.name
    if id == MyServer .. "_" .. MyName then return end
    local currentTime = os.time()
    M.peers[id] = {
        id = id,
        name = content.name,
        server = content.server,
        hp = content.hp or 0,
        mana = content.mana or 0,
        endurance = content.endurance or 0,
        zone = content.zone or "unknown",
        dps = content.dps or 0,
        aa = content.aa or 0,
        class = content.class or "UNK",
        level = content.level or 1,
        target = content.target or "None",
        combat_state = content.combat_state or false,
        casting = content.casting or "None",
        last_update = currentTime,
        distance = 0,
        inSameZone = false
    }
    lastUpdateTime[id] = currentTime
end

-- DPS Event Callbacks
local function handleDamageEvent(dmgAmount)
    if not enteredCombat then
        enteredCombat   = true
        battleStartTime = os.time()
        leftCombatTime  = 0
        -- Reset counters
        dmgTotalBattle    = 0
        dmgBattCounter    = 0
        critTotalBattle   = 0
        critHealsTotal    = 0
        dmgTotalDS        = 0
        dsCounter         = 0
        dmgTotalNonMelee  = 0
        nonMeleeCounter   = 0
        print("[Peers] Combat started.")
    end
    -- Reset leftCombatTime if we re-enter combat quickly
    leftCombatTime = 0
    return tonumber(dmgAmount) or 0
end

local function meleeCallBack(line, dType, target, dmgStr)
    -- Ignore heals mixed into melee events if any
    if string.find(line, "have been healed") then return end
    -- Ignore misses for DPS calculation
    if string.find(line, "but miss") or string.find(line, "but misses") then return end

    local dmg = handleDamageEvent(dmgStr)
    dmgTotalBattle = dmgTotalBattle + dmg
    dmgBattCounter = dmgBattCounter + 1
end

local function critCallBack(line, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    critTotalBattle = critTotalBattle + dmg
end

local function critHealCallBack(line, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    critHealsTotal = critHealsTotal + dmg
end

local function nonMeleeCallBack(line, targetOrYou, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    local type = "non-melee"
    if string.find(line, "was hit by non-melee for") then
        type = "dShield"
        dmgTotalDS = dmgTotalDS + dmg
        dsCounter = dsCounter + 1
     -- Hit *by* non-melee (taken damage)
    elseif string.find(line, "You were hit by non-melee for") then
        type = "hit-by-non-melee"
        -- Do not add damage taken to your outgoing DPS totals
    -- Standard non-melee hit dealt by you
    else
        dmgTotalNonMelee = dmgTotalNonMelee + dmg
        nonMeleeCounter = nonMeleeCounter + 1
    end
end

-- Combat State Management
local function checkCombatState()
    local currentCombatState = utils.safeTLO(mq.TLO.Me.CombatState, "UNKNOWN")

    if currentCombatState ~= 'COMBAT' and enteredCombat then
        if leftCombatTime == 0 then
            leftCombatTime = os.time()
            --print("[Peers] Combat ended (timer started).")
        end
        if os.difftime(os.time(), leftCombatTime) > BATTLE_DURATION_S then
            --print("[Peers] Combat DPS reset.")
            enteredCombat   = false
            battleStartTime = 0
            leftCombatTime  = 0
            -- Reset totals (optional, could keep last fight stats)
            dmgTotalBattle    = 0
            dmgBattCounter    = 0
            critTotalBattle   = 0
            critHealsTotal    = 0
            dmgTotalDS        = 0
            dsCounter         = 0
            dmgTotalNonMelee  = 0
            nonMeleeCounter   = 0
        end
    elseif currentCombatState == 'COMBAT' and enteredCombat then
        -- If we dip out and back in quickly, reset the leftCombatTime
        if leftCombatTime ~= 0 then
            --print("[Peers] Re-entered combat.")
            leftCombatTime = 0
        end
    end
end

-- Peer List Management
local function cleanupPeers()
    local currentTime = os.time()
    local idsToRemove = {}
    for id, data in pairs(M.peers) do
        if os.difftime(currentTime, data.last_update) > STALE_DATA_TIMEOUT_S then
            table.insert(idsToRemove, id)
        end
    end
    for _, id in ipairs(idsToRemove) do
        M.peers[id] = nil
        lastUpdateTime[id] = nil -- Clean up last update time as well
        -- print(string.format("[Peers] Removed stale peer: %s", id))
    end
end

local function refreshPeers()
    local new_peer_list = {}
    local currentTime = os.time()
    local myCurrentZone = utils.safeTLO(mq.TLO.Zone.ShortName, "unknown")
    local myID = utils.safeTLO(mq.TLO.Me.ID, 0)
    local my_entry_id = MyServer .. "_" .. MyName

    -- Update self entry in peers table (always refresh the AA value)
    if M.peers[my_entry_id] then
        M.peers[my_entry_id].hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0)
        M.peers[my_entry_id].mana = utils.safeTLO(mq.TLO.Me.PctMana, 0)
        M.peers[my_entry_id].endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0)
        M.peers[my_entry_id].zone = myCurrentZone
        M.peers[my_entry_id].dps = calculateCurrentDPS()
        M.peers[my_entry_id].aa = getActualAAPoints()
        M.peers[my_entry_id].class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "UNK")
        M.peers[my_entry_id].level = utils.safeTLO(mq.TLO.Me.Level, 1)
        M.peers[my_entry_id].target = utils.safeTLO(mq.TLO.Target.CleanName, "None")
        M.peers[my_entry_id].combat_state = utils.safeTLO(mq.TLO.Me.CombatState, "UNKNOWN") == "COMBAT"
        M.peers[my_entry_id].casting = utils.safeTLO(mq.TLO.Me.Casting.Name, "None")
        M.peers[my_entry_id].last_update = currentTime
        M.peers[my_entry_id].distance = 0
        M.peers[my_entry_id].inSameZone = true
    else
        -- Create new self entry
        M.peers[my_entry_id] = {
            id = my_entry_id,
            name = MyName,
            server = MyServer,
            hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
            mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
            endurance = utils.safeTLO(mq.TLO.Me.PctEndurance, 0),
            zone = myCurrentZone,
            dps = calculateCurrentDPS(),
            aa = getActualAAPoints(),
            class = utils.safeTLO(mq.TLO.Me.Class.ShortName, "UNK"),
            level = utils.safeTLO(mq.TLO.Me.Level, 1),
            target = utils.safeTLO(mq.TLO.Target.CleanName, "None"),
            combat_state = utils.safeTLO(mq.TLO.Me.CombatState, "UNKNOWN") == "COMBAT",
            casting = utils.safeTLO(mq.TLO.Me.Casting.Name, "None"),
            last_update = currentTime,
            distance = 0,
            inSameZone = true
        }
    end
    table.insert(new_peer_list, M.peers[my_entry_id])

    -- Process other peers (existing logic, but also update their AA display)
    for id, data in pairs(M.peers) do
        if id == my_entry_id then goto continue end
        if os.difftime(currentTime, data.last_update) <= STALE_DATA_TIMEOUT_S then
            data.inSameZone = (data.zone == myCurrentZone)
            if data.inSameZone then
                -- Use quoted name to handle spaces/special characters
                local spawn = mq.TLO.Spawn(string.format('pc "%s"', data.name))
                if spawn and spawn() and spawn.ID() and spawn.ID() ~= myID then
                    local distance = spawn.Distance3D()
                    if distance ~= nil then
                        data.distance = distance
                    else
                        data.distance = 9999
                    end
                else
                    data.distance = 9999
                end
            else
                data.distance = 9999
            end
            table.insert(new_peer_list, data)
        end
        ::continue::
    end

    -- Apply Sorting (existing logic)
    if M.options.sort_mode == "Alphabetical" then
        table.sort(new_peer_list, function(a, b) return a.name:lower() < b.name:lower() end)
    elseif M.options.sort_mode == "HP" then
        table.sort(new_peer_list, function(a, b) return (a.hp or 0) < (b.hp or 0) end)
    elseif M.options.sort_mode == "Distance" then
        table.sort(new_peer_list, function(a, b) return (a.distance or 9999) < (b.distance or 9999) end)
    elseif M.options.sort_mode == "DPS" then
        table.sort(new_peer_list, function(a, b) return (a.dps or 0) > (b.dps or 0) end)
    elseif M.options.sort_mode == "Class" then
        table.sort(new_peer_list, function(a, b) 
            if (a.class or "UNK") == (b.class or "UNK") then
                return a.name:lower() < b.name:lower()
            end
            return (a.class or "UNK") < (b.class or "UNK")
        end)
    end

    M.peer_list = new_peer_list

    -- Update cached height - dynamic calculation based on display style
    local peerCount = #M.peer_list
    local shouldUseGroupStyle = M.options.display_style == "group" or 
                               (peerCount <= M.options.group_window_threshold and M.options.display_style == "auto")
    local currentDisplayStyle = shouldUseGroupStyle and "group" or "table"
    
    -- Recalculate if peer count changed OR display style changed OR options that affect height changed
    if peerCount ~= lastPeerCount or currentDisplayStyle ~= lastDisplayStyle then
        lastPeerCount = peerCount
        lastDisplayStyle = currentDisplayStyle
        
        if shouldUseGroupStyle then
            -- Group window style - calculate based on bars per peer
            local baseRowHeight = 24 -- Name/level line (increased)
            local barHeight = 20 -- Each progress bar (increased from 14 to 20)
            local barSpacing = 3 -- Spacing between bars (increased)
            local peerSpacing = M.options.compact_mode and 6 or 10 -- Spacing between peers (increased)
            
            -- Calculate bars per peer dynamically
            local totalBarsForAllPeers = 0
            for _, peer in ipairs(M.peer_list) do
                local barsForThisPeer = 1 -- HP always present
                if classUsesMana(peer.class) then
                    barsForThisPeer = barsForThisPeer + 1 -- Mana
                end
                if M.options.show_endurance then
                    barsForThisPeer = barsForThisPeer + 1 -- Endurance
                end
                totalBarsForAllPeers = totalBarsForAllPeers + barsForThisPeer
            end
            
            local statusLineHeight = M.options.compact_mode and 0 or 20 -- Target/combat/casting info (increased)
            local totalStatusLines = M.options.compact_mode and 0 or peerCount
            
            local headerHeight = 25 -- Style indicator
            local totalBarHeight = totalBarsForAllPeers * (barHeight + barSpacing)
            local totalBaseHeight = peerCount * baseRowHeight
            local totalPeerSpacing = math.max(0, peerCount - 1) * peerSpacing
            local totalStatusHeight = totalStatusLines * statusLineHeight
            
            cachedPeerHeight = math.max(100, math.min(
                headerHeight + totalBaseHeight + totalBarHeight + totalPeerSpacing + totalStatusHeight, 
                700 -- Increased max height
            ))
        else
            -- Table style - original calculation  
            local peerRowHeight = 22
            local headerHeight = 45 -- Table headers + some padding
            cachedPeerHeight = math.max(80, math.min((peerCount * peerRowHeight) + headerHeight, 500))
        end
        
        -- Extra small adjustment for empty lists
        if peerCount == 0 then
            cachedPeerHeight = 80
        end
    end

    cleanupPeers()
end

-- Switcher Actions
local function switchTo(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Switching to: %s", name))
        mq.cmdf('/dex %s /foreground', name)
    end
end

local function targetCharacter(name)
    if name and type(name) == 'string' and name ~= MyName then
        print(string.format("[Peers] Targeting: %s", name))
        mq.cmdf('/target pc "%s"', name) -- Quote name for safety
    end
end

-- NEW: Group Window Style Drawing Function
function M.draw_group_window()
    for i, peer in ipairs(M.peer_list) do
        local isSelf = (peer.name == MyName and peer.server == MyServer)
        
        -- Character header with level and class
        imgui.PushID(peer.id)
        
        -- Name/Level line - increased height
        local nameColor = isSelf and ImVec4(1, 1, 0.7, 1) or ImVec4(0.9, 0.9, 0.9, 1)
        if not peer.inSameZone then
            nameColor = ImVec4(0.6, 0.6, 0.6, 1) -- Grayed out if not in zone
        end
        
        imgui.PushStyleColor(ImGuiCol.Text, nameColor)
        -- Just show name without distance (distance will be shown in level/class line)
        local displayText = peer.name
        
        -- Make the name clickable
        if imgui.Selectable(displayText .. "##name", false, ImGuiSelectableFlags.None) then
            if not isSelf then switchTo(peer.name) end
        end
        imgui.PopStyleColor()
        
        -- Right click to target
        if not isSelf and imgui.IsItemClicked(ImGuiMouseButton.Right) then
            targetCharacter(peer.name)
        end
        
        -- Show distance, level and class on same line
        imgui.SameLine()
        local distanceText = ""
        if M.options.show_distance and peer.distance and peer.distance < 9999 and peer.inSameZone then
            distanceText = string.format("(%d) ", math.floor(peer.distance))
        end
        imgui.TextColored(ImVec4(0.7, 0.9, 1, 1), string.format("%sLevel %d %s", distanceText, peer.level or 1, peer.class or "UNK"))
        
        -- Health Bar - increased height
        local hp_percent = (peer.hp or 0) / 100.0
        local hp_color = getHealthColor(peer.hp or 0)
        imgui.PushStyleColor(ImGuiCol.PlotHistogram, hp_color)
        imgui.ProgressBar(hp_percent, ImVec2(-1, 18), string.format("HP: %d%%", peer.hp or 0))
        imgui.PopStyleColor()
        
        -- Mana Bar (only if character class uses mana) - increased height
        if classUsesMana(peer.class) then
            local mana_percent = (peer.mana or 0) / 100.0
            local mana_color = getManaColor(peer.mana or 0)
            imgui.PushStyleColor(ImGuiCol.PlotHistogram, mana_color)
            imgui.ProgressBar(mana_percent, ImVec2(-1, 18), string.format("Mana: %d%%", peer.mana or 0))
            imgui.PopStyleColor()
        end
        
        -- Endurance Bar (if enabled) - increased height
        if M.options.show_endurance then
            local end_percent = (peer.endurance or 0) / 100.0
            local end_color = getEnduranceColor(peer.endurance or 0)
            imgui.PushStyleColor(ImGuiCol.PlotHistogram, end_color)
            imgui.ProgressBar(end_percent, ImVec2(-1, 18), string.format("End: %d%%", peer.endurance or 0))
            imgui.PopStyleColor()
        end
        
        -- Optional: Show additional info in compact form
        if not M.options.compact_mode then
            -- Target and status line
            local statusText = ""
            if M.options.show_target and peer.target and peer.target ~= "None" then
                statusText = "Target: " .. peer.target
            end
            if M.options.show_combat and peer.combat_state then
                if statusText ~= "" then statusText = statusText .. " | " end
                statusText = statusText .. "Fighting"
            end
            if M.options.show_casting and peer.casting and peer.casting ~= "None" then
                if statusText ~= "" then statusText = statusText .. " | " end
                statusText = statusText .. "Casting: " .. peer.casting
            end
            if M.options.show_dps and peer.dps and peer.dps > 0 then
                if statusText ~= "" then statusText = statusText .. " | " end
                statusText = statusText .. "DPS: " .. utils.cleanNumber(peer.dps, 1, true)
            end
            
            if statusText ~= "" then
                imgui.TextColored(ImVec4(0.8, 0.8, 0.8, 1), statusText)
            end
        end
        
        imgui.PopID()
        
        -- Add some spacing between group members
        if i < #M.peer_list then
            imgui.Spacing()
        end
    end
end

-- Drawing Functions
function M.draw_peer_list()
    -- Auto-switch display style based on peer count
    local shouldUseGroupStyle = M.options.display_style == "group" or 
                               (#M.peer_list <= M.options.group_window_threshold and M.options.display_style ~= "table")
    
    if shouldUseGroupStyle then
        M.draw_group_window()
        return
    end
    
    -- Original table style code...
    -- Determine column count (this part remains the same)
    local column_count = 0
    local first_column_is_name_or_class = false
    if M.options.show_name or M.options.use_class then
        column_count = column_count + 1
        first_column_is_name_or_class = true
    end
    if M.options.show_hp       then column_count = column_count + 1 end
    if M.options.show_mana     then column_count = column_count + 1 end
    if M.options.show_distance then column_count = column_count + 1 end
    if M.options.show_dps      then column_count = column_count + 1 end
    if M.options.show_target   then column_count = column_count + 1 end
    if M.options.show_combat   then column_count = column_count + 1 end
    if M.options.show_casting  then column_count = column_count + 1 end

    if column_count == 0 then
        imgui.Text("No columns selected for Peer Switcher.")
        return
    end

    local tableFlags = bit32.bor(
        ImGuiTableFlags.Reorderable,
        ImGuiTableFlags.Resizable,
        ImGuiTableFlags.Borders,
        ImGuiTableFlags.RowBg,
        ImGuiTableFlags.ScrollY,
        ImGuiTableFlags.NoHostExtendX
    )

    if not imgui.BeginTable("##PeerTableUnified", column_count, tableFlags) then
        return
    end

    if first_column_is_name_or_class then
        local header_text = "Name" -- Default to Name
        if M.options.sort_mode ~= "Class" and M.options.use_class then
            header_text = "Class"
        end
        imgui.TableSetupColumn(header_text, ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 150)
    end
    if M.options.show_hp then imgui.TableSetupColumn("HP", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_mana then imgui.TableSetupColumn("Mana", ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_distance then imgui.TableSetupColumn("Dist", ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_dps then imgui.TableSetupColumn("DPS", ImGuiTableColumnFlags.Sortable, ImGuiTableColumnFlags.WidthFixed, 45) end
    if M.options.show_target then imgui.TableSetupColumn("Target", ImGuiTableColumnFlags.WidthFixed, 100) end
    if M.options.show_combat then imgui.TableSetupColumn("Combat", ImGuiTableColumnFlags.WidthFixed, 70) end
    if M.options.show_casting then imgui.TableSetupColumn("Casting", ImGuiTableColumnFlags.WidthFixed, 100) end
    imgui.TableHeadersRow()

    local current_drawn_class = nil -- Variable to track the currently drawn class group

    for _, peer in ipairs(M.peer_list) do
        -- If sorting by class, and the class has changed, insert a class title row.
        if M.options.sort_mode == "Class" and (peer.class or "Unknown") ~= current_drawn_class then
            current_drawn_class = peer.class or "Unknown"
            imgui.TableNextRow()
            imgui.TableNextColumn()

            -- Style the class title text
            imgui.PushStyleColor(ImGuiCol.Text, ImVec4(1.0, 0.75, 0.3, 1.0))
            imgui.Text(current_drawn_class)
            imgui.PopStyleColor()

            for i = 2, column_count do
                imgui.TableNextColumn()
                imgui.Text("") -- Empty text to fill cells
            end
        end

        -- Now draw the actual peer data row
        imgui.TableNextRow()

        -- Name/Class Column Content
        if first_column_is_name_or_class then
            imgui.TableNextColumn()
            local isSelf = (peer.name == MyName and peer.server == MyServer)
            local zoneColor = peer.inSameZone and ImVec4(0.8,1,0.8,1) or ImVec4(1,0.7,0.7,1)
            if isSelf then zoneColor = ImVec4(1,1,0.7,1) end
            imgui.PushStyleColor(ImGuiCol.Text, zoneColor)

            local displayValue = peer.name -- Default to name
            if M.options.sort_mode ~= "Class" and M.options.use_class then
                displayValue = peer.class or "Unknown"
            end
            local uniqueLabel = string.format("%s##%s_peer", displayValue, peer.id) -- Suffix for uniqueness

            if imgui.Selectable(uniqueLabel, false, ImGuiSelectableFlags.SpanAllColumns) then
                if not isSelf then switchTo(peer.name) end
            end
            imgui.PopStyleColor()

            if imgui.IsItemHovered() then
                imgui.BeginTooltip()
                imgui.Text("Name : %s",  peer.name)
                imgui.Text("Class: %s",  peer.class or "Unknown")
                -- Add any other details you want in the tooltip here
                imgui.Text("Zone: %s", peer.zone or "Unknown")
                if not isSelf then
                    imgui.Text("Left-click : Switch to %s", peer.name)
                    imgui.Text("Right-click: Target %s",   peer.name)
                end
                imgui.EndTooltip()
            end
            if not isSelf and imgui.IsItemClicked(ImGuiMouseButton.Right) then
                targetCharacter(peer.name)
            end
        end

        -- HP Column
        if M.options.show_hp then
            imgui.TableNextColumn()
            local hpColor = getHealthTextColor(peer.hp) -- Use dynamic color for table text
            imgui.PushStyleColor(ImGuiCol.Text, hpColor)
            imgui.Text("%.0f%%", peer.hp or 0)
            imgui.PopStyleColor()
        end

        -- Mana Column
        if M.options.show_mana then
            imgui.TableNextColumn()
            local manaColor = getManaColor(peer.mana)
            imgui.PushStyleColor(ImGuiCol.Text, manaColor)
            imgui.Text("%.0f%%", peer.mana or 0)
            imgui.PopStyleColor()
        end

        -- Distance Column
        if M.options.show_distance then
            imgui.TableNextColumn()
            local distance = peer.distance or 0
            local distText = "N/A"
            local distColor = ImVec4(0.7, 0.7, 0.7, 1) -- Gray default
            if not peer.inSameZone then
                distText = "MIA"; distColor = ImVec4(1, 0.6, 0.6, 1)
            elseif distance >= 9999 then
                distText = "???"; distColor = ImVec4(1, 1, 0.6, 1)
            else
                distText = string.format("%.0f", distance) -- Integer for cleaner look
                if distance < 20 then distColor = ImVec4(0.6,1,0.6,1) -- Very Close
                elseif distance < 100 then distColor = ImVec4(0.8,1,0.8,1) -- Green
                elseif distance < 175 then distColor = ImVec4(1,0.8,0.6,1) -- Orange-ish
                else distColor = ImVec4(1,0.6,0.6,1) -- Red-ish
                end
            end
            imgui.PushStyleColor(ImGuiCol.Text, distColor)
            imgui.Text(distText)
            imgui.PopStyleColor()
        end

        -- DPS Column
        if M.options.show_dps then
            imgui.TableNextColumn()
            imgui.Text(utils.cleanNumber(peer.dps or 0, 1, true))
        end

        -- Target Column
        if M.options.show_target then
            imgui.TableNextColumn()
            local targetColor
            if M.options.show_combat then -- If combat column is shown, target color is simpler
                targetColor = (peer.target == "None") and ImVec4(0.7,0.7,0.7,1) or ImVec4(1,1,1,1)
            else -- If combat column hidden, color target if peer is in combat
                if peer.combat_state then
                    targetColor = ImVec4(1,0,0,1) -- Red if in combat
                else
                    targetColor = (peer.target == "None") and ImVec4(0.7,0.7,0.7,1) or ImVec4(1,1,1,1)
                end
            end
            imgui.PushStyleColor(ImGuiCol.Text, targetColor)
            imgui.Text(peer.target or "None")
            imgui.PopStyleColor()
        end

        -- Combat State Column
        if M.options.show_combat then
            imgui.TableNextColumn()
            if peer.combat_state then
                combatText = "Fighting"
                combatColor = ImVec4(1, 0.7, 0.7, 1) -- Reddish for Combat
            else
                combatText = "Idle"
                combatColor = ImVec4(1, 1, 0.7, 1) -- Yellowish for Cooldown
            end
            imgui.PushStyleColor(ImGuiCol.Text, combatColor)
            imgui.Text(combatText)
            imgui.PopStyleColor()
        end

        -- Casting Column
        if M.options.show_casting then
            imgui.TableNextColumn()
            local castingColor = (peer.casting == "None" or peer.casting == "") and ImVec4(0.7,0.7,0.7,1) or ImVec4(0.8,0.8,1,1)
            imgui.PushStyleColor(ImGuiCol.Text, castingColor)
            imgui.Text(peer.casting or "None")
            imgui.PopStyleColor()
        end
    end
    imgui.EndTable()
end

function M.draw_aa_window()
    if not M.show_aa_window.value then return end
    local window_open = M.show_aa_window.value
    imgui.SetNextWindowSize(ImVec2(400, 500), ImGuiCond.FirstUseEver)
    if imgui.Begin("Peer AA Totals", window_open, bit32.bor(ImGuiWindowFlags.NoCollapse)) then
        -- Header with close button and peer count
        if imgui.Button("Close") then
            M.show_aa_window.value = false
        end
        imgui.SameLine()
        imgui.TextDisabled("(" .. #M.peer_list .. " peers)")
        imgui.Separator()
        -- Sort peers alphabetically by name
        local aa_list = {}
        for _, p in ipairs(M.peer_list) do table.insert(aa_list, p) end
        table.sort(aa_list, function(a, b)
            local name_a = (a.name or "Unknown"):lower()
            local name_b = (b.name or "Unknown"):lower()
            return name_a < name_b
        end)
        local total_aa = 0
        for _, peer in ipairs(aa_list) do
            total_aa = total_aa + (peer.aa or 0)
        end
        local avg_aa = math.floor(total_aa / math.max(1, #aa_list))
        -- Stats header
        imgui.Text("Total AA: " .. formatNumberWithCommas(total_aa))
        local row_height = imgui.GetTextLineHeightWithSpacing()
        local max_rows = #aa_list
        local table_height = math.min(max_rows * row_height + 20, 500)
        -- Begin clean table with 3 columns
        local tableFlags = bit32.bor(
            ImGuiTableFlags.Borders,
            ImGuiTableFlags.RowBg,
            ImGuiTableFlags.ScrollY,
            ImGuiTableFlags.SizingFixedFit
        )
        if imgui.BeginTable("PeerAATable", 3, tableFlags, ImVec2(0, table_height)) then
            imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn("AA Points", ImGuiTableColumnFlags.WidthFixed, 90) -- Increased width
            imgui.TableSetupColumn("", ImGuiTableColumnFlags.WidthFixed, 60) -- Empty header for suffix
            imgui.TableHeadersRow()
            for _, peer in ipairs(aa_list) do
                imgui.TableNextRow()
                local aa_val = peer.aa or 0
                local isSelf = (peer.name == MyName and peer.server == MyServer)
                -- Name Column
                imgui.TableNextColumn()
                imgui.Text(peer.name or "Unknown")
                imgui.TableNextColumn()
                local aa_text = formatNumberWithCommas(aa_val)
                local text_width = imgui.CalcTextSize(aa_text)
                local cell_width = imgui.GetColumnWidth()
                imgui.SetCursorPosX(imgui.GetCursorPosX() + (cell_width - text_width - imgui.GetStyle().ItemSpacing.x) / 2)
                imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.7, 0.9, 1.0, 1.0)) -- Light blue
                imgui.Text(aa_text)
                imgui.PopStyleColor()
                -- Suffix Column
                imgui.TableNextColumn()
                local suffix = ""
                if aa_val >= 1000000 then
                    suffix = string.format("(%.1fM)", aa_val / 1000000)
                elseif aa_val >= 1000 then
                    suffix = string.format("(%.1fK)", aa_val / 1000)
                end
                if suffix ~= "" then
                    imgui.PushStyleColor(ImGuiCol.Text, ImVec4(0.3, 1.0, 0.3, 1.0)) -- Green
                    imgui.Text(suffix)
                    imgui.PopStyleColor()
                end
            end
            imgui.EndTable()
        end
    end
    imgui.End()
    if not window_open then
        M.show_aa_window.value = false
    end
end

function M.load_config()
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        local parsed = json.decode(content)
        if parsed and parsed[myName] then
            for k, v in pairs(parsed[myName]) do
                M.options[k] = v
            end
        end
    end
end

function M.save_config()
    local all_config = {}
    local file = io.open(config_path, "r")
    if file then
        local content = file:read("*a")
        file:close()
        all_config = json.decode(content) or {}
    end

    all_config[myName] = M.options

    file = io.open(config_path, "w")
    if file then
        file:write(json.encode(all_config, { indent = true }))
        file:close()
        print(string.format("\ay[Peers] Saved UI config to %s\ax", config_path))
    else
        print(string.format("\ar[Peers] Failed to write UI config to %s\ax", config_path))
    end
end

-- Main update function for the peer module
function M.update()
    checkCombatState()
    publishHealthStatus() -- Publish own status periodically
    refreshPeers()        -- Refresh peer list, distances, and sorting
    -- DPS calculation happens implicitly via events and calculateCurrentDPS()
end

-- Initialization function
function M.init()
    print("[Peers] Initializing...")
    MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
    MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")
    if MyName == "Unknown" or MyServer == "Unknown" then
        print('\ar[Peers] Failed to get character name or server.\ax')
        return
    end
    M.load_config()
    actor_mailbox = actors.register('peer_status', peer_message_handler)
    if not actor_mailbox then
        print('\ar[Peers] Failed to register actor mailbox "peer_status".\ax')
        return
    end
    print("[Peers] Actor mailbox registered successfully.")
    mq.event("melee_crit", "#*#You score a critical hit!#*#(#1#)#*#", critCallBack)
    mq.event("melee_crit2", "#*#You deliver a critical blast!#*#(#1#)#*#", critCallBack)
    mq.event("melee_crit3", string.format("#*#%s scores a critical hit!#*#(#1#)#*#", MyName), critCallBack)
    mq.event("melee_deadly_strike", string.format("#*#%s scores a Deadly Strike!#*#(#1#)#*#", MyName), critCallBack)
    mq.event("melee_do_damage", "#*#You #1# #2# for #3# points of damage#*#", meleeCallBack)
    mq.event("melee_miss", "#*#You try to #1# #2#, but miss#*#", function() end)
    mq.event("melee_non_melee", string.format("#*#%s hit #1# for #2# points of non-melee damage#*#", MyName), nonMeleeCallBack)
    mq.event("melee_damage_shield", "#*#was hit by non-melee for #2# points of damage#*#", nonMeleeCallBack)
    mq.event("melee_you_hit_non-melee", "#*#You were hit by non-melee for #2# damage#*#", nonMeleeCallBack)
    mq.event("melee_crit_heal", "#*#You perform an exceptional heal!#*#(#1#)#*#", critHealCallBack)
    
    -- Only register AA events for EZ Linux server
    if isEZLinuxServer() then
        mq.event("aa_display_capture", "Unspent AA: #1#", aaDisplayCallback)
        mq.event("aa_gain_capture", "#*#You now have #1# ability point(s)#*#", aaGainCallback)
        print("[Peers] DPS and AA events registered for EZ Linux server.")
        
        -- Request initial AA update
        if not M.aa_said then
            mq.cmd('/say AA')
            M.aa_said = true
        end
    else
        print("[Peers] DPS events registered. Using TLO for AA points on this server.")
    end
    lastAACheckTime = os.time()
    
    refreshPeers()
    print("[Peers] Initialization complete.")
end

-- Getters for main UI
function M.get_peer_data()
    return {
        list = M.peer_list,
        count = #M.peer_list,
        my_aa = getActualAAPoints(),
        cached_height = cachedPeerHeight
    }
end

function M.get_refresh_interval()
    return REFRESH_INTERVAL_MS
end

-- Force height recalculation (call when display options change)
function M.recalculate_height()
    lastPeerCount = -1 -- Force recalculation
    lastDisplayStyle = "" -- Force recalculation
end

M.formatNumberWithCommas = formatNumberWithCommas

return M