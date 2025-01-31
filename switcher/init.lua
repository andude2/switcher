local mq = require 'mq'
local imgui = require 'ImGui'

local DANNET = require 'lib.vs.DANNET'
if DANNET.checkVersion(1,1) == false then mq.exit() end

local TABLE = require 'lib.vs.TABLE'
if TABLE.checkVersion(1,0) == false then mq.exit() end

local OpenUI, ShowUI = true, true
local SwitcherName = 'Switcher'
local SwitcherVersion = '0.4'

local command_line_args = {...}
local first_imgui_frame = true
local peer_list_refreshed = false
local peer_list_last_refreshed = 0
local peer_list = {}
local peer_list_ui = {}
local peer_name_cache = {}
local observer_list = DANNET.newObserverList()

local NAME_QUERY = 'Me.CleanName'
local LEADER_QUERY = 'Group.Leader.CleanName'
local CLASS_QUERY = 'Me.Class.ShortName'
local HP_QUERY = 'Me.PctHPs'

-- Sorting Mode
local sort_mode = "Alphabetical"

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

-- Function to show tooltips
local function showToolTip(tooltip)
    if tooltip ~= nil and ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.TextUnformatted(tooltip)
        ImGui.EndTooltip()
    end
end

-- Refresh the peer list and apply sorting
local function refreshPeerList()
    if os.difftime(os.time(), peer_list_last_refreshed) == 0 then return end
    peer_list_last_refreshed = os.time()

    local peer_names = DANNET.getPeers()

    -- Populate cache if new peers detected
    for _, peer in ipairs(peer_names) do
        if peer_name_cache[peer] == nil then
            peer_name_cache[peer] = DANNET.query(peer, NAME_QUERY)
        end
    end

    -- Sorting based on selected mode
    if sort_mode == "Alphabetical" then
        table.sort(peer_names, function(a, b)
            return (peer_name_cache[a] or ""):lower() < (peer_name_cache[b] or ""):lower()
        end)
    elseif sort_mode == "Class" then
        table.sort(peer_names, function(a, b)
            local classA = DANNET.query(a, CLASS_QUERY) or ""
            local classB = DANNET.query(b, CLASS_QUERY) or ""
            return classA < classB
        end)
    end

    -- Update peer list
    DANNET.removeAll(observer_list)  -- Clear previous observers
    peer_list = {}

    for _, peer in ipairs(peer_names) do
        local name = peer_name_cache[peer]
        if name then
            local leader = DANNET.observe(peer, LEADER_QUERY)
            local hp = DANNET.query(peer, HP_QUERY) or 0
            table.insert(peer_list, { name = name, leader = leader, hp = tonumber(hp) })
        end
        DANNET.addPeer(observer_list, peer)
    end

    peer_list_refreshed = true
end

-- Update UI Peer List
local function updatePeerListUI()
    if peer_list_refreshed then
        peer_list_ui = TABLE.copy(peer_list)
        peer_list_refreshed = false
    end
end

-- Load script on all peers
local function button_LoadAll()
    if ImGui.SmallButton('Load All') then
        local x, y = ImGui.GetWindowPos()
        mq.cmdf('/dge /lua run %s %s %s', SwitcherName, x, y)
    end
    showToolTip('Load on all other peers at current position. Will not reload peers if they are already running.')
end

-- Unload script on all peers
local function button_UnloadAll()
    if ImGui.SmallButton('Unload All') then
        mq.cmdf('/dge /switcher unload')
    end
    showToolTip('Unload on all other peers. Use before "Load All" to reset positions.')
end

-- Switch focus to another EQ client
local function switchTo(name)
    if name and type(name) == 'string' then
        mq.cmdf('/dex %s /foreground', name)
    end
end

-- Face another player character
local function turnTo(name)
    if name and type(name) == 'string' then
        mq.cmdf('/multiline ; /tar PC %s; /face; /if (${Cursor.ID}) /click left target', name)
    end
end

-- Display Peer List in UI
local function show_Peers()
    updatePeerListUI()

    -- Table Headers
    if ImGui.BeginTable("##PeerTable", 2, ImGuiTableFlags.Resizable) then
        ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.WidthStretch)
        ImGui.TableSetupColumn("HP (%)", ImGuiTableColumnFlags.WidthFixed, 50)
        ImGui.TableHeadersRow()

        for _, peer in ipairs(peer_list_ui) do
            ImGui.TableNextRow()
            ImGui.TableNextColumn()

            if ImGui.Selectable(peer.name) then switchTo(peer.name) end
            if ImGui.IsItemClicked(ImGuiMouseButton.Right) then turnTo(peer.name) end
            showToolTip('Left-click to switch. Right-click to target.')

            ImGui.TableNextColumn()
            ImGui.Text(string.format("%.0f%%", peer.hp or 0))
        end
        ImGui.EndTable()
    end
end

-- Set UI Window Position on First Frame
local function firstFrameOnly()
    if first_imgui_frame then
        first_imgui_frame = false
        if command_line_args[1] and command_line_args[2] then
            local x, y = tonumber(command_line_args[1]), tonumber(command_line_args[2])
            if x >= 0 and y >= 0 then ImGui.SetNextWindowPos(x, y) end
        end
    end
end

-- Main UI Window
function SwitcherUI()
    if OpenUI then
        firstFrameOnly()
        ImGui.SetNextWindowBgAlpha(0.8)
        local window_flags = bit32.bor(ImGuiWindowFlags.Resizable, ImGuiWindowFlags.NoCollapse)
        OpenUI, ShowUI = ImGui.Begin(SwitcherName, OpenUI, window_flags)

        if ShowUI then
            button_LoadAll()
            ImGui.SameLine()
            button_UnloadAll()
            sortDropdown()  -- Sorting Dropdown
            show_Peers()
        end
        
        ImGui.End()
    end
end

-- Initialize Script
local function init()
    DANNET.addQuery(observer_list, LEADER_QUERY)
    mq.bind('/switcher', function() OpenUI = false end)
    mq.bind('/switchto', switchTo)
    mq.bind('/to', switchTo)
    mq.imgui.init(SwitcherName, SwitcherUI)
end

-- Main Loop
init()
while OpenUI and mq.TLO.MacroQuest.GameState() == 'INGAME' do
    refreshPeerList()
    mq.delay(100)
end
DANNET.removeAll(observer_list)
