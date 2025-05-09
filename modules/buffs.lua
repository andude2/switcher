-- buffs.lua
-- Handles buff/song display logic and settings

local mq = require 'mq'
local imgui = require 'ImGui'
local icons = require 'mq.Icons'
local utils = require 'switcher.modules.utils' -- Assuming utils.lua is in the same directory or Lua path

local M = {} -- Module table

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

M.settings = LoadSettings()
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
    imgui.SetWindowFontScale(M.settings.font / 10)
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
    local widgetSizes = WIDGET_SIZES[M.settings.font]
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

-- Main draw function for the buff section within the combined UI
function M.draw()
    -- Apply font scale for the entire buff section
    imgui.SetWindowFontScale(M.settings.font / 10)

    -- Draw settings menu (attached to the window background)
    M.buffWindow:DrawSettingsMenu()

    if imgui.BeginTabBar('BuffSortTabs') then
        local currentSort = M.buffWindow.settings.sortBy
        local newSort = currentSort
        local sortChanged = false

        if imgui.BeginTabItem('Slot') then
            if currentSort ~= SORT_BY_SLOT then newSort = SORT_BY_SLOT; sortChanged = true; end
            -- Content for Slot Tab
             M.buffWindow:DrawFavorites()
             M.buffWindow:DrawBuffTable() -- No color filter
            imgui.EndTabItem()
        end

        if imgui.BeginTabItem('Name') then
             if currentSort ~= SORT_BY_NAME then newSort = SORT_BY_NAME; sortChanged = true; end
             -- Content for Name Tab
             M.buffWindow:DrawFavorites()
             M.buffWindow:DrawBuffTable() -- No color filter
             imgui.EndTabItem()
        end

        if imgui.BeginTabItem('Type') then
             if currentSort ~= SORT_BY_TYPE then newSort = SORT_BY_TYPE; sortChanged = true; end
             -- Content for Type Tab (draw favorites first, then sections by color)
             M.buffWindow:DrawFavorites()
             -- Draw sections by color, applying filters
             imgui.TextDisabled("Detrimental") -- Header
             M.buffWindow:DrawBuffTable('red')
             imgui.TextDisabled("Short/Medium Duration")
             M.buffWindow:DrawBuffTable('green')
             imgui.TextDisabled("Long Duration")
             M.buffWindow:DrawBuffTable('blue')
             imgui.TextDisabled("Permanent / Very Long")
             M.buffWindow:DrawBuffTable('gray')
             imgui.TextDisabled("Other / Unknown Duration")
             M.buffWindow:DrawBuffTable('none')
             imgui.EndTabItem()
        end

        if sortChanged then
             M.buffWindow:SetSortMethod(newSort)
        end

        imgui.EndTabBar()
    end

    -- Restore default font scale after drawing the buff section
    imgui.SetWindowFontScale(1.0)
end

-- Update function to be called in the main loop
function M.update()
    if not M.buffWindow then return end -- Don't update if not initialized
    M.buffWindow:UpdateBuffs()
end

-- Initialize the buff window instance
function M.init()
     -- Ensure we have a valid name before loading/saving settings
     local charName = utils.safeTLO(mq.TLO.Me.Name, nil)
     if not charName then
         print('\ar[Buffs] Cannot initialize: Character not in game?\ax')
         return
     end
     M.settings = LoadSettings()
     SaveSettings()
     M.buffWindow = BuffWindow.new("Buffs", BUFFS, M.settings.buffWindow, 30)
     M.songWindow = BuffWindow.new("Songs", SONGS, M.settings.songWindow, 12)
end


return M