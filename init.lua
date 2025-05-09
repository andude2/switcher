-- main.lua
-- Main script orchestrating the Peer Switcher and Buff Display modules

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

    -- Begin main window
    if imgui.Begin("EQ Companion Hub") then

        -- Menu Bar
        if imgui.BeginMenuBar() then
            if imgui.BeginMenu("Switcher Options") then
                 -- Menu items directly modify the options table in the peers module
                 local changed
                 changed, peers.options.show_name = imgui.Checkbox("Show Name", peers.options.show_name)
                 changed, peers.options.show_hp = imgui.Checkbox("Show HP (%)", peers.options.show_hp)
                 changed, peers.options.show_distance = imgui.Checkbox("Show Distance", peers.options.show_distance)
                 changed, peers.options.show_dps = imgui.Checkbox("Show DPS", peers.options.show_dps)
                 imgui.Separator()
                 if imgui.BeginMenu("Sort By") then
                      if imgui.MenuItem("Alphabetical", nil, peers.options.sort_mode == "Alphabetical") then peers.options.sort_mode = "Alphabetical" end
                      if imgui.MenuItem("HP (Asc)", nil, peers.options.sort_mode == "HP") then peers.options.sort_mode = "HP" end
                      if imgui.MenuItem("Distance (Asc)", nil, peers.options.sort_mode == "Distance") then peers.options.sort_mode = "Distance" end
                      if imgui.MenuItem("DPS (Desc)", nil, peers.options.sort_mode == "DPS") then peers.options.sort_mode = "DPS" end
                      imgui.EndMenu()
                 end
                 imgui.Separator()
                 if imgui.MenuItem("Show AA Window", nil, showPeerAAWindow.value) then
                     showPeerAAWindow.value = not showPeerAAWindow.value
                 end
                imgui.EndMenu()
            end
            imgui.EndMenuBar()
        end

        -- == Player Stats Section ==
        DrawPlayerStats()
        ImGui.PushStyleColor(ImGuiCol.ChildBg, ImGui.GetStyleColorVec4(ImGuiCol.Separator))
        ImGui.BeginChild("ThickSeparator", 0, 6, false, ImGuiWindowFlags.NoScrollbar)
        ImGui.EndChild()
        ImGui.PopStyleColor()
        -- Adds vertical space
        imgui.Spacing()

        -- == Switcher Section ==
        local peerData = peers.get_peer_data() -- Get current peer data
        imgui.TextColored(ImVec4(0.7, 0.9, 1, 1), string.format("Peer Switcher (%d)", peerData.count))
        imgui.SameLine(imgui.GetWindowContentRegionWidth() - 100) -- Align AA to the right
        imgui.TextColored(ImVec4(0.8, 0.8, 1, 1), string.format("My AA: %d", peerData.my_aa))
        if imgui.IsItemHovered() then imgui.SetTooltip("Click to toggle Peer AA window") end
        if imgui.IsItemClicked() then
            showPeerAAWindow.value = not showPeerAAWindow.value -- Toggle the flag
        end
        imgui.Separator()

        -- Child window for peer list with calculated height
        if imgui.BeginChild("PeerListChild", ImVec2(0, peerData.cached_height), false, ImGuiWindowFlags.None) then
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
