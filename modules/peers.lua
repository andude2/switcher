-- peers.lua
-- Handles peer status, DPS tracking, and switching logic

local mq = require('mq')
local imgui = require('ImGui')
local actors = require('actors')
local utils = require('switcher.modules.utils')
local json = require('dkjson')
local config = {}
local config_path = string.format('%s/peer_ui_config.json', mq.configDir)
local myName = mq.TLO.Me.CleanName() or "Unknown"

local M = {} -- Module table

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
}
M.show_aa_window = { value = false } -- Control the visibility of the AA window

local lastPeerCount    = 0
local cachedPeerHeight = 300 -- Default height
local lastUpdateTime   = {} -- [id] = timestamp of last message received
local lastPublishTime  = 0  -- Timestamp of last published message
local actor_mailbox    = nil
local MyName = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
local MyServer = utils.safeTLO(mq.TLO.EverQuest.Server, "Unknown")


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
-- local sequenceCounter   = 0 -- Not strictly needed unless debugging sequence
-- local damTable          = {} -- Damage table for detailed logging (removed for simplicity, re-add if needed)
-- local tableSize         = 0

-- Helper: Get health bar color
local function getHealthColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(1, 0, 0, 1) -- Red
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1) -- Yellow
    else
        return ImVec4(0, 1, 0, 1) -- Green
    end
end

-- Helper: Get mana bar color (unchanged)
local function getManaColor(percent)
    percent = percent or 0
    if percent < 35 then
        return ImVec4(0.5, 0.5, 0, 1) -- Dark Yellow/Reddish for low mana
    elseif percent < 75 then
        return ImVec4(1, 1, 0, 1) -- Yellow
    else
        return ImVec4(0.678, 0.847, 0.902, 1) -- Light Blue
    end
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
    local status = {
        name = MyName,
        server = MyServer,
        hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
        mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
        zone = utils.safeTLO(mq.TLO.Zone.ShortName, "unknown"),
        distance = 0,
        dps = calculateCurrentDPS(),
        aa = utils.safeTLO(mq.TLO.Me.AAPoints, 0)
    }
    actor_mailbox:send({ mailbox = 'peer_status' }, status)
    --print(string.format("[Peers] Published status: %s/%s HP: %d%% DPS: %.1f", MyName, MyServer, status.hp, status.dps))
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
        zone = content.zone or "unknown",
        dps = content.dps or 0,
        aa = content.aa or 0,
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
    -- Crit damage is often *part* of melee/spell damage already reported.
    -- Check specific game logs. If it's *extra* damage, add it.
    -- If it's just a notification of a hit type, don't add it here to avoid double counting.
    -- Assuming here it's just a notification, so only adding to critTotalBattle for stats if needed.
    critTotalBattle = critTotalBattle + dmg
    -- We don't add to dmgTotalBattle here assuming the main hit is logged separately.
end

local function critHealCallBack(line, dmgStr)
    -- Crit heals don't contribute to dealt DPS.
    local dmg = handleDamageEvent(dmgStr) -- Still resets combat timer if needed
    critHealsTotal = critHealsTotal + dmg
end

local function nonMeleeCallBack(line, targetOrYou, dmgStr)
    local dmg = handleDamageEvent(dmgStr)
    local type = "non-melee" -- Default: Spell/proc damage dealt by you

    -- Damage Shield (target hit by non-melee means your DS hit them)
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
             -- First frame out of combat
            leftCombatTime = os.time()
            print("[Peers] Combat ended (timer started).")
        end
        -- Check if timeout has expired
        if os.difftime(os.time(), leftCombatTime) > BATTLE_DURATION_S then
             print("[Peers] Combat DPS reset.")
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
             print("[Peers] Re-entered combat.")
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

    -- Ensure self is in peers table
    M.peers[my_entry_id] = M.peers[my_entry_id] or {
        id = my_entry_id,
        name = MyName,
        server = MyServer,
        hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0),
        mana = utils.safeTLO(mq.TLO.Me.PctMana, 0),
        zone = myCurrentZone,
        dps = calculateCurrentDPS(),
        aa = utils.safeTLO(mq.TLO.Me.AAPoints, 0),
        last_update = currentTime,
        distance = 0,
        inSameZone = true
    }
    table.insert(new_peer_list, M.peers[my_entry_id])

    -- Process other peers
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
                        --print(string.format("[Peers] Distance to %s: %.1f", data.name, data.distance))
                    else
                        data.distance = 9999
                        --print(string.format("[Peers] Distance3D for %s returned nil", data.name))
                    end
                else
                    data.distance = 9999
                    --print(string.format("[Peers] Spawn not found for %s (ID=%s)", data.name, spawn.ID() or "nil"))
                end
            else
                data.distance = 9999
                --print(string.format("[Peers] %s is in different zone: %s", data.name, data.zone))
            end
            table.insert(new_peer_list, data)
        end
        ::continue::
    end

    -- Apply Sorting
    if M.options.sort_mode == "Alphabetical" then
        table.sort(new_peer_list, function(a, b) return a.name:lower() < b.name:lower() end)
    elseif M.options.sort_mode == "HP" then
        table.sort(new_peer_list, function(a, b) return (a.hp or 0) < (b.hp or 0) end)
    elseif M.options.sort_mode == "Distance" then
        table.sort(new_peer_list, function(a, b) return (a.distance or 9999) < (b.distance or 9999) end)
    elseif M.options.sort_mode == "DPS" then
        table.sort(new_peer_list, function(a, b) return (a.dps or 0) > (b.dps or 0) end)
    end

    M.peer_list = new_peer_list

    -- Update cached height
    local peerCount = #M.peer_list
    if peerCount ~= lastPeerCount then
        lastPeerCount = peerCount
        local peerRowHeight = 20
        local headerHeight = 38
        cachedPeerHeight = math.min((peerCount * peerRowHeight) + headerHeight)
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


-- Drawing Functions
function M.draw_peer_list()
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
            local hpColor = getHealthColor(peer.hp)
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
    if not M.show_aa_window.value then return end -- Check the flag passed from main

    -- Use a boolean directly for Begin, passing the reference table value
    local window_open = M.show_aa_window.value
    imgui.SetNextWindowSize(ImVec2(250, 300), ImGuiCond.FirstUseEver) -- Initial size

    if imgui.Begin("Peer AA Counts", window_open, ImGuiWindowFlags.NoCollapse) then
        if imgui.Button("Close") then
            M.show_aa_window.value = false -- Modify the reference table value
        end
        imgui.Separator()

        -- Create a temporary sorted list for AA display if needed (peer_list might be sorted differently)
        local aa_list = {}
        for _, p in ipairs(M.peer_list) do table.insert(aa_list, p) end
        table.sort(aa_list, function(a, b) return a.name:lower() < b.name:lower() end)

        if imgui.BeginTable("PeerAATable", 2, bit32.bor(ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY)) then
            imgui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
            imgui.TableSetupColumn("AA Points", ImGuiTableColumnFlags.WidthFixed, 80)
            imgui.TableHeadersRow()

            for _, peer in ipairs(aa_list) do
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

    -- Important: Update the external flag if the window was closed via 'X'
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
    -- Register DPS events
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
    print("[Peers] DPS events registered.")
    refreshPeers()
    print("[Peers] Initialization complete.")
end

-- Getters for main UI
function M.get_peer_data()
    return {
        list = M.peer_list,
        count = #M.peer_list,
        my_aa = utils.safeTLO(mq.TLO.Me.AAPoints, 0),
        cached_height = cachedPeerHeight
    }
end

function M.get_refresh_interval()
    return REFRESH_INTERVAL_MS
end

return M