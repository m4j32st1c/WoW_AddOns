--[[
	AuctionatorConfig.lua

	Wires up all the Blizzard-style interface-options sub-panels defined
	in AuctionatorConfig.xml: basic options, tooltips, undercutting,
	per-item stacking preferences, scan quality threshold, and the About
	panel.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

-----------------------------------------
-- Panel registration helpers
-----------------------------------------

function Atr_LoadOptionsSubPanel(panel, name, title, subtitle)

	panel.name   = name
	panel.parent = "Auctionator"
	panel.cancel = Atr_Options_Cancel

	local frameName = panel:GetName()
	panel.okay = _G[frameName .. "_Save"]

	_G[frameName .. "_ATitle"]:SetText(title or name)
	_G[frameName .. "_BTitle"]:SetText(subtitle or "")

	InterfaceOptions_AddCategory(panel)
end

function Atr_Options_Cancel()
	Atr_InitOptionsPanels()
end

function Atr_InitOptionsPanels()

	if AUCTIONATOR_SAVEDVARS == nil then
		Atr_ResetSavedVars()
	end

	Atr_SetupBasicOptionsFrame()
	Atr_SetupTooltipsOptionsFrame()
	Atr_SetupUCConfigFrame()
	Atr_SetupStackingFrame()
	Atr_SetupOptionsFrame()
	Atr_SetupScanningConfigFrame()
end

-----------------------------------------
-- About panel
-----------------------------------------

function Atr_SetupOptionsFrame()

	local aboutHTML = "<html><body>"
		.. "<p>" .. ZT("The latest information on Auctionator can be found at") .. " auctionator-addon.com.</p>"
		.. "</body></html>"

	AuctionatorDescriptionHTML:SetText(aboutHTML)
	AuctionatorDescriptionHTML:SetSpacing(3)

	AuctionatorVersionText:SetText(ZT("Version") .. ": " .. AuctionatorVersion)
end

-----------------------------------------
-- Basic options
-----------------------------------------

function Atr_SetDurationOptionRB(radioButtonName)
	Atr_RB_S:SetChecked(zc.StringEndsWith(radioButtonName, "S"))
	Atr_RB_M:SetChecked(zc.StringEndsWith(radioButtonName, "M"))
	Atr_RB_L:SetChecked(zc.StringEndsWith(radioButtonName, "L"))
end

function Atr_BasicOptionsFrame_Save()

	local before = zc.msg_str(AUCTIONATOR_ENABLE_ALT, AUCTIONATOR_OPEN_ALL_BAGS, AUCTIONATOR_SHOW_ST_PRICE,
		AUCTIONATOR_DEFTAB, AUCTIONATOR_DEF_DURATION, AUCTIONATOR_ROMOVE_BLOOFORGED, AUCTIONATOR_ROMOVE_SUFFIX)

	AUCTIONATOR_ENABLE_ALT        = zc.BoolToNum(AuctionatorOption_Enable_Alt_CB:GetChecked())
	AUCTIONATOR_OPEN_ALL_BAGS     = zc.BoolToNum(AuctionatorOption_Open_All_Bags_CB:GetChecked())
	AUCTIONATOR_SHOW_ST_PRICE     = zc.BoolToNum(AuctionatorOption_Show_StartingPrice_CB:GetChecked())
	AUCTIONATOR_ROMOVE_BLOOFORGED = zc.BoolToNum(AuctionatorOption_Remove_Bloodforge_CB:GetChecked())
	AUCTIONATOR_ROMOVE_SUFFIX     = zc.BoolToNum(AuctionatorOption_Remove_Suffix_CB:GetChecked())
	AUCTIONATOR_DEFTAB            = UIDropDownMenu_GetSelectedValue(AuctionatorOption_Deftab)

	AUCTIONATOR_DEF_DURATION = "N"
	if AuctionatorOption_Def_Duration_CB:GetChecked() then
		if Atr_RB_S:GetChecked() then AUCTIONATOR_DEF_DURATION = "S" end
		if Atr_RB_M:GetChecked() then AUCTIONATOR_DEF_DURATION = "M" end
		if Atr_RB_L:GetChecked() then AUCTIONATOR_DEF_DURATION = "L" end
	end

	local after = zc.msg_str(AUCTIONATOR_ENABLE_ALT, AUCTIONATOR_OPEN_ALL_BAGS, AUCTIONATOR_SHOW_ST_PRICE,
		AUCTIONATOR_DEFTAB, AUCTIONATOR_DEF_DURATION, AUCTIONATOR_ROMOVE_BLOOFORGED, AUCTIONATOR_ROMOVE_SUFFIX)

	if before ~= after then
		zc.msg_atr(ZT("basic options saved"))
	end

	Atr_ShowHide_StartingPrice()
end

function Atr_SetupBasicOptionsFrame()

	Atr_BasicOptionsFrame_BTitle:SetText(string.format(ZT("Basic Options for %s"), "|cffffff55" .. UnitName("player")))

	AuctionatorOption_Enable_Alt_CB:SetChecked(zc.NumToBool(AUCTIONATOR_ENABLE_ALT))
	AuctionatorOption_Open_All_Bags_CB:SetChecked(zc.NumToBool(AUCTIONATOR_OPEN_ALL_BAGS))
	AuctionatorOption_Show_StartingPrice_CB:SetChecked(zc.NumToBool(AUCTIONATOR_SHOW_ST_PRICE))
	AuctionatorOption_Remove_Bloodforge_CB:SetChecked(zc.NumToBool(AUCTIONATOR_ROMOVE_BLOOFORGED))
	AuctionatorOption_Remove_Suffix_CB:SetChecked(zc.NumToBool(AUCTIONATOR_ROMOVE_SUFFIX))

	UIDropDownMenu_Initialize(AuctionatorOption_Deftab, AuctionatorOption_Deftab_Initialize)
	UIDropDownMenu_SetSelectedValue(AuctionatorOption_Deftab, AUCTIONATOR_DEFTAB)

	AuctionatorOption_Def_Duration_CB:SetChecked(
		AUCTIONATOR_DEF_DURATION == "S" or AUCTIONATOR_DEF_DURATION == "M" or AUCTIONATOR_DEF_DURATION == "L")

	Atr_SetDurationOptionRB(AUCTIONATOR_DEF_DURATION)
end

function AuctionatorOption_Deftab_Initialize()
	local info = UIDropDownMenu_CreateInfo()
	Atr_AddMenuPick(info, ZT("None"), 0, AuctionatorOption_Deftab_OnClick)
	Atr_AddMenuPick(info, ZT("Sell"), 1, AuctionatorOption_Deftab_OnClick)
	Atr_AddMenuPick(info, ZT("Buy"),  2, AuctionatorOption_Deftab_OnClick)
	Atr_AddMenuPick(info, ZT("More"), 3, AuctionatorOption_Deftab_OnClick)
end

function AuctionatorOption_Deftab_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
end

function Atr_Option_OnClick(checkbox)

	-- "Open on Buy" and "Open on Sell" are mutually exclusive.
	if zc.StringContains(checkbox:GetName(), "Open_BUY") and checkbox:GetChecked() then
		AuctionatorOption_Open_SELL_CB:SetChecked(false)
	end

	if zc.StringContains(checkbox:GetName(), "Open_SELL") and checkbox:GetChecked() then
		AuctionatorOption_Open_BUY_CB:SetChecked(false)
	end
end

-----------------------------------------
-- Tooltip options
-----------------------------------------

function Atr_SetupTooltipsOptionsFrame()

	ATR_tipsAuctionOpt_CB:SetChecked(zc.NumToBool(AUCTIONATOR_A_TIPS))
	ATR_tipsDisenchantOpt_CB:SetChecked(zc.NumToBool(AUCTIONATOR_D_TIPS))

	UIDropDownMenu_Initialize(Atr_tipsShiftDD, Atr_tipsShiftDD_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_tipsShiftDD, AUCTIONATOR_SHIFT_TIPS)

	UIDropDownMenu_Initialize(Atr_deDetailsDD, Atr_deDetailsDD_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_deDetailsDD, AUCTIONATOR_DE_DETAILS_TIPS)
end

function Atr_TooltipsOptionsFrame_Save()

	local before = zc.msg_str(AUCTIONATOR_V_TIPS, AUCTIONATOR_A_TIPS, AUCTIONATOR_D_TIPS, AUCTIONATOR_SHIFT_TIPS, AUCTIONATOR_DE_DETAILS_TIPS)

	AUCTIONATOR_A_TIPS          = zc.BoolToNum(ATR_tipsAuctionOpt_CB:GetChecked())
	AUCTIONATOR_D_TIPS          = zc.BoolToNum(ATR_tipsDisenchantOpt_CB:GetChecked())
	AUCTIONATOR_SHIFT_TIPS      = UIDropDownMenu_GetSelectedValue(Atr_tipsShiftDD)
	AUCTIONATOR_DE_DETAILS_TIPS = UIDropDownMenu_GetSelectedValue(Atr_deDetailsDD)

	local after = zc.msg_str(AUCTIONATOR_V_TIPS, AUCTIONATOR_A_TIPS, AUCTIONATOR_D_TIPS, AUCTIONATOR_SHIFT_TIPS, AUCTIONATOR_DE_DETAILS_TIPS)

	if before ~= after then
		zc.msg_atr(ZT("tooltip configuration saved"))
	end
end

function Atr_tipsShiftDD_Initialize()
	local info = UIDropDownMenu_CreateInfo()
	Atr_AddMenuPick(info, ZT("stack price"),     1, Atr_tipsShiftDD_OnClick)
	Atr_AddMenuPick(info, ZT("per item price"),  2, Atr_tipsShiftDD_OnClick)
end

function Atr_tipsShiftDD_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
end

function Atr_deDetailsDD_Initialize()
	local info = UIDropDownMenu_CreateInfo()
	Atr_AddMenuPick(info, ZT("when SHIFT is held down"),   1, Atr_deDetailsDD_OnClick)
	Atr_AddMenuPick(info, ZT("when CONTROL is held down"), 2, Atr_deDetailsDD_OnClick)
	Atr_AddMenuPick(info, ZT("when ALT is held down"),     3, Atr_deDetailsDD_OnClick)
	Atr_AddMenuPick(info, ZT("never"),                     4, Atr_deDetailsDD_OnClick)
	Atr_AddMenuPick(info, ZT("always"),                    5, Atr_deDetailsDD_OnClick)
end

function Atr_deDetailsDD_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
end

-----------------------------------------
-- Undercutting configuration
-----------------------------------------

-- Threshold rows shown on the Undercutting options screen, from highest
-- price bracket to lowest.
local UNDERCUT_THRESHOLDS = {
	{ amount = 5000000, labelFormat = ZT("over %d gold"),   labelValue = 500 },
	{ amount = 1000000, labelFormat = ZT("over %d gold"),   labelValue = 100 },
	{ amount = 200000,  labelFormat = ZT("over %d gold"),   labelValue = 20 },
	{ amount = 50000,   labelFormat = ZT("over %d gold"),   labelValue = 5 },
	{ amount = 10000,   labelFormat = ZT("over 1 gold"),    labelValue = 1 },
	{ amount = 2000,    labelFormat = ZT("over %d silver"), labelValue = 20 },
	{ amount = 500,     labelFormat = ZT("over %d silver"), labelValue = 5 },
}

function Atr_SetupUCConfigFrame()

	for _, threshold in ipairs(UNDERCUT_THRESHOLDS) do
		local lineText = string.format(threshold.labelFormat, threshold.labelValue)
		_G["UC_" .. threshold.amount .. "_RangeText"]:SetText(lineText)
		MoneyInputFrame_SetCopper(_G["UC_" .. threshold.amount .. "_MoneyInput"], AUCTIONATOR_SAVEDVARS["_" .. threshold.amount])
	end

	Atr_Starting_Discount:SetText(AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT)
end

function Atr_UCConfigFrame_Save()

	local before = AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT
	AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT = Atr_Starting_Discount:GetNumber()
	local after = AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT

	for _, threshold in ipairs(UNDERCUT_THRESHOLDS) do
		local key = "_" .. threshold.amount
		before = before + AUCTIONATOR_SAVEDVARS[key]
		AUCTIONATOR_SAVEDVARS[key] = MoneyInputFrame_GetCopper(_G["UC_" .. threshold.amount .. "_MoneyInput"])
		after = after + AUCTIONATOR_SAVEDVARS[key]
	end

	if before ~= after then
		zc.msg_atr(ZT("undercutting configuration saved"))
	end
end

-----------------------------------------
-- Per-item / per-category stacking preferences
-----------------------------------------

-- Categories with a built-in stacking default that the user can override.
kStackList_categories = {
	[ATR_SK_GLYPHS]     = { txt = ZT("Glyphs") },
	[ATR_SK_GEMS_CUT]   = { txt = ZT("Gems - Cut") },
	[ATR_SK_GEMS_UNCUT] = { txt = ZT("Gems - Uncut") },
	[ATR_SK_ITEM_ENH]   = { txt = ZT("Item Enhancements") },
	[ATR_SK_POT_ELIX]   = { txt = ZT("Potions and Elixirs") },
	[ATR_SK_FLASKS]     = { txt = ZT("Flasks") },
	[ATR_SK_HERBS]      = { txt = ZT("Herbs") },
}

local STACK_LIST_VISIBLE_ROWS = 12
local selectedStackListIndex = 0
local currentStackList -- the sorted display list currently shown, rebuilt by Atr_StackingList_Display

local function BuildStackListEntry(sortKey, displayText, numStacks, stackSize)
	return { sortKey = sortKey, text = displayText, numStacks = numStacks, stackSize = stackSize }
end

local function SortStackListEntries(a, b)
	return a.sortKey < b.sortKey
end

function Atr_SetupStackingFrame()

	if _G["Atr_StackList1"] == nil then
		for i = 1, STACK_LIST_VISIBLE_ROWS do
			local yOffset = -5 - ((i - 1) * 16)
			local row = CreateFrame("BUTTON", "Atr_StackList" .. i, Atr_Stacking_List, "Atr_StackingEntryTemplate")
			row:SetPoint("TOP", 0, yOffset)
		end
	end

	Atr_StackingList_Display()
end

function Atr_StackingList_Display()

	currentStackList = {}

	for _, categoryInfo in pairs(kStackList_categories) do
		categoryInfo.overrideFound = false
	end

	local i = 1

	-- User-defined overrides (both for specific item names and for the
	-- built-in categories above).
	for key, prefs in pairs(AUCTIONATOR_STACKING_PREFS) do
		if prefs.numStacks ~= 0 then

			local sortKey = key
			local displayText = key

			if kStackList_categories[key] then
				kStackList_categories[key].overrideFound = true
				displayText = kStackList_categories[key].txt
			end

			currentStackList[i] = BuildStackListEntry(sortKey, displayText, prefs.numStacks, prefs.stackSize)
			i = i + 1
		end
	end

	-- Categories still on their default behavior.
	for sortKey, categoryInfo in pairs(kStackList_categories) do
		if not categoryInfo.overrideFound then
			currentStackList[i] = BuildStackListEntry(sortKey, categoryInfo.txt, -2, 0)
			i = i + 1
		end
	end

	table.sort(currentStackList, SortStackListEntries)

	local totalRows = #currentStackList

	FauxScrollFrame_Update(Atr_Stacking_ScrollFrame, totalRows, STACK_LIST_VISIBLE_ROWS, 16)

	for line = 1, STACK_LIST_VISIBLE_ROWS do

		local dataOffset = line + FauxScrollFrame_GetOffset(Atr_Stacking_ScrollFrame)
		local rowFrame = _G["Atr_StackList" .. line]
		rowFrame:SetID(dataOffset)

		if dataOffset <= totalRows and currentStackList[dataOffset] then

			local entry = currentStackList[dataOffset]
			local textFrame = _G["Atr_StackList" .. line .. "_text"]
			local infoFrame = _G["Atr_StackList" .. line .. "_info"]

			local highlightPrefix = (entry.text == entry.sortKey) and "" or "|cffffff88"
			textFrame:SetText(highlightPrefix .. entry.text)

			local infoText
			if entry.numStacks == -2 then     infoText = "|cff777777" .. ZT("default behavior")
			elseif entry.numStacks == -1 then infoText = string.format(ZT("max. stacks of %d"), entry.stackSize)
			elseif entry.stackSize == 0 then  infoText = "1 " .. ZT("stack")
			elseif entry.numStacks == 0 then  infoText = ZT("stacks of") .. " " .. entry.stackSize
			else                              infoText = entry.numStacks .. " " .. ZT("stacks of") .. " " .. entry.stackSize
			end

			infoFrame:SetText(infoText)

			if selectedStackListIndex == dataOffset then
				rowFrame:SetButtonState("PUSHED", true)
			else
				rowFrame:SetButtonState("NORMAL", false)
			end

			rowFrame:Show()
		else
			rowFrame:Hide()
		end
	end

	zc.EnableDisable(Atr_StackingOptionsFrame_Edit, selectedStackListIndex > 0)
end

function Atr_StackingEntry_OnClick(self)
	selectedStackListIndex = self:GetID()
	Atr_StackingList_Display()
end

function Atr_StackingEntry_OnDoubleClick(self)
	Atr_StackingEntry_OnClick(self)
	Atr_StackingList_Edit_OnClick()
end

function Atr_Memorize_Show(isNewEntry)

	local numStacks = -1
	local stackSize = 1

	zc.ShowHide(Atr_Mem_itemName_static, not isNewEntry)
	zc.ShowHide(Atr_Mem_EB_itemName, isNewEntry)
	zc.ShowHide(Atr_Mem_Forget, not isNewEntry)

	Atr_MemorizeFrame.isCategory = false

	if not isNewEntry then

		local entry = currentStackList[selectedStackListIndex]

		Atr_Mem_itemName_static:SetText(entry.text)
		stackSize = entry.stackSize
		numStacks = entry.numStacks

		local isCategory = (entry.sortKey ~= entry.text)
		Atr_MemorizeFrame.isCategory = isCategory

		if isCategory and numStacks == -2 then
			numStacks = -1
			stackSize = 1
		end

		zc.SetTextIf(Atr_Mem_itemName_text, isCategory, ZT("Category"), ZT("Item Name"))
		zc.SetTextIf(Atr_Mem_Forget, isCategory, ZT("Reset to Default"), ZT("Forget this Item"))
	end

	Atr_Mem_EB_stackSize:SetText(stackSize)

	UIDropDownMenu_Initialize(Atr_Mem_DD_numStacks, Atr_SONumStacks_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_Mem_DD_numStacks, numStacks)

	Atr_Mem_EB_itemName:SetText("")

	ShowInterfaceOptionsMask()
	Atr_MemorizeFrame:Show()
end

function Atr_StackingList_Edit_OnClick()
	Atr_Memorize_Show(false)
end

function Atr_StackingList_New_OnClick()
	Atr_Memorize_Show(true)
end

function Atr_Memorize_Save()

	local entry = currentStackList[selectedStackListIndex]
	local key = Atr_Mem_EB_itemName:GetText()

	if key == nil or key == "" then
		key = entry.sortKey
	end

	if key and key ~= "" then
		Atr_Set_StackingPrefs_numstacks(key, UIDropDownMenu_GetSelectedValue(Atr_Mem_DD_numStacks))
		Atr_Set_StackingPrefs_stacksize(key, Atr_Mem_EB_stackSize:GetNumber())
	end

	Atr_StackingList_Display()
end

function Atr_Memorize_Forget()

	local entry = currentStackList[selectedStackListIndex]

	if entry.sortKey then
		Atr_Clear_StackingPrefs(entry.sortKey)
	end

	if not Atr_MemorizeFrame.isCategory then
		selectedStackListIndex = 0
	end

	Atr_StackingList_Display()
end

function Atr_SONumStacks_OnLoad(self)
	UIDropDownMenu_Initialize(self, Atr_SONumStacks_Initialize)
	UIDropDownMenu_SetSelectedValue(self, -1)
	UIDropDownMenu_JustifyText(self, "CENTER")
	UIDropDownMenu_SetWidth(self, 150)
end

function Atr_SONumStacks_Initialize()
	local info = UIDropDownMenu_CreateInfo()
	Atr_AddMenuPick(info, ZT("As many as possible"), -1, Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "1",  1,  Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "2",  2,  Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "3",  3,  Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "4",  4,  Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "5",  5,  Atr_SONumStacks_OnClick)
	Atr_AddMenuPick(info, "10", 10, Atr_SONumStacks_OnClick)
end

function Atr_SONumStacks_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
	Atr_Mem_stacksOf_text:SetText(ZT((self.value == 1) and "stack of" or "stacks of"))
end

-----------------------------------------
-- Tooltip help text for the Basic Options screen
-----------------------------------------

local OPTION_TOOLTIPS = {
	{ match = "Enable_Alt",    text = ZT("If this option is checked, holding the Alt key down while clicking an item in your bags will switch to the Auctionator panel, place the item in the Auction Item area, and start the scan.") },
	{ match = "Deftab",        text = ZT("Select the Auctionator panel to be displayed first whenever you open the Auction House window.") },
	{ match = "Open_BUY",      text = ZT("If this option is checked, the Auctionator BUY panel will display first whenever you open the Auction House window.") },
	{ match = "Open_All_Bags", text = ZT("If this option is checked, ALL your bags will be opened when you first open the Auctionator panel.") },
	{ match = "Def_Duration",  text = ZT("If this option is checked, every time you initiate a new auction the auction duration will be reset to the default duration you've selected.") },
}

function Atr_ShowOptionTooltip(element)

	local frameName = element:GetName()
	local tooltipText

	for _, entry in ipairs(OPTION_TOOLTIPS) do
		if zc.StringContains(frameName, entry.match) then
			tooltipText = entry.text
			break
		end
	end

	if tooltipText then
		local titleFrame = _G[frameName .. "_CB_Text"] or _G[frameName .. "_Text"]
		local titleText = titleFrame and titleFrame:GetText() or "???"

		GameTooltip:SetOwner(this, "ANCHOR_LEFT")
		GameTooltip:SetText(titleText, 0.9, 1.0, 1.0)
		GameTooltip:AddLine(tooltipText, 0.5, 0.5, 1.0, 1)
		GameTooltip:Show()
	end
end

-----------------------------------------
-- Scanning (minimum quality level) options
-----------------------------------------

function Atr_SetupScanningConfigFrame()
	UIDropDownMenu_Initialize(Atr_scanLevelDD, Atr_scanLevelDD_Initialize)
	UIDropDownMenu_SetSelectedValue(Atr_scanLevelDD, AUCTIONATOR_SCAN_MINLEVEL)
end

function Atr_ScanningOptionsFrame_Save()

	local before = zc.msg_str(AUCTIONATOR_SCAN_MINLEVEL)
	AUCTIONATOR_SCAN_MINLEVEL = UIDropDownMenu_GetSelectedValue(Atr_scanLevelDD)
	local after = zc.msg_str(AUCTIONATOR_SCAN_MINLEVEL)

	if before ~= after then
		zc.msg_atr(ZT("scanning options saved"))
	end
end

function Atr_scanLevelDD_Initialize()
	local info = UIDropDownMenu_CreateInfo()
	Atr_AddMenuPick(info, "|cffa335ee" .. ZT("Epic") .. "|r",        5, Atr_scanLevelDD_OnClick)
	Atr_AddMenuPick(info, "|cff0070dd" .. ZT("Rare") .. "|r",        4, Atr_scanLevelDD_OnClick)
	Atr_AddMenuPick(info, "|cff1eff00" .. ZT("Uncommon") .. "|r",    3, Atr_scanLevelDD_OnClick)
	Atr_AddMenuPick(info, "|cffffffff" .. ZT("Common") .. "|r",      2, Atr_scanLevelDD_OnClick)
	Atr_AddMenuPick(info, "|cff9d9d9d" .. ZT("Poor (all)") .. "|r",  1, Atr_scanLevelDD_OnClick)
end

function Atr_scanLevelDD_OnClick(self)
	UIDropDownMenu_SetSelectedValue(self.owner, self.value)
end

function Atr_scanLevelDD_showTip()
	GameTooltip:SetOwner(this, "ANCHOR_LEFT")
	GameTooltip:SetText(ZT("Minimum Quality Level"), 0.9, 1.0, 1.0)
	GameTooltip:AddLine(ZT("Only include items in the scanning database that are this level or higher"), 0.5, 0.5, 1.0, 1)
	GameTooltip:Show()
end

-----------------------------------------
-- Interface-options frame styling / masking
-----------------------------------------

function Atr_MakeOptionsFrameOpaque()

	InterfaceOptionsFrame:SetBackdrop({
		bgFile = "Interface/RAIDFRAME/UI-RaidFrame-GroupBg",
		edgeFile = "Interface/DialogFrame/UI-DialogBox-Border",
		tile = false,
		edgeSize = 32,
		insets = { left = 11, right = 11, top = 10, bottom = 10 },
	})

	local listBackdrop = {
		bgFile = "Interface/CharacterFrame/UI-Party-Background",
		tile = true,
		insets = { left = 5, right = 5, top = 5, bottom = 5 },
	}

	InterfaceOptionsFrameAddOns:SetBackdrop(listBackdrop)
	InterfaceOptionsFrameCategories:SetBackdrop(listBackdrop)
end

local interfaceOptionsMask

function ShowInterfaceOptionsMask()

	if interfaceOptionsMask == nil then
		interfaceOptionsMask = CreateFrame("Frame", "Atr_Mask_StdOptions", InterfaceOptionsFrame, "Atr_Mask_StdOptionsTempl")
		interfaceOptionsMask:SetFrameLevel(129)
	end

	interfaceOptionsMask:Show()
end

function HideInterfaceOptionsMask()
	if interfaceOptionsMask then
		interfaceOptionsMask:Hide()
	end
end
