--[[
	AuctionatorShop.lua

	Shopping lists (Atr_SList) for the Buy tab, plus the Buy tab's search
	box wiring and the advanced-search dialog.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

Atr_SList = {}
Atr_SList.__index = Atr_SList

local SHOPPING_LIST_VISIBLE_ROWS = 15
local MAX_RECENT_SEARCHES = 50
local MAX_SHOPPING_LIST_ITEMS = 50

local currentShoppingList

-----------------------------------------
-- Atr_SList: one shopping list (or the special "Recent Searches" list)
-----------------------------------------

function Atr_ShoppingListsInit()
	for _, list in ipairs(AUCTIONATOR_SHOPPING_LISTS) do
		setmetatable(list, Atr_SList)
	end
end

local function SortShoppingListsByName(a, b)
	if a.isRecents then return true end
	if b.isRecents then return false end
	return string.lower(a.name) < string.lower(b.name)
end

function Atr_SList.create(name, isRecents)

	local list = setmetatable({}, Atr_SList)
	list.name = name
	list.items = {}

	if isRecents then
		list.isRecents = true
	end

	table.insert(AUCTIONATOR_SHOPPING_LISTS, list)
	table.sort(AUCTIONATOR_SHOPPING_LISTS, SortShoppingListsByName)
	Atr_DropDownSL_Initialize()

	return list
end

function Atr_SList:AddItem(itemName)

	if itemName == "" or itemName == nil then
		return
	end

	if self.isRecents then
		table.insert(self.items, 1, itemName)
		while #self.items > MAX_RECENT_SEARCHES do
			table.remove(self.items)
		end
	else
		table.insert(self.items, itemName)
		self.isSorted = false
	end
end

function Atr_SList:RemoveItem(itemName)
	for i, existingName in ipairs(self.items) do
		if zc.StringSame(existingName, itemName) then
			table.remove(self.items, i)
			return
		end
	end
end

function Atr_SList:FindItemIndex(itemName)
	for i, existingName in ipairs(self.items) do
		if zc.StringSame(itemName, existingName) then
			return i
		end
	end
	return 0
end

function Atr_SList:IsItemOnList(itemName)
	return self:FindItemIndex(itemName) > 0
end

local function SortAlphabetically(a, b)
	return string.lower(a) < string.lower(b)
end

function Atr_SList:DisplayX()

	currentShoppingList = self

	local currentPane = Atr_GetCurrentPane()

	if not (self.isRecents or self.isSorted) then
		self.isSorted = true
		table.sort(self.items, SortAlphabetically)
	end

	local numRows = #self.items

	FauxScrollFrame_Update(Atr_Hlist_ScrollFrame, numRows, SHOPPING_LIST_VISIBLE_ROWS, 16)

	for line = 1, SHOPPING_LIST_VISIBLE_ROWS do

		currentPane.hlistScrollOffset = FauxScrollFrame_GetOffset(Atr_Hlist_ScrollFrame)
		local dataOffset = line + currentPane.hlistScrollOffset

		local rowFrame = _G["AuctionatorHEntry" .. line]
		rowFrame:SetID(dataOffset)

		local itemName = self.items[dataOffset]

		if dataOffset <= numRows and itemName then

			local textFrame = _G["AuctionatorHEntry" .. line .. "_EntryText"]
			textFrame:SetText(Atr_AbbrevItemName(itemName))
			textFrame:SetTextColor(.6, .6, .6)

			local isSelected = (currentPane.activeSearch.originalSearchText ~= "" and zc.StringSame(itemName, currentPane.activeSearch.originalSearchText))
				or (currentPane.activeSearch.searchText == "" and zc.StringSame(itemName, Atr_Search_Box:GetText()))

			rowFrame:SetButtonState(isSelected and "PUSHED" or "NORMAL", isSelected)
			rowFrame:Show()
		else
			rowFrame:Hide()
		end
	end
end

function Atr_DisplaySlist()
	if currentShoppingList then
		currentShoppingList:DisplayX()
	end
end

-----------------------------------------
-- Search box handling
-----------------------------------------

function Atr_Search_Onclick()

	local currentPane = Atr_GetCurrentPane()
	local searchText = Atr_Search_Box:GetText()

	Atr_Search_Button:Disable()
	Atr_Adv_Search_Button:Disable()
	Atr_Buy1_Button:Disable()
	Atr_AddToSListButton:Disable()
	Atr_RemFromSListButton:Disable()

	Atr_ClearAll()

	currentPane:DoSearch(searchText)

	Atr_Process_Historydata()
end

-- Called once a Buy-tab search finishes: records it in the recent
-- searches list and refreshes the results UI.
function Atr_Shop_OnFinishScan()

	local currentPane = Atr_GetCurrentPane()
	local searchText = currentPane.activeSearch.originalSearchText

	Atr_Search_Box:SetText(searchText)

	local recentSearches = AUCTIONATOR_SHOPPING_LISTS[1]

	if recentSearches then

		local isRecentsShown = (currentShoppingList == recentSearches)
		local existingIndex = recentSearches:FindItemIndex(searchText)

		if existingIndex > 14 or (not isRecentsShown and existingIndex > 0) then
			table.remove(recentSearches.items, existingIndex)
		end

		if recentSearches:FindItemIndex(searchText) == 0 then
			recentSearches:AddItem(searchText)
		end

		if isRecentsShown then
			FauxScrollFrame_SetOffset(Atr_Hlist_ScrollFrame, 0)
		end
	end

	if #currentPane.activeScan.sortedData > 0 then
		currentPane.currIndex = 1
	end

	currentPane.UINeedsUpdate = true

	Atr_Search_Button:Enable()
	Atr_Adv_Search_Button:Enable()
end

function Atr_DropDownSL_OnLoad(self)
	UIDropDownMenu_Initialize(self, Atr_DropDownSL_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_DropDownSL, 1)
	Atr_DropDownSL:Show()
end

function Atr_DropDownSL_Initialize()

	local info = UIDropDownMenu_CreateInfo()

	for index, list in ipairs(AUCTIONATOR_SHOPPING_LISTS) do
		info.text    = list.name
		info.value   = index
		info.func    = Atr_DropDownSL_OnClick
		info.checked = nil
		info.owner   = this:GetParent()
		UIDropDownMenu_AddButton(info)
	end
end

function Atr_DropDownSL_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
	currentShoppingList = AUCTIONATOR_SHOPPING_LISTS[self.value]
	Atr_SetUINeedsUpdate()
end

function Atr_SEntryOnClick()

	local entryIndex = this:GetID()
	local itemName = currentShoppingList.items[entryIndex]

	Atr_Search_Box:SetText(itemName)

	if IsAltKeyDown() then
		Atr_GetCurrentPane():ClearSearch()
		Atr_RemFromSListOnClick()
	else
		Atr_Search_Onclick()
	end

	Atr_Shop_UpdateUI()
end

-----------------------------------------
-- New / delete shopping list dialogs
-----------------------------------------

local function FinishCreateNewShoppingList(name)

	local newList = Atr_SList.create(name)

	for index, list in ipairs(AUCTIONATOR_SHOPPING_LISTS) do
		if list == newList then
			UIDropDownMenu_SetSelectedValue(Atr_DropDownSL, index)
			UIDropDownMenu_SetText(Atr_DropDownSL, name) -- works around a UIDropDownMenu display bug
			newList:DisplayX()
			Atr_SetUINeedsUpdate()
			break
		end
	end
end

StaticPopupDialogs["ATR_NEW_SHOPPING_LIST"] = {
	text = "",
	button1 = ACCEPT,
	button2 = CANCEL,
	hasEditBox = 1,
	maxLetters = 32,
	OnAccept = function(self)
		FinishCreateNewShoppingList(self.editBox:GetText())
	end,
	EditBoxOnEnterPressed = function(self)
		FinishCreateNewShoppingList(self:GetParent().editBox:GetText())
		self:GetParent():Hide()
	end,
	OnShow = function(self)
		self.editBox:SetText("")
		self.editBox:SetFocus()
	end,
	timeout = 0,
	exclusive = 1,
	whileDead = 1,
	hideOnEscape = 1,
}

StaticPopupDialogs["ATR_DEL_SHOPPING_LIST"] = {
	text = "",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self)
		for index, list in ipairs(AUCTIONATOR_SHOPPING_LISTS) do
			if list == currentShoppingList then
				table.remove(AUCTIONATOR_SHOPPING_LISTS, index)
				currentShoppingList = AUCTIONATOR_SHOPPING_LISTS[1]
				UIDropDownMenu_SetSelectedValue(Atr_DropDownSL, 1)
				UIDropDownMenu_SetText(Atr_DropDownSL, currentShoppingList.name)
				Atr_SetUINeedsUpdate()
				return
			end
		end
	end,
	OnShow = function(self)
		local message = string.format(ZT("Really delete the shopping list %s ?"), ": \n\n" .. currentShoppingList.name)
		self.text:SetText("\n" .. message .. "\n\n")
	end,
	timeout = 0,
	exclusive = 1,
	whileDead = 1,
	hideOnEscape = 1,
}

function Atr_NewSlist_OnClick()
	StaticPopupDialogs["ATR_NEW_SHOPPING_LIST"].text = ZT("Name for your new shopping list")
	StaticPopup_Show("ATR_NEW_SHOPPING_LIST")
end

function Atr_DelSList_OnClick()
	StaticPopup_Show("ATR_DEL_SHOPPING_LIST")
end

function Atr_AddToSListOnClick()

	if not currentShoppingList then
		return
	end

	if #currentShoppingList.items >= MAX_SHOPPING_LIST_ITEMS then
		Atr_Error_Text:SetText(string.format(ZT("You may have no more than\n\n%d items on a shopping list."), MAX_SHOPPING_LIST_ITEMS))
		Atr_Error_Frame.withMask = 1
		Atr_Error_Frame:Show()
	else
		currentShoppingList:AddItem(Atr_Search_Box:GetText())
		Atr_SetUINeedsUpdate()
	end
end

function Atr_RemFromSListOnClick()
	if currentShoppingList then
		currentShoppingList:RemoveItem(Atr_Search_Box:GetText())
		Atr_SetUINeedsUpdate()
	end
end

function Atr_Shop_UpdateUI()

	local currentPane = Atr_GetCurrentPane()

	Atr_AddToSListButton:Disable()
	Atr_RemFromSListButton:Disable()
	Atr_DelSListButton:Disable()

	currentShoppingList = currentShoppingList or AUCTIONATOR_SHOPPING_LISTS[1]

	if currentShoppingList then

		currentShoppingList:DisplayX()

		local searchBoxText = Atr_Search_Box:GetText()

		if currentShoppingList:IsItemOnList(searchBoxText) then
			Atr_RemFromSListButton:Enable()
		elseif searchBoxText ~= "" and searchBoxText ~= nil and currentShoppingList ~= AUCTIONATOR_SHOPPING_LISTS[1] then
			Atr_AddToSListButton:Enable() -- can't add to (or delete) the built-in Recent Searches list
		end

		if currentShoppingList ~= AUCTIONATOR_SHOPPING_LISTS[1] then
			Atr_DelSListButton:Enable()
		end
	end

	if currentPane.activeSearch:NumScans() > 1 and not currentPane:IsScanEmpty() then
		Atr_Back_Button:Show()
	else
		Atr_Back_Button:Hide()
	end
end

-----------------------------------------
-- Advanced search dialog
-----------------------------------------

function Atr_Adv_Search_Onclick()

	local searchText = Atr_Search_Box:GetText()

	Atr_Adv_Search_Dialog:Show()

	if Atr_IsCompoundSearch(searchText) then

		local queryString, itemClass, itemSubclass, minLevel, maxLevel = Atr_ParseCompoundSearch(searchText)

		Atr_AS_Searchtext:SetText(queryString)

		UIDropDownMenu_SetSelectedValue(Atr_ASDD_Class, itemClass)
		Atr_ASDD_UpdateSubclassMenu()
		UIDropDownMenu_SetSelectedValue(Atr_ASDD_Subclass, itemSubclass)

		Atr_AS_Minlevel:SetText(minLevel or "")
		Atr_AS_Maxlevel:SetText(maxLevel or "")
	else
		Atr_AS_Searchtext:SetText(searchText)
	end
end

function Atr_ASDD_Class_OnLoad(self)
	UIDropDownMenu_Initialize(self, Atr_ASDD_Class_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_ASDD_Class, 0)
	Atr_ASDD_Class:Show()
end

function Atr_ASDD_Class_Initialize()

	Atr_Dropdown_AddPick(Atr_ASDD_Subclass, "-------", 0)

	local itemClasses = Atr_GetAuctionClasses()

	if #itemClasses > 0 then
		for index, text in pairs(itemClasses) do
			Atr_Dropdown_AddPick(this, text, index, Atr_ASDD_Class_OnClick)
		end
	end
end

function Atr_ASDD_Class_OnClick(info, frame)
	UIDropDownMenu_SetSelectedValue(frame, info.value)
	Atr_ASDD_UpdateSubclassMenu()
end

function Atr_ASDD_UpdateSubclassMenu()
	Atr_ASDD_Subclass:Hide()
	Atr_ASDD_Subclass_Initialize(Atr_ASDD_Subclass)
	Atr_ASDD_Subclass:Show()
end

function Atr_ASDD_Subclass_OnLoad(self)
	UIDropDownMenu_Initialize(self, Atr_ASDD_Subclass_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_ASDD_Subclass, 0)
	Atr_ASDD_Subclass:Show()
end

function Atr_ASDD_Subclass_Initialize()

	Atr_Dropdown_AddPick(Atr_ASDD_Subclass, "-------", 0)

	local itemClass = UIDropDownMenu_GetSelectedValue(Atr_ASDD_Class)

	if itemClass then
		local subclasses = Atr_GetAuctionSubclasses(itemClass)
		if #subclasses > 0 then
			for index, text in pairs(subclasses) do
				Atr_Dropdown_AddPick(Atr_ASDD_Subclass, text, index)
			end
		end
	end
end

function Atr_Adv_Search_Reset()

	Atr_AS_Searchtext:SetText("")

	UIDropDownMenu_SetSelectedValue(Atr_ASDD_Class, 0)
	Atr_ASDD_UpdateSubclassMenu()
	UIDropDownMenu_SetSelectedValue(Atr_ASDD_Subclass, 0)

	Atr_AS_Minlevel:SetText("")
	Atr_AS_Maxlevel:SetText("")
end

function Atr_Adv_Search_Do()

	local itemClass    = UIDropDownMenu_GetSelectedValue(Atr_ASDD_Class)
	local itemSubclass = UIDropDownMenu_GetSelectedValue(Atr_ASDD_Subclass)

	local itemClassNames    = Atr_GetAuctionClasses()
	local itemSubclassNames = Atr_GetAuctionSubclasses(itemClass)

	local searchText = itemClassNames[itemClass]

	if itemSubclass > 0 then
		searchText = searchText .. "/" .. itemSubclassNames[itemSubclass]
	end

	local minLevel = Atr_AS_Minlevel:GetNumber()
	local maxLevel = Atr_AS_Maxlevel:GetNumber()
	local freeText = Atr_AS_Searchtext:GetText()

	if maxLevel > 0 and minLevel == 0 then
		minLevel = 1
	end

	if minLevel > 0 then searchText = searchText .. "/" .. minLevel end
	if maxLevel > 0 then searchText = searchText .. "/" .. maxLevel end
	if freeText ~= "" then searchText = searchText .. "/" .. freeText end

	Atr_Search_Box:SetText(searchText)
	Atr_Search_Onclick()
	Atr_Adv_Search_Dialog:Hide()
end
