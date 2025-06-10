-- main.lua
-- Main script orchestrating the Peer Switcher and Buff Display modules
-- Enhanced with group window display options

local mq = require 'mq'
local imgui = require 'ImGui'
local icons = require 'mq.Icons' -- Required by main UI elements potentially
local command = require 'modules.commands'

local success_utils, utils = pcall(require, 'switcher.modules.utils')
local success_peers = require('switcher.modules.peers')
local peers = require('switcher.modules.peers')
local success_buffs, buffs = pcall(require, 'switcher.modules.buffs')
local actors = require('actors')
local success_actors = require('actors')

-- Check essential libraries first
if not mq or not imgui then
    print("\arFatal Error: MQ or ImGui library not found!\ax")
    mq.exit()
end
if not success_utils then
    print("\arFatal Error: Failed to load 'utils.lua'.\ax")
    mq.exit()
end
if not success_peers then
    print("\arFatal Error: Failed to load 'peers.lua'.\ax")
    mq.exit()
end
if not success_buffs then
    print("\arFatal Error: Failed to load 'buffs.lua'.\ax")
    mq.exit()
end

-- Global UI State
local combinedUIOpen        = { value = true }-- Use a table for mutable boolean
local combinedUIInitialized = false
local showPeerAAWindow      = peers.show_aa_window -- Link directly to the peers module's flag


------------------------------------------------------
-- Player Stats Display Function
------------------------------------------------------
local function DrawPlayerStats()
    -- Use utils.safeTLO for robustness
    local name = utils.safeTLO(mq.TLO.Me.CleanName, "Unknown")
    local level = utils.safeTLO(mq.TLO.Me.Level, 0)
    -- local hp = utils.safeTLO(mq.TLO.Me.CurrentHP, 0) -- Raw HP not shown in original
    -- local max_hp = utils.safeTLO(mq.TLO.Me.MaxHP, 1) -- Avoid div by zero
    local pct_hp = utils.safeTLO(mq.TLO.Me.PctHPs, 0)
    -- local mana = utils.safeTLO(mq.TLO.Me.CurrentMana, 0) -- Raw not shown
    local max_mana = utils.safeTLO(mq.TLO.Me.MaxMana, 0)
    local pct_mana = utils.safeTLO(mq.TLO.Me.PctMana, 0)
    -- local endurance = utils.safeTLO(mq.TLO.Me.CurrentEndurance, 0) -- Raw not shown
    local max_endurance = utils.safeTLO(mq.TLO.Me.MaxEndurance, 0)
    local pct_endurance = (max_endurance > 0) and utils.safeTLO(mq.TLO.Me.PctEndurance, 0) or 0

    -- Layout similar to original
    imgui.TextColored(ImVec4(1, 1, 0.7, 1), string.format("Name: %s (Lvl %d)", name, level)) -- Combine Name/Level

    local hpText = string.format("HP: %.0f%%", pct_hp)
    local manaText = (max_mana > 0) and string.format("Mana: %.0f%%", pct_mana) or "Mana: N/A"
    local endText = (max_endurance > 0) and string.format("End: %.0f%%", pct_endurance) or "End: N/A"

    imgui.Text(hpText)
    imgui.SameLine(75)
    imgui.TextColored(ImVec4(0.6, 0.8, 1, 1), manaText) -- Blue-ish for Mana
    imgui.SameLine(150)
    imgui.TextColored(ImVec4(1, 0.7, 0.5, 1), endText) -- Orange-ish for Endurance
end

------------------------------------------------------
-- COMBINED UI WINDOW Definition
------------------------------------------------------
local function CombinedUI()
    if not combinedUIInitialized then
        imgui.SetNextWindowSize(ImVec2(350, 700), ImGuiCond.FirstUseEver) -- Sensible default size
        combinedUIInitialized = true
    end

        if peers.options.borderless then
        windowFlags = bit32.bor(ImGuiWindowFlags.NoTitleBar)
    else
        windowFlags = 0 --ImGuiWindowFlags.MenuBar -- Uncomment ImGuiWindowFlags here, and Menu Bar below to change display options
    end

    -- Begin main window
    if imgui.Begin("EQ Hub") then

        if imgui.BeginPopupContextWindow("##HubContext", ImGuiPopupFlags.MouseButtonRight) then

        imgui.Text("Switcher Options")
        imgui.Separator()

        -- Display Style Options
        imgui.Text("Display Style:")
        local current_style = peers.options.display_style
        local style_changed = false
        if imgui.RadioButton("Auto", current_style == "auto") then
            peers.options.display_style = "auto"
            style_changed = true
        end
        imgui.SameLine()
        if imgui.RadioButton("Table", current_style == "table") then
            peers.options.display_style = "table"
            style_changed = true
        end
        imgui.SameLine()
        if imgui.RadioButton("Group", current_style == "group") then
            peers.options.display_style = "group"
            style_changed = true
        end
        
        -- Group Window Threshold
        imgui.PushItemWidth(80)
        local threshold_changed = false
        peers.options.group_window_threshold, threshold_changed = imgui.SliderInt("Auto Switch Threshold", peers.options.group_window_threshold, 1, 20)
        imgui.PopItemWidth()
        
        if style_changed or threshold_changed then
            peers.recalculate_height()
            peers.save_config()
        end
        
        imgui.Separator()

        -- Group Window Specific Options
        if peers.options.display_style == "group" or (#peers.get_peer_data().list <= peers.options.group_window_threshold and peers.options.display_style ~= "table") then
            imgui.Text("Group Window Options:")
            local endurance_changed = false
            local compact_changed = false
            peers.options.show_endurance, endurance_changed = imgui.Checkbox("Show Endurance Bars", peers.options.show_endurance)
            peers.options.compact_mode, compact_changed = imgui.Checkbox("Compact Mode", peers.options.compact_mode)
            peers.options.show_pet_bars = imgui.Checkbox("Show Pet Bars", peers.options.show_pet_bars)
            
            if endurance_changed or compact_changed then
                peers.recalculate_height()
                peers.save_config()
            end
            imgui.Separator()
        end

        -- Standard Options
        peers.options.show_name     = imgui.Checkbox("Show Name", peers.options.show_name)
        peers.options.show_hp       = imgui.Checkbox("Show HP (%)", peers.options.show_hp)
        peers.options.show_mana     = imgui.Checkbox("Show Mana (%)", peers.options.show_mana)
        peers.options.show_distance = imgui.Checkbox("Show Distance", peers.options.show_distance)
        peers.options.show_dps      = imgui.Checkbox("Show DPS", peers.options.show_dps)
        peers.options.show_target   = imgui.Checkbox("Show Target", peers.options.show_target)
        peers.options.show_combat   = imgui.Checkbox("Show Combat", peers.options.show_combat)
        peers.options.show_casting  = imgui.Checkbox("Show Casting", peers.options.show_casting)
        peers.options.borderless    = imgui.Checkbox("Borderless", peers.options.borderless)
        peers.options.show_player_stats = imgui.Checkbox("Show Player Stats", peers.options.show_player_stats)
        peers.options.use_class     = imgui.Checkbox("Use Class Name", peers.options.use_class)
        imgui.Separator()

        -- Sort submenu
        if imgui.BeginMenu("Sort By") then
            if imgui.MenuItem("Alphabetical", nil, peers.options.sort_mode == "Alphabetical") then
            peers.options.sort_mode = "Alphabetical"
            peers.save_config()
            end
            if imgui.MenuItem("HP (Asc)",      nil, peers.options.sort_mode == "HP") then
            peers.options.sort_mode = "HP"
            peers.save_config()
            end
            if imgui.MenuItem("Distance (Asc)",nil, peers.options.sort_mode == "Distance") then
            peers.options.sort_mode = "Distance"
            peers.save_config()
            end
            if imgui.MenuItem("DPS (Desc)",    nil, peers.options.sort_mode == "DPS") then
            peers.options.sort_mode = "DPS"
            peers.save_config()
            end
            if imgui.MenuItem("Class", nil, peers.options.sort_mode == "Class") then
            peers.options.sort_mode = "Class"
            peers.save_config()
            end
            imgui.EndMenu()
        end

        imgui.Separator()
        if imgui.MenuItem("Show AA Window", nil, showPeerAAWindow.value) then
            showPeerAAWindow.value = not showPeerAAWindow.value
        end

        if imgui.MenuItem("Save Config Now") then
            peers.save_config()
        end

        imgui.EndPopup()
        end

        -- == Player Stats Section ==
        if peers.options.show_player_stats then
            DrawPlayerStats()
            imgui.Separator()
            imgui.Spacing()
        end

        -- == Switcher Section ==
        local peerData = peers.get_peer_data() -- Get current peer data
        local zonePCCount = mq.TLO.SpawnCount("PC")() -- Get actual PC count in zone
        local peersInZone = peerData.count -- Assuming this represents peers in zone

        -- Determine color based on whether all peers are in zone
        local pcCountColor
        if zonePCCount == peersInZone then
            pcCountColor = ImVec4(0, 1, 0, 1) -- Green if all peers are in zone
        else
            pcCountColor = ImVec4(1, 0, 0, 1) -- Red if counts don't match
        end

        imgui.TextColored(pcCountColor, string.format("Zone PC's: %d", zonePCCount))
        imgui.SameLine(imgui.GetWindowContentRegionWidth() - 120)
        local peerData = peers.get_peer_data()
        local aaFormatted = string.format("AA Points: %s", peers.formatNumberWithCommas(peerData.my_aa or 0))
        imgui.TextColored(ImVec4(0.7, 0.9, 1, 1), aaFormatted)
        --[[imgui.SameLine(imgui.GetWindowContentRegionWidth() - 100) -- Align AA to the right
        local countNPC = mq.TLO.SpawnCount("NPC")
        imgui.TextColored(ImVec4(0.8, 0.8, 1, 1), string.format("Zone NPC's: %s", countNPC))]]
        if imgui.IsItemHovered() then imgui.SetTooltip("Click to toggle Peer AA window") end
        if imgui.IsItemClicked() then
            showPeerAAWindow.value = not showPeerAAWindow.value -- Toggle the flag
        end
        imgui.Separator()

        -- Display style indicator
        local shouldUseGroupStyle = peers.options.display_style == "group" or 
                                   (peerData.count <= peers.options.group_window_threshold and peers.options.display_style ~= "table")
        local styleText = shouldUseGroupStyle and "Group Style" or "Table Style"
        local styleColor = shouldUseGroupStyle and ImVec4(0.7, 1, 0.7, 1) or ImVec4(0.7, 0.7, 1, 1)
        imgui.TextColored(styleColor, styleText)
        imgui.SameLine()
        imgui.TextDisabled(string.format("(%d peers)", peerData.count))

        -- Child window for peer list with calculated height
        local opened = imgui.BeginChild("PeerListChild", ImVec2(0, peerData.cached_height), false, ImGuiWindowFlags.None)
        if opened then
            ImGui.SetWindowFontScale(peers.options.font_scale)
            peers.draw_peer_list()
        end
        imgui.EndChild()
        imgui.Separator()
        imgui.Spacing()

        -- == Buff Display Section ==
        function DrawColoredSeparatorText(colorVec4, text)
            imgui.TextColored(colorVec4, text)
        
            local draw_list = imgui.GetWindowDrawList()
            local x, y = imgui.GetCursorScreenPos()
            local width, _ = imgui.GetContentRegionAvail()
        
            local sepColor = imgui.GetStyleColorVec4(ImGuiCol_Separator)
            local colorU32 = imgui.GetColorU32(sepColor)
            imgui.Dummy(0, 4)
        end                  

        ImGui.SeparatorText("Buff Display")

        -- Child window for buffs (takes remaining space)
        -- Give it a minimum height, and let it expand. -1 takes available space.
        if imgui.BeginChild("BuffDisplaySection", ImVec2(0, -imgui.GetFrameHeightWithSpacing()), false, ImGuiWindowFlags.None) then
            buffs.draw() -- Call the draw function from the buffs module
        end
        imgui.EndChild()

    end
    imgui.End() -- End main window

    peers.draw_aa_window()

    -- If main window closed, exit script
    if not combinedUIOpen.value then
        print("[Main] UI Closed, exiting script.")
        mq.exit()
    end
end

------------------------------------------------------
-- INITIALIZATION
------------------------------------------------------
print("[Main] Initializing Modules...")
local gameState = utils.safeTLO(mq.TLO.MacroQuest.GameState, "UNKNOWN")
if gameState ~= "INGAME" then
    print("\ar[Main] Not in game. Please enter the world and restart script.\ax")
    mq.exit()
end

-- Initialize modules (order might matter if there are dependencies)
peers.init()
buffs.init() -- Buffs init depends on Me.Name, Me.MaxBuffSlots etc.
command.init()
command.setup_maintenance()

print("[Main] Initializing ImGui Window...")
-- Register the main UI function with ImGui
mq.imgui.init('CombinedUI', CombinedUI) -- Use a unique name

------------------------------------------------------
-- MAIN EVENT LOOP
------------------------------------------------------
print("[Main] Starting Event Loop...")
local refreshInterval = peers.get_refresh_interval() -- Get interval from peers module

while mq.TLO.MacroQuest.GameState() == "INGAME" do

    -- Update modules
    peers.update()
    buffs.update()

    -- Process MQ events and ImGui rendering
    mq.doevents()

    -- Delay
    mq.delay(refreshInterval) -- Use the interval defined in peers module
end

print("[Main] Event Loop Ended.")