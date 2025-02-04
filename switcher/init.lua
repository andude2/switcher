local mq = require 'mq'
local imgui = require 'ImGui'

if not mq.TLO.MQ2Mono then
    print('\arError: MQ2Mono plugin is not loaded. Please load it with /plugin MQ2Mono\ax')
    mq.exit()
end

local OpenUI, ShowUI = true, true
local SwitcherName = 'Switcher'
local SwitcherVersion = '2.4'

local peer_list = {}
local peer_map = {} -- Tracks peers by name for quick updates

-- 🔄 Refresh settings
local refreshInterval = 500 -- Refresh every 500ms (0.5 seconds)
local staleDataTimeout = 10 -- Remove peers if they haven't updated in 10 seconds

-- 🔄 Keeps track of when each peer was last updated
local lastUpdateTime = {}

-- Sorting Mode
local sort_mode = "Alphabetical"

-- Column Visibility (User Selectable)
local show_name = true
local show_hp = true
local show_class = true

-- 🔄 **Fix: Define switchTo function**
local function switchTo(name)
    if name and type(name) == 'string' then
        mq.cmdf('/dex %s /foreground', name)
    end
end

-- Function to show sorting dropdown in UI
local function sortDropdown()
    ImGui.Text("Sort by: ")
    ImGui.SameLine()
    if ImGui.BeginCombo("##SortMode", sort_mode) then
        if ImGui.Selectable("Alphabetical", sort_mode == "Alphabetical") then
            sort_mode = "Alphabetical"
        end
        if ImGui.Selectable("Class", sort_mode == "Class") then
            sort_mode = "Class"
        end
        ImGui.EndCombo()
    end
end

-- Function to show checkboxes for column visibility
local function columnSelection()
    ImGui.Text("Show Columns: ")
    show_name = ImGui.Checkbox("Name", show_name)
    ImGui.SameLine()
    show_hp = ImGui.Checkbox("HP (%)", show_hp)
    ImGui.SameLine()
    show_class = ImGui.Checkbox("Class", show_class)
end

-- Function to show tooltips
local function showToolTip(tooltip)
    if tooltip ~= nil and ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.TextUnformatted(tooltip)
        ImGui.EndTooltip()
    end
end

-- 🔄 **Refresh Peer List Using MQ2Mono**
local function refreshPeers()
    local currentTime = os.time()
    local myInstance = tostring(mq.TLO.Me.Instance()) -- Get the player's current instance as a string

    -- Get the list of all connected clients
    local clientList = mq.TLO.MQ2Mono.Query("e3,E3Bots.ConnectedClients")()
    
    if not clientList or clientList == "" then
        return
    end

    -- Convert the comma-separated list into a Lua table
    local peer_names = {}
    for botName in string.gmatch(clientList, "([^,]+)") do
        table.insert(peer_names, botName)
    end

    -- Process each peer in the list
    for _, peer in ipairs(peer_names) do
        local name = mq.TLO.MQ2Mono.Query(string.format("e3,E3Bots(%s).Query(Name)", peer))() or peer
        local leader = mq.TLO.MQ2Mono.Query(string.format("e3,E3Bots(%s).Leader", peer))() or "N/A"
        local hp = mq.TLO.MQ2Mono.Query(string.format("e3,E3Bots(%s).PctHPs", peer))() or 0
        local class = mq.TLO.MQ2Mono.Query(string.format("e3,E3Bots(%s).Query(Class)", peer))() or "Unknown"
        local instance = tostring(mq.TLO.MQ2Mono.Query(string.format("e3,E3Bots(%s).Instance", peer))() or "Unknown")

        -- Determine if the peer is in the same zone
        local inSameZone = (instance == myInstance)

        -- Update or add the peer in the peer_map
        if not peer_map[name] or peer_map[name].hp ~= hp or peer_map[name].class ~= class or peer_map[name].inSameZone ~= inSameZone then
            peer_map[name] = { name = name, leader = leader, hp = tonumber(hp), class = class, inSameZone = inSameZone }
        end

        -- Update the timestamp for this peer
        lastUpdateTime[name] = currentTime
    end

    -- Remove stale peers from peer_map
    for name, lastSeen in pairs(lastUpdateTime) do
        if os.difftime(currentTime, lastSeen) > staleDataTimeout then
            peer_map[name] = nil
            lastUpdateTime[name] = nil
        end
    end

    -- Update the peer_list for display purposes
    peer_list = {}
    for _, peer in pairs(peer_map) do
        table.insert(peer_list, peer)
    end

    -- Sort the peer_list
    if sort_mode == "Alphabetical" then
        table.sort(peer_list, function(a, b) return a.name:lower() < b.name:lower() end)
    elseif sort_mode == "Class" then
        table.sort(peer_list, function(a, b) return a.class < b.class end)
    end
end

-- Display Peer List in UI
local function show_Peers()
    -- Table Headers
    if ImGui.BeginTable("##PeerTable", 3, ImGuiTableFlags.Resizable) then
        if show_name then ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch) end
        if show_hp then ImGui.TableSetupColumn("HP (%)", ImGuiTableColumnFlags.WidthFixed, 50) end
        if show_class then ImGui.TableSetupColumn("Class", ImGuiTableColumnFlags.WidthFixed, 50) end
        ImGui.TableHeadersRow()

        for _, peer in ipairs(peer_list) do
            ImGui.TableNextRow()

            if show_name then
                ImGui.TableNextColumn()
                -- Apply color based on zone status
                if peer.inSameZone then
                    ImGui.PushStyleColor(ImGuiCol.Text, 0, 1, 0, 1) -- Green for same zone
                else
                    ImGui.PushStyleColor(ImGuiCol.Text, 1, 0, 0, 1) -- Red for different zone
                end

                if ImGui.Selectable(peer.name) then switchTo(peer.name) end
                showToolTip('Left-click to switch.')

                ImGui.PopStyleColor() -- Revert to default color
            end

            if show_hp then
                ImGui.TableNextColumn()
                ImGui.Text(string.format("%.0f%%", peer.hp or 0))
            end

            if show_class then
                ImGui.TableNextColumn()
                ImGui.Text(peer.class)
            end
        end
        ImGui.EndTable()
    end
end

-- Main UI Window
function SwitcherUI()
    if OpenUI then
        ImGui.SetNextWindowBgAlpha(0.8)
        local window_flags = bit32.bor(ImGuiWindowFlags.Resizable, ImGuiWindowFlags.NoCollapse)
        OpenUI, ShowUI = ImGui.Begin(SwitcherName, OpenUI, window_flags)

        if ShowUI then
            columnSelection()
            show_Peers()
            sortDropdown()
        end
        
        ImGui.End()
    end
end

-- **Run the Peer Refresh in a Separate Loop**
local function eventLoop()
    while OpenUI and mq.TLO.MacroQuest.GameState() == 'INGAME' do
        refreshPeers() -- Updates in real-time using MQ2Mono
        mq.delay(refreshInterval) -- Controls refresh speed
    end
end

-- Initialize Script
local function init()
    mq.imgui.init(SwitcherName, SwitcherUI)
    eventLoop()
end

init()
