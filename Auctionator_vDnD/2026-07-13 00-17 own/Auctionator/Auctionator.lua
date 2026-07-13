--[[
	Auctionator.lua

	The core of the addon: event registration/dispatch, the three
	Auctionator tabs (Sell/Buy/More), auction-house hook functions,
	pricing recommendations, purchase/sale history, and per-item
	stacking preferences.

	Public Atr_* function names are kept stable because Auctionator.xml
	and AuctionatorConfig.xml call them directly by name.
]]

AuctionatorVersion = "???" -- populated from the .toc on load
AuctionatorAuthor  = "Zirco"

local addonInitialized = false

local addonName, addonTable = ...
local zc = addonTable.zc

-----------------------------------------
-- Saved-variable defaults
-----------------------------------------

AUCTIONATOR_ENABLE_ALT        = 1
AUCTIONATOR_OPEN_ALL_BAGS     = 1
AUCTIONATOR_SHOW_ST_PRICE     = 0
AUCTIONATOR_ROMOVE_BLOOFORGED = 1
AUCTIONATOR_ROMOVE_SUFFIX     = 1
AUCTIONATOR_SHOW_TIPS         = 1
AUCTIONATOR_DEF_DURATION      = "N" -- none
AUCTIONATOR_V_TIPS            = 1
AUCTIONATOR_A_TIPS            = 1
AUCTIONATOR_D_TIPS            = 1
AUCTIONATOR_SHIFT_TIPS        = 1
AUCTIONATOR_DE_DETAILS_TIPS   = 4 -- off by default
AUCTIONATOR_DEFTAB            = 1

-- Obsolete: kept only so old SavedVariables can migrate cleanly.
AUCTIONATOR_OPEN_FIRST = 0
AUCTIONATOR_OPEN_BUY   = 0

local SELL_TAB = 1
local MORE_TAB = 2
local BUY_TAB  = 3

local MODE_LIST_ACTIVE = 1
local MODE_LIST_ALL    = 2

local ITEM_HIST_NUM_LINES = 20
local MAX_SINGLE_STACK_AUCTIONS = 40 -- Blizzard's server-side limit for x1 stacks of one item

local DEFAULT_UNDERCUT_AMOUNTS = {
	["_5000000"] = 10000,
	["_1000000"] = 2500,
	["_200000"]  = 1000,
	["_50000"]   = 500,
	["_10000"]   = 200,
	["_2000"]    = 100,
	["_500"]     = 5,
	["STARTING_DISCOUNT"] = 5, -- percent
}

-----------------------------------------
-- Hook originals
-----------------------------------------

local original_AuctionFrameTab_OnClick
local original_ContainerFrameItemButton_OnModifiedClick
local original_AuctionFrameAuctions_Update
local original_CanShowRightUIPanel
local original_ChatEdit_InsertLink
local original_ChatFrame_OnEvent
local original_FriendsFrame_OnEvent

-----------------------------------------
-- Module state
-----------------------------------------

local isAuctionSellClick = false -- true for one frame after we programmatically click "sell this item"

local openAllBagsPending = AUCTIONATOR_OPEN_ALL_BAGS
local epochTimeZero       -- Jan 1 2000, used as the origin for "tight" (compact) timestamps
local tightEpochTimeZero  -- Aug 1 2008, origin for hour-granularity "tight" timestamps

local autoSingletonRequestedAt = 0 -- time() when Ctrl+drag requested a single-item (x1) sell

-- Info about the auction just posted, kept around so the UI can show a
-- "created!" confirmation even after the posting completes.
local justPosted_ItemName
local justPosted_ItemLink
local justPosted_BuyoutPrice
local justPosted_StackSize
local justPosted_NumInBagsAtStart
local justPosted_NumStacks

local allBagIDs = {}

local pendingHentryRetry -- an AuctionatorHEntry button waiting on GetItemInfo() to resolve
local condensedHistoryThisSession = {} -- itemName -> true, so we only condense history once per item per session

local activeAuctionsCache = {} -- itemName -> count of your own currently-active auctions (rebuilt on demand)
local hlistNeedsUpdate = false

local sellPane, morePane, shopPane
local currentPane

local sortedHistoryItemList = {}

local ATR_CACT_NULL                   = 0
local ATR_CACT_READY                  = 1
local ATR_CACT_PROCESSING             = 2
local ATR_CACT_WAITING_ON_CANCEL_CONFIRM = 3

local itemPostingInProgress = false
local sendWhoZoneMessages = false
local quietWhoStartedAt = 0
local checkingActive_NumUndercuts = 0
local checkingActive_State = ATR_CACT_NULL

Atr_ptime = nil -- a higher-precision "elapsed since load" timer, updated every frame

Atr_ScanDB = nil -- per-realm/faction price database, set up in Atr_InitScanDB

local recommendElements = {} -- UI pieces shown/hidden together for the price recommendation

-----------------------------------------
-- Stacking-preference special keys (wildcard categories)
-----------------------------------------

ATR_SK_GLYPHS     = "*_glyphs"
ATR_SK_GEMS_CUT   = "*_gemscut"
ATR_SK_GEMS_UNCUT = "*_gemsuncut"
ATR_SK_ITEM_ENH   = "*_itemenh"
ATR_SK_POT_ELIX   = "*_potelix"
ATR_SK_FLASKS     = "*_flasks"
ATR_SK_HERBS      = "*_herbs"

local roundPriceDown, ToTightTime, FromTightTime, FormatMonthDay

-----------------------------------------
-- Event registration / dispatch
-----------------------------------------

function Atr_RegisterEvents(self)

	self:RegisterEvent("VARIABLES_LOADED")
	self:RegisterEvent("ADDON_LOADED")

	self:RegisterEvent("AUCTION_ITEM_LIST_UPDATE")
	self:RegisterEvent("AUCTION_OWNED_LIST_UPDATE")

	self:RegisterEvent("AUCTION_MULTISELL_START")
	self:RegisterEvent("AUCTION_MULTISELL_UPDATE")
	self:RegisterEvent("AUCTION_MULTISELL_FAILURE")

	self:RegisterEvent("AUCTION_HOUSE_SHOW")
	self:RegisterEvent("AUCTION_HOUSE_CLOSED")

	self:RegisterEvent("NEW_AUCTION_UPDATE")
	self:RegisterEvent("CHAT_MSG_ADDON")
	self:RegisterEvent("WHO_LIST_UPDATE")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
end

-- Single dispatch table, avoiding a long if/elseif chain per event.
local EVENT_HANDLERS = {
	VARIABLES_LOADED          = function() Atr_OnLoad() end,
	ADDON_LOADED               = function() Atr_OnAddonLoaded() end,
	AUCTION_ITEM_LIST_UPDATE   = function() Atr_OnAuctionUpdate() end,
	AUCTION_OWNED_LIST_UPDATE  = function() Atr_OnAuctionOwnedUpdate() end,
	AUCTION_MULTISELL_START    = function() Atr_OnAuctionMultiSellStart() end,
	AUCTION_MULTISELL_UPDATE   = function() Atr_OnAuctionMultiSellUpdate() end,
	AUCTION_MULTISELL_FAILURE  = function() Atr_OnAuctionMultiSellFailure() end,
	AUCTION_HOUSE_SHOW         = function() Atr_OnAuctionHouseShow() end,
	AUCTION_HOUSE_CLOSED       = function() Atr_OnAuctionHouseClosed() end,
	NEW_AUCTION_UPDATE         = function() Atr_OnNewAuctionUpdate() end,
	CHAT_MSG_ADDON             = function() Atr_OnChatMsgAddon() end,
	WHO_LIST_UPDATE            = function() Atr_OnWhoListUpdate() end,
	PLAYER_ENTERING_WORLD      = function() Atr_OnPlayerEnteringWorld() end,
}

function Atr_EventHandler()
	local handler = EVENT_HANDLERS[event]
	if handler then
		handler()
	end
end

-----------------------------------------
-- Hook installation
-----------------------------------------

-- Some hooks (e.g. the "who" event filter) must exist before ADDON_LOADED
-- fires for other addons, so they're installed separately/earlier.
function Atr_SetupHookFunctionsEarly()
	original_FriendsFrame_OnEvent = FriendsFrame_OnEvent
	FriendsFrame_OnEvent = Atr_FriendsFrame_OnEvent
end

function Atr_SetupHookFunctions()

	original_AuctionFrameTab_OnClick = AuctionFrameTab_OnClick
	AuctionFrameTab_OnClick = Atr_AuctionFrameTab_OnClick

	original_ContainerFrameItemButton_OnModifiedClick = ContainerFrameItemButton_OnModifiedClick
	ContainerFrameItemButton_OnModifiedClick = Atr_ContainerFrameItemButton_OnModifiedClick

	original_AuctionFrameAuctions_Update = AuctionFrameAuctions_Update
	AuctionFrameAuctions_Update = Atr_AuctionFrameAuctions_Update

	original_CanShowRightUIPanel = CanShowRightUIPanel
	CanShowRightUIPanel = auctionator_CanShowRightUIPanel

	original_ChatEdit_InsertLink = ChatEdit_InsertLink
	ChatEdit_InsertLink = auctionator_ChatEdit_InsertLink

	original_ChatFrame_OnEvent = ChatFrame_OnEvent
	ChatFrame_OnEvent = auctionator_ChatFrame_OnEvent
end

-----------------------------------------
-- Item link cache
-----------------------------------------

local itemLinkCache = {}
local lastCachedItemName = "" -- de-dupes consecutive identical cache writes for performance

function Atr_AddToItemLinkCache(itemName, itemLink)

	if itemName == lastCachedItemName then
		return
	end

	lastCachedItemName = itemName
	itemLinkCache[string.lower(itemName)] = itemLink
end

function Atr_GetItemLink(itemName)

	if itemName == nil or itemName == "" then
		return nil
	end

	local itemLink = itemLinkCache[string.lower(itemName)]

	if itemLink == nil then
		_, itemLink = GetItemInfo(itemName)
		if itemLink then
			Atr_AddToItemLinkCache(itemName, itemLink)
		end
	end

	return itemLink
end

-----------------------------------------
-- Version-check protocol (addon-channel ping/pong)
-----------------------------------------

local highestKnownVersion
local hasShownVersionReminder = false

local function IsNewerVersion(otherVersionString)

	highestKnownVersion = highestKnownVersion or AuctionatorVersion

	local major, minor, patch = strsplit(".", otherVersionString)
	if tonumber(major) == nil or tonumber(minor) == nil or tonumber(patch) == nil then
		return false
	end

	if otherVersionString > highestKnownVersion then
		highestKnownVersion = otherVersionString
		return true
	end

	return false
end

function Atr_VersionReminder()
	if not hasShownVersionReminder then
		hasShownVersionReminder = true
		zc.msg_atr(ZT("There is a more recent version of Auctionator: VERSION") .. " " .. highestKnownVersion)
	end
end

local versionRequestSentAt = 0

function Atr_SendAddon_VREQ(distribution, target)
	versionRequestSentAt = time()
	SendAddonMessage("ATR", "VREQ_" .. AuctionatorVersion, distribution, target)
end

function Atr_OnChatMsgAddon()

	local prefix, message, _, sender = arg1, arg2, arg3, arg4

	if prefix ~= "ATR" then
		return
	end

	if zc.StringStartsWith(message, "VREQ_") then
		SendAddonMessage("ATR", "V_" .. AuctionatorVersion, "WHISPER", sender)
	end

	if zc.StringStartsWith(message, "V_") and time() - versionRequestSentAt < 5 then
		local theirVersion = string.sub(message, 3)
		if IsNewerVersion(theirVersion) then
			zc.AddDeferredCall(3, "Atr_VersionReminder", nil, nil, "VR")
		end
	end
end

-----------------------------------------
-- Slash command
-----------------------------------------

local function GetAddonMemoryString()
	UpdateAddOnMemoryUsage()
	return string.format("%6i KB", math.floor(GetAddOnMemoryUsage("Auctionator")))
end

local function Atr_SlashCmdFunction(msg)

	local command, param1, param2 = zc.words(msg)

	if command == nil or type(command) ~= "string" then
		return
	end

	command = command:lower()
	param1 = param1 and param1:lower() or nil
	param2 = param2 and param2:lower() or nil

	if command == "mem" then

		UpdateAddOnMemoryUsage()

		for i = 1, GetNumAddOns() do
			local mem = GetAddOnMemoryUsage(i)
			if mem > 0 then
				zc.msg_yellow(string.format("%6i KB   %s", math.floor(mem), GetAddOnInfo(i)))
			end
		end

	elseif command == "clear" then

		zc.msg_atr("memory usage: " .. GetAddonMemoryString())

		if param1 == "fullscandb" then
			Atr_ScanDB = nil
			AUCTIONATOR_PRICE_DATABASE = nil
			Atr_InitScanDB()
			zc.msg_atr(ZT("full scan database cleared"))
		elseif param1 == "posthistory" then
			AUCTIONATOR_PRICING_HISTORY = {}
			zc.msg_atr(ZT("pricing history cleared"))
		end

		collectgarbage("collect")

		zc.msg_atr("memory usage: " .. GetAddonMemoryString())

	elseif Atr_HandleDevCommands and Atr_HandleDevCommands(command, param1, param2) then
		-- handled by developer-only commands, nothing more to do

	else
		zc.msg_atr(ZT("unrecognized command"))
	end
end

-----------------------------------------
-- Scan price database (per realm + faction)
-----------------------------------------

function Atr_InitScanDB()

	local realmFactionKey = GetRealmName()

	-- Migrate the old (pre-multi-realm) single flat table to the new
	-- per-realm/faction layout.
	if AUCTIONATOR_PRICE_DATABASE and AUCTIONATOR_PRICE_DATABASE["__dbversion"] == nil then
		local legacyData = zc.CopyDeep(AUCTIONATOR_PRICE_DATABASE)
		AUCTIONATOR_PRICE_DATABASE = { ["__dbversion"] = 2 }
		AUCTIONATOR_PRICE_DATABASE[realmFactionKey] = legacyData
	end

	AUCTIONATOR_PRICE_DATABASE = AUCTIONATOR_PRICE_DATABASE or { ["__dbversion"] = 2 }
	AUCTIONATOR_PRICE_DATABASE[realmFactionKey] = AUCTIONATOR_PRICE_DATABASE[realmFactionKey] or {}

	Atr_ScanDB = AUCTIONATOR_PRICE_DATABASE[realmFactionKey]
end

-----------------------------------------
-- Addon lifecycle
-----------------------------------------

function Atr_OnLoad()

	AuctionatorVersion = GetAddOnMetadata("Auctionator", "Version")

	epochTimeZero      = time({ year = 2000, month = 1, day = 1, hour = 0 })
	tightEpochTimeZero = time({ year = 2008, month = 8, day = 1, hour = 0 })

	for i = 0, NUM_BAG_SLOTS do
		allBagIDs[i + 1] = i
	end
	allBagIDs[NUM_BAG_SLOTS + 2] = KEYRING_CONTAINER

	AuctionatorLoaded = true

	SlashCmdList["Auctionator"] = Atr_SlashCmdFunction
	SLASH_Auctionator1 = "/auctionator"
	SLASH_Auctionator2 = "/atr"

	Atr_InitScanDB()

	AUCTIONATOR_PRICING_HISTORY = AUCTIONATOR_PRICING_HISTORY or {}
	AUCTIONATOR_TOONS = AUCTIONATOR_TOONS or {}

	if AUCTIONATOR_STACKING_PREFS == nil then
		Atr_StackingPrefs_Init()
	end

	local playerName = UnitName("player")

	if not AUCTIONATOR_TOONS[playerName] then
		AUCTIONATOR_TOONS[playerName] = {
			firstSeen = time(),
			firstVersion = AuctionatorVersion,
		}
	end

	AUCTIONATOR_TOONS[playerName].guid = UnitGUID("player")

	AUCTIONATOR_SCAN_MINLEVEL = AUCTIONATOR_SCAN_MINLEVEL or 1 -- "poor (all)" items

	if AUCTIONATOR_SHOW_TIPS == 0 then
		AUCTIONATOR_A_TIPS = 0
		AUCTIONATOR_D_TIPS = 0
		AUCTIONATOR_SHOW_TIPS = 2
	end

	-- One-time migration from the old two-flag "open on X" setting to
	-- the single AUCTIONATOR_DEFTAB value.
	if AUCTIONATOR_OPEN_FIRST < 2 then
		if AUCTIONATOR_OPEN_FIRST == 1 then     AUCTIONATOR_DEFTAB = 1
		elseif AUCTIONATOR_OPEN_BUY == 1 then    AUCTIONATOR_DEFTAB = 2
		else                                     AUCTIONATOR_DEFTAB = 0
		end
		AUCTIONATOR_OPEN_FIRST = 2
	end

	Atr_SetupHookFunctionsEarly()

	CreateFrame("GameTooltip", "AtrScanningTooltip")
	AtrScanningTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")
	AtrScanningTooltip:AddFontStrings(
		AtrScanningTooltip:CreateFontString("$parentTextLeft1", nil, "GameTooltipText"),
		AtrScanningTooltip:CreateFontString("$parentTextRight1", nil, "GameTooltipText"))

	Atr_InitDETable()

	-- AH_QuickSearch (and possibly other addons) force Blizzard_AuctionUI
	-- to load at startup rather than lazily, so initialize immediately if so.
	if IsAddOnLoaded("Blizzard_AuctionUI") then
		Atr_Init()
	end
end

function Atr_OnAddonLoaded()

	local loadedAddonName = arg1

	if zc.StringSame(loadedAddonName, "blizzard_auctionui") then
		Atr_Init()
	end

	if zc.StringSame(loadedAddonName, "lilsparkysWorkshop") then

		local lswVersion = GetAddOnMetadata("lilsparkysWorkshop", "Version")

		if lswVersion == "0.72" or lswVersion == "0.90" or lswVersion == "0.91" then
			if LSW_itemPrice then
				zc.msg("** |cff00ffff" .. ZT("Auctionator provided an auction module to LilSparky's Workshop."), 0, 1, 0)
				zc.msg("** |cff00ffff" .. ZT("Ignore any ERROR message to the contrary below."), 0, 1, 0)
				LSW_itemPrice = Atr_LSW_itemPriceGetAuctionBuyout
			end
		end
	end

	Atr_Check_For_Conflicts(loadedAddonName)
end

function Atr_OnPlayerEnteringWorld()
	Atr_InitOptionsPanels()
end

-- Adapter for LilSparky's Workshop's price-lookup callback contract.
function Atr_LSW_itemPriceGetAuctionBuyout(link)
	local sellPrice = Atr_GetAuctionBuyout(link)
	if sellPrice then
		return sellPrice, false
	end
	return 0, true
end

function Atr_ResetSavedVars()
	AUCTIONATOR_SAVEDVARS = zc.CopyDeep(DEFAULT_UNDERCUT_AMOUNTS)
end

function Atr_Init()

	if addonInitialized then
		return
	end
	addonInitialized = true

	if AUCTIONATOR_SAVEDVARS == nil then
		Atr_ResetSavedVars()
	end

	if AUCTIONATOR_SHOPPING_LISTS == nil then
		AUCTIONATOR_SHOPPING_LISTS = {}
		Atr_SList.create(ZT("Recent Searches"), true)

		if zc.IsEnglishLocale() then
			local sampleList = Atr_SList.create("Sample Shopping List #1")
			sampleList:AddItem("Greater Cosmic Essence")
			sampleList:AddItem("Infinite Dust")
			sampleList:AddItem("Dream Shard")
			sampleList:AddItem("Abyss Crystal")
		end
	else
		Atr_ShoppingListsInit()
	end

	shopPane = Atr_AddSellTab(ZT("Buy"), BUY_TAB)
	sellPane = Atr_AddSellTab(ZT("Sell"), SELL_TAB)
	morePane = Atr_AddSellTab(ZT("More") .. "...", MORE_TAB)

	Atr_AddMainPanel()
	Atr_SetupHookFunctions()

	recommendElements = {
		_G["Atr_Recommend_Text"],
		_G["Atr_RecommendPerItem_Text"],
		_G["Atr_RecommendPerItem_Price"],
		_G["Atr_RecommendPerStack_Text"],
		_G["Atr_RecommendPerStack_Price"],
		_G["Atr_Recommend_Basis_Text"],
		_G["Atr_RecommendItem_Tex"],
	}

	for i = 1, ITEM_HIST_NUM_LINES do
		local yOffset = -5 - ((i - 1) * 16)
		local line = CreateFrame("BUTTON", "AuctionatorHEntry" .. i, Atr_Hlist, "Atr_HEntryTemplate")
		line:SetPoint("TOPLEFT", 0, yOffset)
	end

	Atr_ShowHide_StartingPrice()
	Atr_LocalizeFrames()
end

function Atr_ShowHide_StartingPrice()

	if AUCTIONATOR_SHOW_ST_PRICE == 1 then
		Atr_StartingPriceText:Show()
		Atr_StartingPrice:Show()
		Atr_StartingPriceDiscountText:Hide()
		Atr_Duration_Text:SetPoint("TOPLEFT", 10, -307)
	else
		Atr_StartingPriceText:Hide()
		Atr_StartingPrice:Hide()
		Atr_StartingPriceDiscountText:Show()
		Atr_Duration_Text:SetPoint("TOPLEFT", 10, -304)
	end
end

-----------------------------------------
-- Sell-item info (the item currently placed in the Auction Item slot)
-----------------------------------------

local ITEM_SUFFIXES_TO_STRIP = {
	"of the Tiger", "of the Bear", "of the Gorilla", "of the Boar",
	"of the Monkey", "of the Falcon", "of the Wolf", "of the Eagle",
	"of the Whale", "of the Owl",
}

function Atr_GetSellItemInfo()

	local itemName, _, itemCount = GetAuctionSellItemInfo()

	if itemName == nil then
		return "", 0, nil
	end

	local itemLink
	local exact = true
	local wasBloodforged = false

	AtrScanningTooltip:SetAuctionSellItem()
	_, itemLink = AtrScanningTooltip:GetItem()

	if AuctionatorOption_Remove_Bloodforge_CB:GetChecked() and string.find(itemName, "Bloodforged") == 1 then
		itemName = itemName:gsub("Bloodforged ", "")
		exact = false
		wasBloodforged = true
	end

	if AuctionatorOption_Remove_Suffix_CB:GetChecked() then
		for _, suffix in ipairs(ITEM_SUFFIXES_TO_STRIP) do
			itemName = itemName:gsub(" " .. suffix, "")
		end
	end

	if itemLink == nil then
		return "", 0, nil
	end

	Atr_AddToItemLinkCache(itemName, itemLink)

	return itemName, itemCount, itemLink, exact, wasBloodforged
end

-----------------------------------------
-- Tab index lookup (Blizzard assigns tab indices dynamically)
-----------------------------------------

local sellTabIndex, moreTabIndex, buyTabIndex = 0, 0, 0

function Atr_FindTabIndex(whichTab)

	if sellTabIndex == 0 then

		local i = 4
		while true do
			local tab = _G["AuctionFrameTab" .. i]
			if tab == nil then
				break
			end

			if tab.auctionatorTab == SELL_TAB then sellTabIndex = i end
			if tab.auctionatorTab == MORE_TAB then moreTabIndex = i end
			if tab.auctionatorTab == BUY_TAB then  buyTabIndex = i end

			i = i + 1
		end
	end

	if whichTab == SELL_TAB then return sellTabIndex end
	if whichTab == MORE_TAB then return moreTabIndex end
	if whichTab == BUY_TAB then  return buyTabIndex end

	return 0
end

-----------------------------------------
-- Tab switching
-----------------------------------------

function Atr_AuctionFrameTab_OnClick(self, index, down)

	if index == nil or type(index) == "string" then
		index = self:GetID()
	end

	Atr_Main_Panel:Hide()

	Atr_ClearBuyState()
	itemPostingInProgress = false

	original_AuctionFrameTab_OnClick(self, index, down)

	if not Atr_IsAuctionatorTab(index) then

		Atr_HideAllDialogs()
		AuctionFrameMoneyFrame:Show()

		if AP_Bid_MoneyFrame then -- compatibility with the 'Auction Profit' addon
			if AP_ShowBid then AP_ShowHide_Bid_Button(1) end
			if AP_ShowBO then  AP_ShowHide_BO_Button(1) end
		end

		return
	end

	AuctionFrameAuctions:Hide()
	AuctionFrameBrowse:Hide()
	AuctionFrameBid:Hide()
	PlaySound("igCharacterInfoTab")

	PanelTemplates_SetTab(AuctionFrame, index)

	AuctionFrameTopLeft:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_topleft")
	AuctionFrameBotLeft:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_botleft")
	AuctionFrameTop:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_top")
	AuctionFrameTopRight:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_topright")
	AuctionFrameBot:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_bot")
	AuctionFrameBotRight:SetTexture("Interface\\AddOns\\Auctionator\\Images\\Atr_botright")

	if index == Atr_FindTabIndex(SELL_TAB) then currentPane = sellPane end
	if index == Atr_FindTabIndex(BUY_TAB) then  currentPane = shopPane end
	if index == Atr_FindTabIndex(MORE_TAB) then currentPane = morePane end

	if index == Atr_FindTabIndex(SELL_TAB) then AuctionatorTitle:SetText("Auctionator - " .. ZT("Sell")) end
	if index == Atr_FindTabIndex(BUY_TAB) then  AuctionatorTitle:SetText("Auctionator - " .. ZT("Buy")) end
	if index == Atr_FindTabIndex(MORE_TAB) then AuctionatorTitle:SetText("Auctionator - " .. ZT("More") .. "...") end

	Atr_ClearHlist()
	Atr_SellControls:Hide()
	Atr_Hlist:Hide()
	Atr_Hlist_ScrollFrame:Hide()
	Atr_Search_Box:Hide()
	Atr_Search_Button:Hide()
	Atr_Adv_Search_Button:Hide()
	Atr_AddToSListButton:Hide()
	Atr_RemFromSListButton:Hide()
	Atr_NewSListButton:Hide()
	Atr_DelSListButton:Hide()
	Atr_DropDown1:Hide()
	Atr_DropDownSL:Hide()
	Atr_CheckActiveButton:Hide()
	Atr_Back_Button:Hide()

	AuctionFrameMoneyFrame:Hide()

	if index == Atr_FindTabIndex(SELL_TAB) then
		Atr_SellControls:Show()
	else
		Atr_Hlist:Show()
		Atr_Hlist_ScrollFrame:Show()
		if justPosted_ItemName then
			justPosted_ItemName = nil
			sellPane:ClearSearch()
		end
	end

	if index == Atr_FindTabIndex(MORE_TAB) then
		FauxScrollFrame_SetOffset(Atr_Hlist_ScrollFrame, currentPane.hlistScrollOffset)
		Atr_DisplayHlist()
		Atr_DropDown1:Show()

		if UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ACTIVE then
			Atr_CheckActiveButton:Show()
		end
	end

	if index == Atr_FindTabIndex(BUY_TAB) then
		Atr_Search_Box:Show()
		Atr_Search_Button:Show()
		Atr_Adv_Search_Button:Show()
		AuctionFrameMoneyFrame:Show()
		Atr_BuildGlobalHistoryList(true)
		Atr_AddToSListButton:Show()
		Atr_RemFromSListButton:Show()
		Atr_NewSListButton:Show()
		Atr_DelSListButton:Show()
		Atr_DropDownSL:Show()
		Atr_Hlist:SetHeight(252)
		Atr_Hlist_ScrollFrame:SetHeight(252)
	else
		Atr_Hlist:SetHeight(335)
		Atr_Hlist_ScrollFrame:SetHeight(335)
	end

	if index == Atr_FindTabIndex(BUY_TAB) or index == Atr_FindTabIndex(SELL_TAB) then
		Atr_Buy1_Button:Show()
		Atr_Buy1_Button:Disable()
	end

	Atr_HideElems(recommendElements)

	Atr_Main_Panel:Show()
	currentPane.UINeedsUpdate = true

	if openAllBagsPending == 1 then
		OpenAllBags(true)
		openAllBagsPending = 0
	end
end

function Atr_StackSize()
	return Atr_Batch_Stacksize:GetNumber()
end

function Atr_SetStackSize(n)
	return Atr_Batch_Stacksize:SetText(n)
end

function Atr_SelectPane(whichTab)
	local index = Atr_FindTabIndex(whichTab)
	Atr_AuctionFrameTab_OnClick(_G["AuctionFrameTab" .. index], index)
end

function Atr_IsModeCreateAuction()
	return Atr_IsTabSelected(SELL_TAB)
end

function Atr_IsModeBuy()
	return Atr_IsTabSelected(BUY_TAB)
end

function Atr_IsModeActiveAuctions()
	return Atr_IsTabSelected(MORE_TAB) and UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ACTIVE
end

-----------------------------------------
-- Dragging items into the sell pane
-----------------------------------------

function Atr_ClickAuctionSellItemButton(self, button)
	isAuctionSellClick = true
	ClickAuctionSellItemButton(self, button)
end

function Atr_OnDropItem(self, button)

	if GetCursorInfo() ~= "item" then
		return
	end

	if not Atr_IsTabSelected(SELL_TAB) then
		Atr_SelectPane(SELL_TAB)
	end

	Atr_ClickAuctionSellItemButton(self, button)
	ClearCursor()
end

function Atr_SellItemButton_OnClick(self, button)
	Atr_ClickAuctionSellItemButton(self, button)
end

function Atr_SellItemButton_OnEvent(self, eventName)
	if eventName == "NEW_AUCTION_UPDATE" then
		local _, texture = GetAuctionSellItemInfo()
		Atr_SellControls_Tex:SetNormalTexture(texture)
	end
end

local previousSellItemLink

local function Atr_LoadContainerItemToSellPane()

	local bagID = this:GetParent():GetID()
	local slotID = this:GetID()

	if not Atr_IsTabSelected(SELL_TAB) then
		Atr_SelectPane(SELL_TAB)
	end

	if IsControlKeyDown() then
		autoSingletonRequestedAt = time()
	end

	PickupContainerItem(bagID, slotID)

	if GetCursorInfo() == "item" then
		Atr_ClearAll()
		Atr_ClickAuctionSellItemButton()
		ClearCursor()
	end
end

function Atr_ContainerFrameItemButton_OnClick(self, button)

	if AuctionFrame and AuctionFrame:IsShown() and zc.StringSame(button, "RightButton") then
		local selectedTab = PanelTemplates_GetSelectedTab(AuctionFrame)
		if selectedTab == 1 or selectedTab == 2 or Atr_IsAuctionatorTab(selectedTab) then
			Atr_LoadContainerItemToSellPane()
		end
	end
end

function Atr_ContainerFrameItemButton_OnModifiedClick(self, button)

	if AUCTIONATOR_ENABLE_ALT ~= 0 and AuctionFrame:IsShown() and IsAltKeyDown() then
		Atr_LoadContainerItemToSellPane()
		return
	end

	return original_ContainerFrameItemButton_OnModifiedClick(self, button)
end

-----------------------------------------
-- Creating an auction
-----------------------------------------

function Atr_CreateAuction_OnClick()

	justPosted_ItemName          = currentPane.activeScan.itemName
	justPosted_ItemLink          = currentPane.activeScan.itemLink
	justPosted_BuyoutPrice       = MoneyInputFrame_GetCopper(Atr_StackPrice)
	justPosted_StackSize         = Atr_StackSize()
	justPosted_NumInBagsAtStart  = Atr_GetNumItemInBags(justPosted_ItemName)
	justPosted_NumStacks         = Atr_Batch_NumAuctions:GetNumber()

	local duration = UIDropDownMenu_GetSelectedValue(Atr_Duration)
	local startingPrice = MoneyInputFrame_GetCopper(Atr_StartingPrice)
	local buyoutPrice = MoneyInputFrame_GetCopper(Atr_StackPrice)

	if justPosted_StackSize == 1 and currentPane.fullStackSize > 1 then

		local scan = currentPane.activeScan

		if scan and scan.numYourSingletons + justPosted_NumStacks > MAX_SINGLE_STACK_AUCTIONS then
			local message = ZT("You may have at most 40 single-stack (x1)\nauctions posted for this item.\n\nYou already have %d such auctions and\nyou are trying to post %d more.")
			Atr_Error_Display(string.format(message, scan.numYourSingletons, justPosted_NumStacks))
			return
		end
	end

	Atr_Memorize_Stacking_If()

	StartAuction(startingPrice, buyoutPrice, duration, justPosted_StackSize, justPosted_NumStacks)
end

local multiSellStacksSoFarPrevious

function Atr_OnAuctionMultiSellStart()
	multiSellStacksSoFarPrevious = 0
end

function Atr_OnAuctionMultiSellUpdate()

	local stacksSoFar = arg1
	local stacksTotal = arg2
	local delta = stacksSoFar - multiSellStacksSoFarPrevious

	multiSellStacksSoFarPrevious = stacksSoFar

	Atr_AddToScan(justPosted_ItemName, justPosted_StackSize, justPosted_BuyoutPrice, delta)

	if stacksSoFar == stacksTotal then
		Atr_LogMsg(justPosted_ItemLink, justPosted_StackSize, justPosted_BuyoutPrice, stacksTotal)
		Atr_AddHistoricalPrice(justPosted_ItemName, justPosted_BuyoutPrice / justPosted_StackSize, justPosted_StackSize, justPosted_ItemLink)
	end
end

function Atr_OnAuctionMultiSellFailure()

	-- Add one more anyway: empirically this keeps the scan count accurate
	-- even when the last auction in a batch reports as a failure.
	Atr_AddToScan(justPosted_ItemName, justPosted_StackSize, justPosted_BuyoutPrice, 1)

	Atr_LogMsg(justPosted_ItemLink, justPosted_StackSize, justPosted_BuyoutPrice, multiSellStacksSoFarPrevious + 1)
	Atr_AddHistoricalPrice(justPosted_ItemName, justPosted_BuyoutPrice / justPosted_StackSize, justPosted_StackSize, justPosted_ItemLink)

	if currentPane.activeScan then
		currentPane.activeScan.whenScanned = 0
	end
end

function Atr_AuctionFrameAuctions_Update()
	original_AuctionFrameAuctions_Update()
end

function Atr_LogMsg(itemLink, itemCount, price, numStacks)

	if not itemLink then
		return
	end

	local message = string.format(ZT("Auction created for %s"), itemLink)

	if numStacks > 1 then
		message = string.format(ZT("%d auctions created for %s"), numStacks, itemLink)
	end

	if itemCount > 1 then
		message = message .. "|cff00ddddx" .. itemCount .. "|r"
	end

	message = message .. "   " .. zc.priceToString(price)

	if numStacks > 1 and itemCount > 1 then
		message = message .. "  per stack"
	end

	zc.msg_yellow(message)
end

function Atr_OnAuctionOwnedUpdate()

	itemPostingInProgress = false

	if Atr_IsModeActiveAuctions() then
		hlistNeedsUpdate = true
	end

	if not Atr_IsTabSelected() then
		Atr_ClearScanCache() -- we have no idea what happened on a non-Auctionator tab, so flush everything
		return
	end

	activeAuctionsCache = {} -- always rebuilt lazily on next use

	if justPosted_ItemName and justPosted_NumStacks == 1 then
		Atr_LogMsg(justPosted_ItemLink, justPosted_StackSize, justPosted_BuyoutPrice, 1)
		Atr_AddHistoricalPrice(justPosted_ItemName, justPosted_BuyoutPrice / justPosted_StackSize, justPosted_StackSize, justPosted_ItemLink)
		Atr_AddToScan(justPosted_ItemName, justPosted_StackSize, justPosted_BuyoutPrice, 1)
	end
end

function Atr_ResetDuration()
	if AUCTIONATOR_DEF_DURATION == "S" then UIDropDownMenu_SetSelectedValue(Atr_Duration, 1) end
	if AUCTIONATOR_DEF_DURATION == "M" then UIDropDownMenu_SetSelectedValue(Atr_Duration, 2) end
	if AUCTIONATOR_DEF_DURATION == "L" then UIDropDownMenu_SetSelectedValue(Atr_Duration, 3) end
end

function Atr_AddToScan(itemName, stackSize, buyoutPrice, numAuctions)
	local scan = Atr_FindScan(itemName)
	scan:AddScanItem(itemName, stackSize, buyoutPrice, UnitName("player"), numAuctions)
	scan:CondenseAndSort()
	currentPane.UINeedsUpdate = true
end

function AuctionatorSubtractFromScan(itemName, stackSize, buyoutPrice, howMany)
	howMany = howMany or 1
	local scan = Atr_FindScan(itemName)
	for _ = 1, howMany do
		scan:SubtractScanItem(itemName, stackSize, buyoutPrice)
	end
	scan:CondenseAndSort()
	currentPane.UINeedsUpdate = true
end

-----------------------------------------
-- Chat hooks
-----------------------------------------

function auctionator_ChatEdit_InsertLink(text)

	if AuctionFrame:IsShown() and IsShiftKeyDown() and Atr_IsTabSelected(BUY_TAB) and strfind(text, "item:", 1, true) then
		local item = GetItemInfo(text)
		if item then
			Atr_Search_Box:SetText(item)
			Atr_Search_Onclick()
			return true
		end
	end

	return original_ChatEdit_InsertLink(text)
end

function auctionator_ChatFrame_OnEvent(self, eventName, ...)

	if eventName == "CHAT_MSG_SYSTEM" and (arg1 == ERR_AUCTION_STARTED or arg1 == ERR_AUCTION_REMOVED) then
		return -- suppress the default "Auction created/removed" system message; we print our own
	end

	return original_ChatFrame_OnEvent(self, eventName, ...)
end

function auctionator_CanShowRightUIPanel(frame)
	if zc.StringSame(frame:GetName(), "TradeSkillFrame") then
		return 1
	end
	return original_CanShowRightUIPanel(frame)
end

-----------------------------------------
-- Main panel / tab construction
-----------------------------------------

function Atr_AddMainPanel()

	CreateFrame("FRAME", "Atr_Main_Panel", AuctionFrame, "Atr_Sell_Template"):Hide()

	UIDropDownMenu_SetWidth(Atr_DropDownSL, 150)
	UIDropDownMenu_JustifyText(Atr_DropDownSL, "CENTER")
	UIDropDownMenu_SetWidth(Atr_Duration, 95)
end

function Atr_AddSellTab(tabText, whichTab)

	local tabIndex = AuctionFrame.numTabs + 1
	local frameName = "AuctionFrameTab" .. tabIndex

	local tab = CreateFrame("Button", frameName, AuctionFrame, "AuctionTabTemplate")
	tab:SetID(tabIndex)
	tab:SetText(tabText)
	tab:SetNormalFontObject(_G["AtrFontOrange"])
	tab.auctionatorTab = whichTab
	tab:SetPoint("LEFT", _G["AuctionFrameTab" .. tabIndex - 1], "RIGHT", -8, 0)

	PanelTemplates_SetNumTabs(AuctionFrame, tabIndex)
	PanelTemplates_EnableTab(AuctionFrame, tabIndex)

	return AtrPane.create(whichTab)
end

function Atr_HideElems(elements)
	if not elements then return end
	for _, element in ipairs(elements) do
		element:Hide()
	end
end

function Atr_ShowElems(elements)
	for _, element in ipairs(elements) do
		element:Show()
	end
end

-----------------------------------------
-- Auction-list update dispatch
-----------------------------------------

function Atr_OnAuctionUpdate()

	if gAtr_FullScanState == ATR_FS_STARTED then
		Atr_FullScanAnalyze()
		return
	end

	if not Atr_IsTabSelected() then
		Atr_ClearScanCache()
		return
	end

	if Atr_Buy_OnAuctionUpdate() then
		return
	end

	if currentPane.activeSearch and currentPane.activeSearch.processingState == KM_POSTQUERY then

		local isDuplicate = currentPane.activeSearch:CheckForDuplicatePage()

		if not isDuplicate then
			local isDone = currentPane.activeSearch:AnalyzeResultsPage()
			if isDone then
				currentPane.activeSearch:Finish()
				Atr_OnSearchComplete()
			end
		end
	end
end

function Atr_OnSearchComplete()

	currentPane.sortedHist = nil

	if currentPane.activeSearch:NumScans() == 1 then
		currentPane.activeScan = currentPane.activeSearch:GetFirstScan()
	end

	if Atr_IsModeCreateAuction() then

		currentPane:SetToShowCurrent()

		if #currentPane.activeScan.scanData == 0 then
			currentPane.hints = Atr_BuildHints(currentPane.activeScan.itemName)
			if #currentPane.hints > 0 then
				currentPane:SetToShowHints()
				currentPane.hintsIndex = 1
			end
		end

		if currentPane:ShowCurrent() then
			Atr_FindBestCurrentAuction()
		end

		Atr_UpdateRecommendation(true)
	else
		if Atr_IsModeActiveAuctions() then
			Atr_DisplayHlist()
		end
		Atr_FindBestCurrentAuction()
	end

	if Atr_IsModeBuy() then
		Atr_Shop_OnFinishScan()
	end

	Atr_CheckingActive_OnSearchComplete()

	currentPane.UINeedsUpdate = true
end

function Atr_ClearTop()
	Atr_HideElems(recommendElements)
	if AuctionatorMessageFrame then
		AuctionatorMessageFrame:Hide()
		AuctionatorMessage2Frame:Hide()
	end
end

function Atr_ClearList()

	Atr_Col1_Heading:Hide()
	Atr_Col3_Heading:Hide()
	Atr_Col4_Heading:Hide()
	Atr_Col1_Heading_Button:Hide()
	Atr_Col3_Heading_Button:Hide()

	FauxScrollFrame_Update(AuctionatorScrollFrame, 0, 12, 16)

	for line = 1, 12 do
		_G["AuctionatorEntry" .. line]:Hide()
	end
end

function Atr_ClearAll()
	if AuctionatorMessageFrame then -- guards against calls before the XML has finished loading
		Atr_ClearTop()
		Atr_ClearList()
	end
end

function Atr_SetMessage(message)

	Atr_HideElems(recommendElements)

	if currentPane.activeSearch.searchText ~= "" then
		Atr_ShowItemNameAndTexture(currentPane.activeSearch.searchText)
		AuctionatorMessage2Frame:SetText(message)
		AuctionatorMessage2Frame:Show()
	else
		AuctionatorMessageFrame:SetText(message)
		AuctionatorMessageFrame:Show()
		AuctionatorMessage2Frame:Hide()
	end
end

function Atr_ShowItemNameAndTexture(itemName)

	AuctionatorMessageFrame:Hide()
	AuctionatorMessage2Frame:Hide()

	local scan = currentPane.activeScan
	local colorPrefix = ""

	if scan and not scan:IsNil() then
		colorPrefix = "|cff" .. zc.RGBtoHEX(scan.itemTextColor[1], scan.itemTextColor[2], scan.itemTextColor[3])
		itemName = scan.itemName
	end

	Atr_Recommend_Text:Show()
	Atr_Recommend_Text:SetText(colorPrefix .. itemName)

	Atr_SetTextureButton("Atr_RecommendItem_Tex", 1, currentPane.activeScan.itemLink)
end

-----------------------------------------
-- Sale/purchase history storage
-----------------------------------------

local function SortHistoryByRecency(a, b)
	return a.when > b.when
end

-- "Tight" tags compactly encode a (bucket-type, date) pair as a single
-- string key for AUCTIONATOR_PRICING_HISTORY, e.g. "123456:hd" for a
-- specific day, or "123:hm" for an entire month.
function BuildHtag(bucketType, year, month, day)
	return tostring(ToTightTime(time({ year = year, month = month, day = day, hour = 0 }))) .. ":" .. bucketType
end

function ParseHtag(tag)
	local when, bucketType = strsplit(":", tag)
	bucketType = bucketType or "hx" -- "hx" = an exact, uncondensed timestamp
	return FromTightTime(tonumber(when)), bucketType
end

-- A history row is stored as "price:count" where the meaning of `count`
-- depends on the bucket type: for "hx" (exact/uncondensed) rows it's the
-- stack size; for condensed rows it's the number of auctions folded together.
function ParseHist(tag, historyValue)

	local when, bucketType = ParseHtag(tag)
	local priceStr, countStr = strsplit(":", historyValue)
	local price = tonumber(priceStr)

	local stackSize, numAuctions

	if bucketType == "hx" then
		stackSize = tonumber(countStr)
		numAuctions = 1
	else
		stackSize = 0
		numAuctions = tonumber(countStr)
	end

	return when, bucketType, price, stackSize, numAuctions
end

local function CalcAbsoluteTimeParts(when, whenTable)
	local absYear = whenTable.year - 2000
	local absMonth = (absYear * 12) + whenTable.month
	local absDay = floor((when - epochTimeZero) / (60 * 60 * 24))
	return absYear, absMonth, absDay
end

-- Periodically folds old exact-timestamp history entries into
-- coarser day/month/year buckets so the SavedVariables file doesn't grow
-- without bound. Runs at most once per item per session.
function Atr_Condense_History(itemName)

	if AUCTIONATOR_PRICING_HISTORY[itemName] == nil then
		return
	end

	local now = time()
	local nowTable = date("*t", now)
	local absNowYear, absNowMonth, absNowDay = CalcAbsoluteTimeParts(now, nowTable)

	local tempHistory = {}
	local i = 1

	for tag, historyValue in pairs(AUCTIONATOR_PRICING_HISTORY[itemName]) do
		if tag ~= "is" then

			local when, _, price, stackSize, numAuctions = ParseHist(tag, historyValue)
			local whenTable = date("*t", when)
			local absYear, absMonth, absDay = CalcAbsoluteTimeParts(when, whenTable)

			local newTag
			if absNowYear - absYear >= 3 then
				newTag = BuildHtag("hy", whenTable.year, 1, 1)
			elseif absNowMonth - absMonth >= 2 then
				newTag = BuildHtag("hm", whenTable.year, whenTable.month, 1)
			elseif absNowDay - absDay >= 2 then
				newTag = BuildHtag("hd", whenTable.year, whenTable.month, whenTable.day)
			else
				newTag = tag
			end

			tempHistory[i] = { price = price, numAuctions = numAuctions, stackSize = stackSize, when = when, newTag = newTag }
			i = i + 1
		end
	end

	local uniqueItemInfo = AUCTIONATOR_PRICING_HISTORY[itemName]["is"]
	AUCTIONATOR_PRICING_HISTORY[itemName] = { ["is"] = uniqueItemInfo }

	for _, historyEntry in ipairs(tempHistory) do

		local newTag = historyEntry.newTag

		if AUCTIONATOR_PRICING_HISTORY[itemName][newTag] == nil then

			local _, bucketType = ParseHtag(newTag)
			local count = (bucketType == "hx") and historyEntry.stackSize or historyEntry.numAuctions

			AUCTIONATOR_PRICING_HISTORY[itemName][newTag] = tostring(historyEntry.price) .. ":" .. tostring(count)
		else
			local _, _, price, _, numAuctions = ParseHist(newTag, AUCTIONATOR_PRICING_HISTORY[itemName][newTag])

			local combinedCount = numAuctions + historyEntry.numAuctions
			local combinedPrice = ((price * numAuctions) + (historyEntry.price * historyEntry.numAuctions)) / combinedCount

			AUCTIONATOR_PRICING_HISTORY[itemName][newTag] = tostring(combinedPrice) .. ":" .. tostring(combinedCount)
		end
	end
end

function Atr_Process_Historydata()

	if currentPane:IsScanEmpty() then
		return
	end

	local itemName = currentPane.activeScan.itemName

	if condensedHistoryThisSession[itemName] == nil then
		condensedHistoryThisSession[itemName] = true
		Atr_Condense_History(itemName)
	end

	currentPane.sortedHist = {}

	if AUCTIONATOR_PRICING_HISTORY[itemName] then
		local i = 1
		for tag, historyValue in pairs(AUCTIONATOR_PRICING_HISTORY[itemName]) do
			if tag ~= "is" then

				local when, bucketType, price, stackSize, numAuctions = ParseHist(tag, historyValue)
				if stackSize == 0 then
					stackSize = numAuctions
				end

				currentPane.sortedHist[i] = {
					itemPrice   = price,
					buyoutPrice = price * stackSize,
					stackSize   = stackSize,
					when        = when,
					yours       = true,
					type        = bucketType,
				}
				i = i + 1
			end
		end
	end

	table.sort(currentPane.sortedHist, SortHistoryByRecency)

	if #currentPane.sortedHist > 0 then
		return currentPane.sortedHist[1].itemPrice
	end
end

function Atr_GetMostRecentSale(itemName)

	local mostRecentPrice
	local mostRecentWhen = 0

	if AUCTIONATOR_PRICING_HISTORY and AUCTIONATOR_PRICING_HISTORY[itemName] then
		for tag, historyValue in pairs(AUCTIONATOR_PRICING_HISTORY[itemName]) do
			if tag ~= "is" then
				local when, _, price = ParseHist(tag, historyValue)
				if when > mostRecentWhen then
					mostRecentPrice = price
					mostRecentWhen = when
				end
			end
		end
	end

	return mostRecentPrice
end

-----------------------------------------
-- Price recommendation
-----------------------------------------

function Atr_ShowingSearchSummary()
	return currentPane.activeSearch
		and currentPane.activeSearch.searchText ~= ""
		and currentPane:IsScanEmpty()
		and currentPane.activeSearch:NumScans() > 0
end

function Atr_ShowingCurrentAuctions()
	return currentPane and currentPane:ShowCurrent() or true
end

function Atr_ShowingHistory()
	return currentPane and currentPane:ShowHistory() or false
end

function Atr_ShowingHints()
	return currentPane and currentPane:ShowHints() or false
end

function Atr_UpdateRecommendation(updatePrices)

	if currentPane == sellPane and justPosted_ItemLink and GetAuctionSellItemInfo() == nil then
		return
	end

	local baseData

	if Atr_ShowingSearchSummary() then
		-- nothing to recommend from a multi-item search summary

	elseif Atr_ShowingCurrentAuctions() then

		if currentPane:GetProcessingState() ~= KM_NULL_STATE then
			return
		end

		if #currentPane.activeScan.sortedData == 0 then
			Atr_SetMessage(ZT("No current auctions found"))
			return
		end

		if not currentPane.currIndex then
			if currentPane.activeScan.numMatches == 0 then
				Atr_SetMessage(ZT("No current auctions found\n\n(related auctions shown)"))
			elseif currentPane.activeScan.numMatchesWithBuyout == 0 then
				Atr_SetMessage(ZT("No current auctions with buyouts found"))
			else
				Atr_SetMessage("")
			end
			return
		end

		baseData = currentPane.activeScan.sortedData[currentPane.currIndex]

	elseif Atr_ShowingHistory() then

		baseData = zc.GetArrayElemOrFirst(currentPane.sortedHist, currentPane.histIndex)

		if baseData == nil then
			Atr_SetMessage(ZT("Auctionator has yet to record any auctions for this item"))
			return
		end

	else -- hints

		local hint = zc.GetArrayElemOrFirst(currentPane.hints, currentPane.hintsIndex)

		if hint then
			baseData = {
				itemPrice   = hint.price,
				buyoutPrice = hint.price,
				stackSize   = 1,
				sourceText  = hint.text,
				yours       = true, -- prevents undercut discounting on a hint-based suggestion
			}
		end
	end

	if Atr_StackSize() == 0 then
		return
	end

	local newItemBuyoutPrice

	if itemPostingInProgress and currentPane.itemLink == justPosted_ItemLink then
		-- The server may still be finishing the previous post; use its
		-- price rather than the (possibly stale) scan data.
		newItemBuyoutPrice = justPosted_BuyoutPrice / justPosted_StackSize

	elseif baseData then

		newItemBuyoutPrice = baseData.itemPrice

		if not baseData.yours and not baseData.altName then
			newItemBuyoutPrice = Atr_CalcUndercutPrice(newItemBuyoutPrice)
		end
	end

	if newItemBuyoutPrice == nil then
		return
	end

	local newItemStartPrice = Atr_CalcStartPrice(newItemBuyoutPrice)

	Atr_ShowElems(recommendElements)
	AuctionatorMessageFrame:Hide()
	AuctionatorMessage2Frame:Hide()

	Atr_Recommend_Text:SetText(ZT("Recommended Buyout Price"))
	Atr_RecommendPerStack_Text:SetText(string.format(ZT("for your stack of %d"), Atr_StackSize()))

	Atr_SetTextureButton("Atr_RecommendItem_Tex", Atr_StackSize(), currentPane.activeScan.itemLink)

	MoneyFrame_Update("Atr_RecommendPerItem_Price", zc.round(newItemBuyoutPrice))
	MoneyFrame_Update("Atr_RecommendPerStack_Price", zc.round(newItemBuyoutPrice * Atr_StackSize()))

	if updatePrices then
		MoneyInputFrame_SetCopper(Atr_StackPrice, newItemBuyoutPrice * Atr_StackSize())
		MoneyInputFrame_SetCopper(Atr_StartingPrice, newItemStartPrice * Atr_StackSize())
		MoneyInputFrame_SetCopper(Atr_ItemPrice, newItemBuyoutPrice)
	end

	local cheapestStack = currentPane.activeScan.bestPrices and currentPane.activeScan.bestPrices[Atr_StackSize()]

	Atr_Recommend_Basis_Text:SetTextColor(1, 1, 1)

	if Atr_ShowingHints() then
		Atr_Recommend_Basis_Text:SetTextColor(.8, .8, 1)
		Atr_Recommend_Basis_Text:SetText("(" .. ZT("based on") .. " " .. baseData.sourceText .. ")")
	elseif currentPane.activeScan.absoluteBest
		and baseData.stackSize == currentPane.activeScan.absoluteBest.stackSize
		and baseData.buyoutPrice == currentPane.activeScan.absoluteBest.buyoutPrice then
		Atr_Recommend_Basis_Text:SetText("(" .. ZT("based on cheapest current auction") .. ")")
	elseif cheapestStack and baseData.stackSize == cheapestStack.stackSize and baseData.buyoutPrice == cheapestStack.buyoutPrice then
		Atr_Recommend_Basis_Text:SetText("(" .. ZT("based on cheapest stack of the same size") .. ")")
	else
		Atr_Recommend_Basis_Text:SetText("(" .. ZT("based on selected auction") .. ")")
	end
end

-----------------------------------------
-- Price/stack-size input syncing
-----------------------------------------

function Atr_StackPriceChangedFunc()

	local newStackBuyoutPrice = MoneyInputFrame_GetCopper(Atr_StackPrice)
	local newItemBuyoutPrice = math.floor(newStackBuyoutPrice / Atr_StackSize())
	local newItemStartPrice = Atr_CalcStartPrice(newItemBuyoutPrice)

	local calculatedStackPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice) * Atr_StackSize()

	if calculatedStackPrice ~= newStackBuyoutPrice then -- guards against feedback loops between the two fields
		MoneyInputFrame_SetCopper(Atr_ItemPrice, newItemBuyoutPrice)
		MoneyInputFrame_SetCopper(Atr_StartingPrice, newItemStartPrice * Atr_StackSize())
	end

	Atr_SetDepositText()
end

function Atr_ItemPriceChangedFunc()

	local newItemBuyoutPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice)
	local newItemStartPrice = Atr_CalcStartPrice(newItemBuyoutPrice)

	local calculatedItemPrice = math.floor(MoneyInputFrame_GetCopper(Atr_StackPrice) / Atr_StackSize())

	if calculatedItemPrice ~= newItemBuyoutPrice then
		MoneyInputFrame_SetCopper(Atr_StackPrice, newItemBuyoutPrice * Atr_StackSize())
		MoneyInputFrame_SetCopper(Atr_StartingPrice, newItemStartPrice * Atr_StackSize())
	end

	Atr_SetDepositText()
end

function Atr_StackSizeChangedFunc()

	local itemBuyoutPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice)
	local newItemStartPrice = Atr_CalcStartPrice(itemBuyoutPrice)

	MoneyInputFrame_SetCopper(Atr_StackPrice, itemBuyoutPrice * Atr_StackSize())
	MoneyInputFrame_SetCopper(Atr_StartingPrice, newItemStartPrice * Atr_StackSize())

	sellPane.UINeedsUpdate = true
	Atr_SetDepositText()
end

function Atr_NumAuctionsChangedFunc()
	sellPane.UINeedsUpdate = true
end

-----------------------------------------
-- Icon buttons (item texture + stack-count overlay)
-----------------------------------------

function Atr_SetTextureButton(elementName, count, itemLink)

	local texture = GetItemIcon(itemLink)
	local textureElement = _G[elementName]

	if texture then
		textureElement:Show()
		textureElement:SetNormalTexture(texture)
		Atr_SetTextureButtonCount(elementName, count)
	else
		Atr_SetTextureButtonCount(elementName, 0)
	end
end

function Atr_SetTextureButtonCount(elementName, count)

	local countElement = _G[elementName .. "Count"]

	if count > 1 then
		countElement:SetText(count)
		countElement:Show()
	else
		countElement:Hide()
	end
end

function Atr_ShowRecTooltip()

	local link = currentPane.activeScan.itemLink
	local count = Atr_StackSize()

	if not link then
		link = justPosted_ItemLink
		count = justPosted_StackSize
	end

	if link then
		count = math.max(count, 1)
		GameTooltip:SetOwner(Atr_RecommendItem_Tex, "ANCHOR_RIGHT")
		GameTooltip:SetHyperlink(link, count)
		currentPane.tooltipVisible = true
	end
end

function Atr_HideRecTooltip()
	currentPane.tooltipVisible = nil
	GameTooltip:Hide()
end

-----------------------------------------
-- Auction House open/close
-----------------------------------------

function Atr_OnAuctionHouseShow()

	openAllBagsPending = AUCTIONATOR_OPEN_ALL_BAGS

	if AUCTIONATOR_DEFTAB == 1 then Atr_SelectPane(SELL_TAB) end
	if AUCTIONATOR_DEFTAB == 2 then Atr_SelectPane(BUY_TAB) end
	if AUCTIONATOR_DEFTAB == 3 then Atr_SelectPane(MORE_TAB) end

	Atr_ResetDuration()

	justPosted_ItemName = nil
	sellPane:ClearSearch()

	if currentPane then
		currentPane.UINeedsUpdate = true
	end
end

function Atr_OnAuctionHouseClosed()

	Atr_HideAllDialogs()
	Atr_CheckingActive_Finish()
	Atr_ClearScanCache()

	sellPane:ClearSearch()
	shopPane:ClearSearch()
	morePane:ClearSearch()
end

function Atr_HideAllDialogs()
	Atr_CheckActives_Frame:Hide()
	Atr_Error_Frame:Hide()
	Atr_Buy_Confirm_Frame:Hide()
	Atr_FullScanFrame:Hide()
	Atr_Mask:Hide()
end

-----------------------------------------
-- Options: "default duration" sub-panel live update
-----------------------------------------

function Atr_BasicOptionsUpdate(self, elapsed)

	self.timeSinceLastUpdate = (self.timeSinceLastUpdate or 0) + elapsed

	if self.timeSinceLastUpdate > 0.25 then
		self.timeSinceLastUpdate = 0

		if AuctionatorOption_Def_Duration_CB:GetChecked() then
			AuctionatorOption_Durations:Show()
		else
			AuctionatorOption_Durations:Hide()
		end
	end
end

-----------------------------------------
-- Guild "who" polling (used to ping guildmates for version info)
-----------------------------------------

function Atr_OnWhoListUpdate()

	if not sendWhoZoneMessages then
		return
	end

	sendWhoZoneMessages = false

	local numResults, totalCount = GetNumWhoResults()
	zc.md(numResults .. " out of " .. totalCount .. " users found")

	for i = 1, numResults do
		local name, guildName, level = GetWhoInfo(i)
		Atr_SendAddon_VREQ("WHISPER", name)
		if Atr_Guildinfo then Atr_Guildinfo[name] = guildName end
		if Atr_Levelinfo then Atr_Levelinfo[name] = level end
	end
end

-----------------------------------------
-- Main OnUpdate loop
-----------------------------------------

function Atr_OnUpdate(self, elapsed)

	Atr_ptime = (Atr_ptime or 0) + elapsed

	if zc.periodic(self, "deferredCallLastUpdate", 0.05, elapsed) then
		zc.CheckDeferredCall()
	end

	if gAtr_dustCacheIndex > 0 and zc.periodic(self, "dustCacheLastUpdate", 0.1, elapsed) then
		Atr_GetNextDustIntoCache()
	end

	if zc.periodic(self, "idleLastUpdate", 0.2, elapsed) then
		Atr_Idle(self, elapsed)
	end
end

local versionCheckMessageState = 0
local hasCheckedAuctionProfitCompat = false

function Atr_Idle()

	if currentPane and currentPane.tooltipVisible then
		Atr_ShowRecTooltip()
	end

	if gAtr_FullScanState ~= ATR_FS_NULL then
		Atr_FullScanFrameIdle()
	end

	if versionCheckMessageState == 0 then
		versionCheckMessageState = time()
	end

	if versionCheckMessageState > 1 and time() - versionCheckMessageState > 5 then
		versionCheckMessageState = 1
		local guildName = GetGuildInfo("player")
		if guildName then
			Atr_SendAddon_VREQ("GUILD")
		end
	end

	if not Atr_IsTabSelected() or AuctionatorMessageFrame == nil then
		return
	end

	if pendingHentryRetry then
		Atr_HEntryOnClick()
		return
	end

	if currentPane.activeSearch and currentPane.activeSearch.processingState == KM_PREQUERY then
		currentPane.activeSearch:Continue()
	end

	Atr_UpdateUI()
	Atr_CheckingActiveIdle()
	Atr_Buy_Idle()

	-- One-time compatibility check for the 'Auction Profit' addon, which
	-- shows its own money frames that would otherwise overlap ours.
	if not hasCheckedAuctionProfitCompat then
		hasCheckedAuctionProfitCompat = true
		if AP_Bid_MoneyFrame then
			AP_Bid_MoneyFrame:Hide()
			AP_Buy_MoneyFrame:Hide()
		end
	end
end

-----------------------------------------
-- NEW_AUCTION_UPDATE: item placed in the Auction Item slot changed
-----------------------------------------

function Atr_OnNewAuctionUpdate()

	if not isAuctionSellClick then
		previousSellItemLink = nil
		return
	end

	isAuctionSellClick = false

	local itemName, itemCount, itemLink, exact, wasBloodforged = Atr_GetSellItemInfo()

	if previousSellItemLink ~= itemLink then

		previousSellItemLink = itemLink

		if itemLink then
			justPosted_ItemName = nil
			Atr_AddToItemLinkCache(itemName, itemLink)
			Atr_ClearList() -- better perceived responsiveness
			sellPane:SetToShowCurrent()
		end

		MoneyInputFrame_SetCopper(Atr_StackPrice, 0)
		MoneyInputFrame_SetCopper(Atr_StartingPrice, 0)
		Atr_ResetDuration()

		if justPosted_ItemName == nil then

			local searchName = string.find(itemName, "RE:") and string.gsub(itemName, "RE:", "") or itemName
			local cacheHit = sellPane:DoSearch(searchName, exact, 20)

			sellPane.totalItems = Atr_GetNumItemInBags(itemName, wasBloodforged)
			sellPane.fullStackSize = itemLink and select(8, GetItemInfo(itemLink)) or 0

			local prefNumStacks, prefStackSize = Atr_GetSellStacking(itemLink, itemCount, sellPane.totalItems)

			if time() - autoSingletonRequestedAt < 5 then
				Atr_SetInitialStacking(1, 1)
			else
				Atr_SetInitialStacking(prefNumStacks, prefStackSize)
			end

			if cacheHit then
				Atr_OnSearchComplete()
			end

			Atr_SetTextureButton("Atr_SellControls_Tex", Atr_StackSize(), itemLink)
			Atr_SellControls_TexName:SetText(itemName)
		else
			Atr_SetTextureButton("Atr_SellControls_Tex", 0, nil)
			Atr_SellControls_TexName:SetText("")
		end

	elseif Atr_StackSize() ~= itemCount then

		local prefNumStacks, prefStackSize = Atr_GetSellStacking(itemLink, itemCount, sellPane.totalItems)
		Atr_SetInitialStacking(prefNumStacks, prefStackSize)
		Atr_SetTextureButton("Atr_SellControls_Tex", Atr_StackSize(), itemLink)
		Atr_FindBestCurrentAuction()
		Atr_ResetDuration()
	end

	sellPane.UINeedsUpdate = true
end

-----------------------------------------
-- Main per-frame UI refresh
-----------------------------------------

function Atr_UpdateUI()

	local needsUpdate = currentPane.UINeedsUpdate

	if currentPane.UINeedsUpdate then

		currentPane.UINeedsUpdate = false

		if Atr_ShowingSearchSummary() then
			Atr_ShowSearchSummary()
		elseif currentPane:ShowCurrent() then
			PanelTemplates_SetTab(Atr_ListTabs, 1)
			Atr_ShowCurrentAuctions()
		elseif currentPane:ShowHistory() then
			PanelTemplates_SetTab(Atr_ListTabs, 2)
			Atr_ShowHistory()
		else
			PanelTemplates_SetTab(Atr_ListTabs, 3)
			Atr_ShowHints()
		end

		if currentPane:IsScanEmpty() then
			Atr_ListTabs:Hide()
		else
			Atr_ListTabs:Show()
		end

		Atr_SetMessage("")

		if Atr_IsModeCreateAuction() then
			Atr_UpdateRecommendation(false)
		else
			Atr_HideElems(recommendElements)

			local scan = currentPane.activeScan
			if scan:IsNil() then
				Atr_ShowItemNameAndTexture(currentPane.activeSearch.searchText)
			else
				Atr_ShowItemNameAndTexture(scan.itemName)
			end

			if Atr_IsModeBuy() and currentPane.activeSearch.searchText == "" then
				Atr_SetMessage(ZT("Select an item from the list on the left\n or type a search term above to start a scan."))
			end
		end

		if Atr_IsTabSelected(BUY_TAB) then
			Atr_Shop_UpdateUI()
		end
	end

	if hlistNeedsUpdate and Atr_IsModeActiveAuctions() then
		hlistNeedsUpdate = false
		Atr_DisplayHlist()
	end

	if Atr_IsTabSelected(SELL_TAB) then
		Atr_UpdateUI_SellPane(needsUpdate)
	end
end

function Atr_UpdateUI_SellPane(needsUpdate)

	local auctionItemName = GetAuctionSellItemInfo()

	if needsUpdate then

		if currentPane.activeSearch and currentPane.activeSearch.processingState ~= KM_NULL_STATE then
			Atr_CreateAuctionButton:Disable()
			Atr_FullScanButton:Disable()
			Auctionator1Button:Disable()
			MoneyInputFrame_SetCopper(Atr_StartingPrice, 0)
			return
		end

		Atr_FullScanButton:Enable()
		Auctionator1Button:Enable()

		if Atr_Batch_Stacksize.oldStackSize ~= Atr_StackSize() then
			Atr_Batch_Stacksize.oldStackSize = Atr_StackSize()
			local itemPrice = MoneyInputFrame_GetCopper(Atr_ItemPrice)
			MoneyInputFrame_SetCopper(Atr_StackPrice, itemPrice * Atr_StackSize())
		end

		Atr_StartingPriceDiscountText:SetText(ZT("Starting Price Discount") .. ":  " .. AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT .. "%")

		if Atr_Batch_NumAuctions:GetNumber() < 2 then
			Atr_Batch_Stacksize_Text:SetText(ZT("stack of"))
			Atr_CreateAuctionButton:SetText(ZT("Create Auction"))
		else
			Atr_Batch_Stacksize_Text:SetText(ZT("stacks of"))
			Atr_CreateAuctionButton:SetText(string.format(ZT("Create %d Auctions"), Atr_Batch_NumAuctions:GetNumber()))
		end

		if Atr_StackSize() > 1 then
			Atr_StackPriceText:SetText(ZT("Buyout Price") .. " |cff55ddffx" .. Atr_StackSize() .. "|r")
			Atr_ItemPriceText:SetText(ZT("Per Item"))
			Atr_ItemPriceText:Show()
			Atr_ItemPrice:Show()
		else
			Atr_StackPriceText:SetText(ZT("Buyout Price"))
			Atr_ItemPriceText:Hide()
			Atr_ItemPrice:Hide()
		end

		Atr_SetTextureButton("Atr_SellControls_Tex", Atr_StackSize(), Atr_GetItemLink(auctionItemName))

		local maxAuctions = 0
		if Atr_StackSize() > 0 then
			maxAuctions = math.floor(currentPane.totalItems / Atr_StackSize())
		end

		Atr_Batch_MaxAuctions_Text:SetText(ZT("max") .. ": " .. maxAuctions)
		Atr_Batch_MaxStacksize_Text:SetText(ZT("max") .. ": " .. currentPane.fullStackSize)

		Atr_SetDepositText()

		if justPosted_ItemName ~= nil then

			Atr_Recommend_Text:SetText(string.format(ZT("Auction created for %s"), justPosted_ItemName))
			MoneyFrame_Update("Atr_RecommendPerStack_Price", justPosted_BuyoutPrice)
			Atr_SetTextureButton("Atr_RecommendItem_Tex", justPosted_StackSize, justPosted_ItemLink)

			currentPane.currIndex = currentPane.activeScan:FindInSortedData(justPosted_StackSize, justPosted_BuyoutPrice)

			if currentPane:ShowCurrent() then
				Atr_HighlightEntry(currentPane.currIndex)
			else
				Atr_HighlightEntry(currentPane.histIndex)
			end

		elseif currentPane:IsScanEmpty() then
			Atr_SetMessage(ZT("Drag an item you want to sell to this area."))
		end
	end

	-- Runs every frame, not just on needsUpdate, since these reflect
	-- live edits to the price/stack-count input fields.
	local startingPrice = MoneyInputFrame_GetCopper(Atr_StartingPrice)
	local buyoutPrice = MoneyInputFrame_GetCopper(Atr_StackPrice)

	local pricesValid = startingPrice > 0 and (startingPrice <= buyoutPrice or buyoutPrice == 0) and auctionItemName ~= nil
	local numToSell = Atr_Batch_NumAuctions:GetNumber() * Atr_Batch_Stacksize:GetNumber()

	zc.EnableDisable(Atr_CreateAuctionButton, pricesValid and numToSell <= currentPane.totalItems)
end

function Atr_SetDepositText()

	local _, itemCount = Atr_GetSellItemInfo()

	if itemCount <= 0 then
		Atr_Deposit_Text:SetText("")
		return
	end

	local duration = UIDropDownMenu_GetSelectedValue(Atr_Duration)
	local startingPrice = MoneyInputFrame_GetCopper(Atr_StartingPrice)
	local buyoutPrice = MoneyInputFrame_GetCopper(Atr_StackPrice)
	local depositPerStack = CalculateAuctionDeposit(duration, 1, startingPrice, buyoutPrice)

	local numAuctionsSuffix = ""
	if Atr_Batch_NumAuctions:GetNumber() > 1 then
		numAuctionsSuffix = "  |cffff55ff x" .. Atr_Batch_NumAuctions:GetNumber()
	end

	Atr_Deposit_Text:SetText(ZT("Deposit") .. ":    " .. zc.priceToMoneyString(depositPerStack * Atr_StackSize(), true) .. numAuctionsSuffix)
end

-----------------------------------------
-- Active-auctions cache (used by the undercut checker/icon)
-----------------------------------------

function Atr_BuildActiveAuctions()

	activeAuctionsCache = {}

	local i = 1
	while true do
		local name, _, count = GetAuctionItemInfo("owner", i)
		if name == nil then
			break
		end

		if count > 0 then -- count is 0 for already-sold items
			activeAuctionsCache[name] = (activeAuctionsCache[name] or 0) + 1
		end

		i = i + 1
	end
end

-- Returns a small icon indicating whether the player's own auction for
-- `itemName` is currently the cheapest, undercut, or mixed.
function Atr_GetUCIcon(itemName)

	local icon = "|TInterface\\BUTTONS\\UI-PassiveHighlight:18:18:0:0|t "
	local wasUndercut = false

	local scan = Atr_FindScan(itemName)

	if scan and scan.absoluteBest and scan.whenScanned ~= 0 and scan.yourBestPrice and scan.yourWorstPrice then

		local bestPrice = scan.absoluteBest.itemPrice

		if scan.yourBestPrice <= bestPrice and scan.yourWorstPrice > bestPrice then
			icon = "|TInterface\\AddOns\\Auctionator\\Images\\CrossAndCheck:18:18:0:0|t "
			wasUndercut = true
		elseif scan.yourBestPrice <= bestPrice then
			icon = "|TInterface\\RAIDFRAME\\ReadyCheck-Ready:18:18:0:0|t "
		else
			icon = "|TInterface\\RAIDFRAME\\ReadyCheck-NotReady:18:18:0:0|t "
			wasUndercut = true
		end
	end

	if checkingActive_State ~= ATR_CACT_NULL and wasUndercut then
		checkingActive_NumUndercuts = checkingActive_NumUndercuts + 1
	end

	return icon
end

-----------------------------------------
-- History / active-items list (the "More" tab)
-----------------------------------------

function Atr_DisplayHlist()

	if Atr_IsTabSelected(BUY_TAB) then -- shared scroll-frame callback also serves the shopping-list view
		Atr_DisplaySlist()
		return
	end

	local showAllItems = (UIDropDownMenu_GetSelectedValue(Atr_DropDown1) == MODE_LIST_ALL)

	Atr_BuildGlobalHistoryList(showAllItems)

	local numRows = #sortedHistoryItemList

	FauxScrollFrame_Update(Atr_Hlist_ScrollFrame, numRows, ITEM_HIST_NUM_LINES, 16)

	for line = 1, ITEM_HIST_NUM_LINES do

		currentPane.hlistScrollOffset = FauxScrollFrame_GetOffset(Atr_Hlist_ScrollFrame)
		local dataOffset = line + currentPane.hlistScrollOffset

		local rowFrame = _G["AuctionatorHEntry" .. line]
		rowFrame:SetID(dataOffset)

		if dataOffset <= numRows and sortedHistoryItemList[dataOffset] then

			local itemName = sortedHistoryItemList[dataOffset]
			local icon = showAllItems and "" or Atr_GetUCIcon(itemName)

			_G["AuctionatorHEntry" .. line .. "_EntryText"]:SetText(icon .. Atr_AbbrevItemName(itemName))

			local isSelected = (itemName == currentPane.activeSearch.searchText)
			rowFrame:SetButtonState(isSelected and "PUSHED" or "NORMAL", isSelected)
			rowFrame:Show()
		else
			rowFrame:Hide()
		end
	end
end

function Atr_ClearHlist()
	for line = 1, ITEM_HIST_NUM_LINES do
		local rowFrame = _G["AuctionatorHEntry" .. line]
		rowFrame:Hide()

		local textFrame = _G["AuctionatorHEntry" .. line .. "_EntryText"]
		textFrame:SetText("")
		textFrame:SetTextColor(.7, .7, .7)
	end
end

function Atr_HEntryOnClick(itemNameOverride)

	if currentPane == shopPane then
		Atr_SEntryOnClick()
		return
	end

	local itemName = itemNameOverride
	local rowFrame = this

	if not itemName then

		if pendingHentryRetry then
			rowFrame = pendingHentryRetry
			pendingHentryRetry = nil
		end

		itemName = sortedHistoryItemList[rowFrame:GetID()]
	end

	if IsAltKeyDown() and Atr_IsModeActiveAuctions() then
		Atr_Cancel_Undercuts_OnClick(itemName)
		return
	end

	local itemLink

	if AUCTIONATOR_PRICING_HISTORY[itemName] then

		local itemID, suffixID, uniqueID = strsplit(":", AUCTIONATOR_PRICING_HISTORY[itemName]["is"])
		itemID = tonumber(itemID)
		suffixID = suffixID and tonumber(suffixID) or 0
		uniqueID = uniqueID and tonumber(suffixID) or 0

		local itemString = "item:" .. itemID .. ":0:0:0:0:0:" .. suffixID .. ":" .. uniqueID
		_, itemLink = GetItemInfo(itemString)

		if itemLink == nil then
			-- Not cached locally yet: request it and retry once it arrives.
			AtrScanningTooltip:SetHyperlink(itemString)
			pendingHentryRetry = rowFrame
			zc.md("pulling " .. itemName .. " into the local cache")
			return
		end
	end

	currentPane.UINeedsUpdate = true

	Atr_ClearAll()

	local cacheHit = currentPane:DoSearch(itemName, true, 20)

	Atr_Process_Historydata()
	Atr_FindBestHistoricalAuction()

	Atr_DisplayHlist() -- refresh the row highlight

	if cacheHit then
		Atr_OnSearchComplete()
	end

	PlaySound("igMainMenuOptionCheckBoxOn")
end

function Atr_ShowWhichRB(radioButtonID)

	if currentPane.activeSearch.processingState ~= KM_NULL_STATE then
		return -- ignore clicks while an auction scan is in progress
	end

	PlaySound("igMainMenuOptionCheckBoxOn")

	if radioButtonID == 1 then     currentPane:SetToShowCurrent()
	elseif radioButtonID == 2 then currentPane:SetToShowHistory()
	else                            currentPane:SetToShowHints()
	end

	currentPane.UINeedsUpdate = true
end

function Atr_RedisplayAuctions()
	if Atr_ShowingSearchSummary() then      Atr_ShowSearchSummary()
	elseif Atr_ShowingCurrentAuctions() then Atr_ShowCurrentAuctions()
	elseif Atr_ShowingHistory() then         Atr_ShowHistory()
	else                                      Atr_ShowHints()
	end
end

function Atr_BuildHistItemText(historyEntry)

	local now = time()
	local nowTable = date("*t")
	local whenTable = date("*t", historyEntry.when)

	if historyEntry.type == "hy" then
		return ZT("average of your auctions for") .. " " .. whenTable.year
	elseif historyEntry.type == "hm" then
		if nowTable.year == whenTable.year then
			return ZT("average of your auctions for") .. " " .. date("%B", historyEntry.when)
		end
		return ZT("average of your auctions for") .. " " .. date("%B %Y", historyEntry.when)
	elseif historyEntry.type == "hd" then
		return ZT("average of your auctions for") .. " " .. FormatMonthDay(whenTable)
	end

	return ZT("your auction on") .. " " .. FormatMonthDay(whenTable) .. date(" at %I:%M %p", historyEntry.when)
end

function FormatMonthDay(whenTable)
	return date("%b ", time(whenTable)) .. whenTable.day
end

function Atr_ShowLineTooltip(self)
	if self.itemLink then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT", -280)
		GameTooltip:SetHyperlink(self.itemLink, 1)
	end
end

function Atr_HideLineTooltip()
	GameTooltip:Hide()
end

function Atr_Onclick_Back()
	currentPane.activeScan = Atr_FindScan(nil)
	currentPane.UINeedsUpdate = true
end

function Atr_Onclick_Col1()
	if currentPane.activeSearch then
		currentPane.activeSearch:ClickPriceCol()
		currentPane.UINeedsUpdate = true
	end
end

function Atr_Onclick_Col3()
	if currentPane.activeSearch then
		currentPane.activeSearch:ClickNameCol()
		currentPane.UINeedsUpdate = true
	end
end

-----------------------------------------
-- Result list rendering (three variants: search summary, current
-- auctions for one item, and sale history for one item)
-----------------------------------------

function Atr_ShowSearchSummary()

	Atr_Col1_Heading:Hide()
	Atr_Col3_Heading:Hide()
	Atr_Col1_Heading_Button:Show()
	Atr_Col3_Heading_Button:Show()
	Atr_Col4_Heading:Show()

	currentPane.activeSearch:UpdateArrows()

	local numRows = currentPane.activeSearch:NumScans()

	Atr_Col4_Heading:SetText(currentPane.activeScan.hasStack and ZT("Total Price") or "")

	local highlightIndex = 0
	local dataOffset = FauxScrollFrame_GetOffset(AuctionatorScrollFrame)

	FauxScrollFrame_Update(AuctionatorScrollFrame, numRows, 12, 16)

	for line = 1, 12 do

		dataOffset = dataOffset + 1

		local rowFrame = _G["AuctionatorEntry" .. line]
		rowFrame:SetID(dataOffset)

		local scan
		if currentPane.activeSearch and currentPane.activeSearch:NumSortedScans() > 0 then
			scan = currentPane.activeSearch.sortedScans[dataOffset]
		end

		if dataOffset > numRows or not scan then
			rowFrame:Hide()
		else
			local bestData = scan.absoluteBest
			local priceTag = "AuctionatorEntry" .. line .. "_PerItem_Price"

			local priceFrame = _G[priceTag]
			local priceTextFrame = _G["AuctionatorEntry" .. line .. "_PerItem_Text"]
			local nameFrame = _G["AuctionatorEntry" .. line .. "_EntryText"]
			local stackFrame = _G["AuctionatorEntry" .. line .. "_StackPrice"]

			priceTextFrame:SetText("")
			nameFrame:SetText("")
			stackFrame:SetText("")
			nameFrame:GetParent():SetPoint("LEFT", 157, 0)

			Atr_SetMFcolor(priceTag)

			rowFrame:Show()
			rowFrame.itemLink = scan.itemLink

			local r, g, b = scan.itemTextColor[1], scan.itemTextColor[2], scan.itemTextColor[3]
			nameFrame:SetTextColor(r, g, b)
			stackFrame:SetTextColor(1, 1, 1)

			local icon = Atr_GetUCIcon(scan.itemName)
			nameFrame:SetText(icon .. "  " .. scan.itemName)
			stackFrame:SetText(scan:GetNumAvailable() .. " " .. ZT("available"))

			if bestData == nil or bestData.buyoutPrice == 0 then
				priceFrame:Hide()
				priceTextFrame:Show()
				priceTextFrame:SetText(ZT("no buyout price"))
			else
				priceFrame:Show()
				priceTextFrame:Hide()
				MoneyFrame_Update(priceTag, zc.round(bestData.buyoutPrice / bestData.stackSize))
			end

			if zc.StringSame(scan.itemName, currentPane.SS_hilite_itemName) then
				highlightIndex = dataOffset
			end
		end
	end

	Atr_HighlightEntry(highlightIndex)
end

function Atr_ShowCurrentAuctions()

	Atr_Col1_Heading:Hide()
	Atr_Col3_Heading:Hide()
	Atr_Col4_Heading:Hide()
	Atr_Col1_Heading_Button:Hide()
	Atr_Col3_Heading_Button:Hide()

	local numRows = #currentPane.activeScan.sortedData

	if numRows > 0 then
		Atr_Col1_Heading:Show()
		Atr_Col3_Heading:Show()
		Atr_Col4_Heading:Show()
	end

	Atr_Col1_Heading:SetText(ZT("Item Price"))
	Atr_Col3_Heading:SetText(ZT("Current Auctions"))
	Atr_Col4_Heading:SetText(currentPane.activeScan.hasStack and ZT("Stack Price") or "")

	local dataOffset = FauxScrollFrame_GetOffset(AuctionatorScrollFrame)

	FauxScrollFrame_Update(AuctionatorScrollFrame, numRows, 12, 16)

	for line = 1, 12 do

		dataOffset = dataOffset + 1

		local rowFrame = _G["AuctionatorEntry" .. line]
		rowFrame:SetID(dataOffset)
		rowFrame.itemLink = nil

		local data = currentPane.activeScan.sortedData[dataOffset]

		if dataOffset > numRows or not data then
			rowFrame:Hide()
		else
			local priceTag = "AuctionatorEntry" .. line .. "_PerItem_Price"

			local priceFrame = _G[priceTag]
			local priceTextFrame = _G["AuctionatorEntry" .. line .. "_PerItem_Text"]
			local nameFrame = _G["AuctionatorEntry" .. line .. "_EntryText"]
			local stackFrame = _G["AuctionatorEntry" .. line .. "_StackPrice"]

			priceTextFrame:SetText("")
			nameFrame:SetText("")
			stackFrame:SetText("")
			nameFrame:GetParent():SetPoint("LEFT", 172, 0)

			Atr_SetMFcolor(priceTag)

			if data.type ~= "n" then
				zc.msg_red("Unknown datatype:")
				zc.msg_red(data.type)
			else

				rowFrame:Show()

				local countWord = (data.count == 1) and ZT("stack of") or ZT("stacks of")
				local entryText = string.format("%i %s %i", data.count, countWord, data.stackSize)

				nameFrame:SetTextColor(0.6, 0.6, 0.6)

				if data.stackSize == Atr_StackSize() or Atr_StackSize() == 0 or currentPane ~= sellPane then
					nameFrame:SetTextColor(1.0, 1.0, 1.0)
				end

				if data.yours then
					entryText = entryText .. " (" .. ZT("yours") .. ")"
				elseif data.altName then
					entryText = entryText .. " (" .. data.altName .. ")"
				end

				nameFrame:SetText(entryText)

				if data.buyoutPrice == 0 then
					priceFrame:Hide()
					priceTextFrame:Show()
					priceTextFrame:SetText(ZT("no buyout price"))
				else
					priceFrame:Show()
					priceTextFrame:Hide()
					MoneyFrame_Update(priceTag, zc.round(data.buyoutPrice / data.stackSize))

					if data.stackSize > 1 then
						stackFrame:SetText(zc.priceToString(data.buyoutPrice))
						stackFrame:SetTextColor(0.6, 0.6, 0.6)
					end
				end
			end
		end
	end

	Atr_HighlightEntry(currentPane.currIndex)
end

function Atr_ShowHistory()

	if currentPane.sortedHist == nil then
		Atr_Process_Historydata()
		Atr_FindBestHistoricalAuction()
	end

	Atr_Col1_Heading:Hide()
	Atr_Col3_Heading:Hide()
	Atr_Col4_Heading:Hide()
	Atr_Col3_Heading:SetText(ZT("History"))

	local numRows = currentPane.sortedHist and #currentPane.sortedHist or 0

	if numRows > 0 then
		Atr_Col1_Heading:Show()
		Atr_Col3_Heading:Show()
	end

	FauxScrollFrame_Update(AuctionatorScrollFrame, numRows, 12, 16)

	for line = 1, 12 do

		local dataOffset = line + FauxScrollFrame_GetOffset(AuctionatorScrollFrame)
		local rowFrame = _G["AuctionatorEntry" .. line]
		rowFrame:SetID(dataOffset)

		if dataOffset <= numRows and currentPane.sortedHist[dataOffset] then

			local historyEntry = currentPane.sortedHist[dataOffset]
			local priceTag = "AuctionatorEntry" .. line .. "_PerItem_Price"

			local priceFrame = _G[priceTag]
			local priceTextFrame = _G["AuctionatorEntry" .. line .. "_PerItem_Text"]
			local nameFrame = _G["AuctionatorEntry" .. line .. "_EntryText"]
			local stackFrame = _G["AuctionatorEntry" .. line .. "_StackPrice"]

			priceFrame:Show()
			priceTextFrame:Hide()
			stackFrame:SetText("")

			Atr_SetMFcolor(priceTag)
			MoneyFrame_Update(priceTag, zc.round(historyEntry.itemPrice))

			nameFrame:SetText(Atr_BuildHistItemText(historyEntry))
			nameFrame:SetTextColor(0.8, 0.8, 1.0)

			rowFrame:Show()
		else
			rowFrame:Hide()
		end
	end

	if Atr_IsTabSelected(SELL_TAB) then
		Atr_HighlightEntry(currentPane.histIndex)
	else
		Atr_HighlightEntry(-1)
	end
end

function Atr_FindBestCurrentAuction()

	local scan = currentPane.activeScan

	if Atr_IsModeCreateAuction() or Atr_IsModeBuy() then
		currentPane.currIndex = scan:FindCheapest()
	else
		currentPane.currIndex = scan:FindMatchByYours()
	end
end

function Atr_FindBestHistoricalAuction()
	currentPane.histIndex = nil
	if currentPane.sortedHist and #currentPane.sortedHist > 0 then
		currentPane.histIndex = 1
	end
end

function Atr_HighlightEntry(entryIndex)

	for line = 1, 12 do
		local rowFrame = _G["AuctionatorEntry" .. line]
		local isSelected = (rowFrame:GetID() == entryIndex)
		rowFrame:SetButtonState(isSelected and "PUSHED" or "NORMAL", isSelected)
	end

	local canCancel, canBuy = false, false
	local data

	if Atr_ShowingCurrentAuctions() and entryIndex and entryIndex > 0 and entryIndex <= #currentPane.activeScan.sortedData then

		data = currentPane.activeScan.sortedData[entryIndex]

		if data.yours then
			canCancel = true
		end
		if not data.yours and not data.altName and data.buyoutPrice > 0 then
			canBuy = true
		end
	end

	Atr_Buy1_Button:Disable()
	Atr_CancelSelectionButton:Disable()

	if canCancel then
		Atr_CancelSelectionButton:Enable()
		Atr_CancelSelectionButton:SetText(data.count == 1 and CANCEL_AUCTION or ZT("Cancel Auctions"))
	end

	if canBuy then
		Atr_Buy1_Button:Enable()
	end
end

function Atr_EntryOnClick()

	local entryIndex = this:GetID()

	if Atr_ShowingSearchSummary() then
		-- handled fully below
	elseif Atr_ShowingCurrentAuctions() then
		currentPane.currIndex = entryIndex
	elseif Atr_ShowingHistory() then
		currentPane.histIndex = entryIndex
	else
		currentPane.hintsIndex = entryIndex
	end

	if Atr_ShowingSearchSummary() then

		local scan = currentPane.activeSearch.sortedScans[entryIndex]

		FauxScrollFrame_SetOffset(AuctionatorScrollFrame, 0)
		currentPane.activeScan = scan
		currentPane.currIndex = scan:FindMatchByYours()
		currentPane.SS_hilite_itemName = scan.itemName
		currentPane.UINeedsUpdate = true
	else
		Atr_HighlightEntry(entryIndex)
		Atr_UpdateRecommendation(true)
	end

	PlaySound("igMainMenuOptionCheckBoxOn")
end

function AuctionatorMoneyFrame_OnLoad()
	this.small = 1
	MoneyFrame_SetType(this, "AUCTION")
end

-----------------------------------------
-- Bag scanning
-----------------------------------------

function Atr_GetNumItemInBags(itemName, wasBloodforged)

	if itemName:sub(1, 3) == "RE:" or wasBloodforged then
		return 1 -- these are one-off special cases where a bag count isn't meaningful
	end

	local total = 0

	for _, bagID in ipairs(allBagIDs) do
		local numSlots = GetContainerNumSlots(bagID)
		for slotID = 1, numSlots do
			local itemLink = GetContainerItemLink(bagID, slotID)
			if itemLink then
				local slotItemName = GetItemInfo(itemLink)
				local _, itemCount = GetContainerItemInfo(bagID, slotID)
				if slotItemName == itemName then
					total = total + itemCount
				end
			end
		end
	end

	return total
end

-----------------------------------------
-- Cancelling auctions
-----------------------------------------

function Atr_CancelAuction(index)
	CancelAuction(index)
end

function Atr_LogCancelAuction(numCancelled, itemLink, stackSize)

	local stackSuffix = (stackSize and stackSize > 1) and ("|cff00ddddx" .. stackSize) or ""

	if numCancelled > 1 then
		zc.msg_yellow(numCancelled .. ZT(" auctions cancelled for ") .. itemLink .. stackSuffix)
	elseif numCancelled == 1 then
		zc.msg_yellow(ZT("Auction cancelled for ") .. itemLink .. stackSuffix)
	end
end

function Atr_CancelSelection_OnClick()
	if Atr_ShowingCurrentAuctions() then
		Atr_CancelAuction_ByIndex(currentPane.currIndex)
	end
end

function Atr_CancelAuction_ByIndex(index)

	local data = currentPane.activeScan.sortedData[index]

	if not data.yours then
		return
	end

	local numCancelled = 0
	local itemLink = currentPane.activeScan.itemLink

	local i = 1
	while true do
		local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("owner", i)
		if name == nil then
			break
		end

		if name == currentPane.activeScan.itemName and buyoutPrice == data.buyoutPrice and count == data.stackSize then
			Atr_CancelAuction(i)
			numCancelled = numCancelled + 1
			AuctionatorSubtractFromScan(name, count, buyoutPrice)
			justPosted_ItemName = nil
		end

		i = i + 1
	end

	Atr_LogCancelAuction(numCancelled, itemLink, data.stackSize)
end

-----------------------------------------
-- Per-item / per-category stacking preferences
-----------------------------------------

function Atr_StackingPrefs_Init()
	AUCTIONATOR_STACKING_PREFS = {}
end

function Atr_Has_StackingPrefs(key)
	return AUCTIONATOR_STACKING_PREFS[key:lower()] ~= nil
end

function Atr_Clear_StackingPrefs(key)
	AUCTIONATOR_STACKING_PREFS[key:lower()] = nil
end

function Atr_Get_StackingPrefs(key)
	local lowerKey = key:lower()
	if Atr_Has_StackingPrefs(lowerKey) then
		return AUCTIONATOR_STACKING_PREFS[lowerKey].numStacks, AUCTIONATOR_STACKING_PREFS[lowerKey].stackSize
	end
	return nil, nil
end

function Atr_Set_StackingPrefs_numstacks(key, numStacks)
	local lowerKey = key:lower()
	AUCTIONATOR_STACKING_PREFS[lowerKey] = AUCTIONATOR_STACKING_PREFS[lowerKey] or { stackSize = 0 }
	AUCTIONATOR_STACKING_PREFS[lowerKey].numStacks = zc.Val(numStacks, 1)
end

function Atr_Set_StackingPrefs_stacksize(key, stackSize)
	local lowerKey = key:lower()
	AUCTIONATOR_STACKING_PREFS[lowerKey] = AUCTIONATOR_STACKING_PREFS[lowerKey] or { numStacks = 0 }
	AUCTIONATOR_STACKING_PREFS[lowerKey].stackSize = zc.Val(stackSize, 1)
end

function Atr_GetStackingPrefs_ByItem(itemLink)

	if not itemLink then
		return nil, nil
	end

	local itemName = GetItemInfo(itemLink)

	for text, prefs in pairs(AUCTIONATOR_STACKING_PREFS) do
		if zc.StringContains(itemName, text) then
			return prefs.numStacks, prefs.stackSize
		end
	end

	if Atr_IsGlyph(itemLink) then                              return Atr_Special_SP(ATR_SK_GLYPHS, 0, 1) end
	if Atr_IsCutGem(itemLink) then                              return Atr_Special_SP(ATR_SK_GEMS_CUT, 0, 1) end
	if Atr_IsGem(itemLink) then                                 return Atr_Special_SP(ATR_SK_GEMS_UNCUT, 1, 0) end
	if Atr_IsItemEnhancement(itemLink) then                     return Atr_Special_SP(ATR_SK_ITEM_ENH, 0, 1) end
	if Atr_IsPotion(itemLink) or Atr_IsElixir(itemLink) then    return Atr_Special_SP(ATR_SK_POT_ELIX, 1, 0) end
	if Atr_IsFlask(itemLink) then                               return Atr_Special_SP(ATR_SK_FLASKS, 1, 0) end
	if Atr_IsHerb(itemLink) then                                return Atr_Special_SP(ATR_SK_HERBS, 1, 0) end

	return nil, nil
end

function Atr_Special_SP(key, defaultNumStacks, defaultStackSize)
	if Atr_Has_StackingPrefs(key) then
		return Atr_Get_StackingPrefs(key)
	end
	return defaultNumStacks, defaultStackSize
end

-- Computes how many stacks (and of what size) to pre-fill when an item is
-- dragged into the sell pane, honoring any saved preference for it.
function Atr_GetSellStacking(itemLink, numDragged, numTotal)

	local prefNumStacks, prefStackSize = Atr_GetStackingPrefs_ByItem(itemLink)

	if prefNumStacks == nil then
		return 1, numDragged
	end

	if prefNumStacks <= 0 and prefStackSize <= 0 then
		prefStackSize = 1 -- shouldn't happen, but guards against a zero-size stack
	end

	local numStacks = prefNumStacks
	local stackSize = prefStackSize
	local numToSell = numDragged

	if numStacks == -1 then -- "as many stacks as possible"
		numToSell = numTotal
	elseif stackSize == 0 then -- "auto" stack size
		stackSize = math.floor(numDragged / numStacks)
	elseif numStacks > 0 then
		numToSell = math.min(numStacks * stackSize, numTotal)
	end

	numStacks = math.floor(numToSell / stackSize)

	if numStacks == 0 then
		numStacks = 1
		stackSize = numToSell
	end

	return numStacks, stackSize
end

local initialNumStacks, initialStackSize -- remembers the values as-shown, to detect user edits

function Atr_SetInitialStacking(numStacks, stackSize)
	initialNumStacks = numStacks
	initialStackSize = stackSize
	Atr_Batch_NumAuctions:SetText(numStacks)
	Atr_SetStackSize(stackSize)
end

-- If the user changed the pre-filled stack size before creating the
-- auction, remember their choice as a new preference for this item (or
-- clear it if they set it back to the default single-stack behavior).
function Atr_Memorize_Stacking_If()

	local newNumStacks = Atr_Batch_NumAuctions:GetNumber()
	local newStackSize = Atr_StackSize()

	local stackSizeChanged = tonumber(initialStackSize) ~= newStackSize

	if not stackSizeChanged then
		return
	end

	local itemName = string.lower(currentPane.activeScan.itemName)

	if not itemName then
		return
	end

	if newNumStacks == 1 then
		local _, _, auctionCount = GetAuctionSellItemInfo()
		if auctionCount == newStackSize then
			Atr_Clear_StackingPrefs(itemName)
			return
		end
	end

	Atr_Set_StackingPrefs_stacksize(itemName, Atr_StackSize())
end

-----------------------------------------
-- Interface predicates
-----------------------------------------

function Atr_IsTabSelected(whichTab)

	if not AuctionFrame or not AuctionFrame:IsShown() then
		return false
	end

	if not whichTab then
		return Atr_IsTabSelected(SELL_TAB) or Atr_IsTabSelected(MORE_TAB) or Atr_IsTabSelected(BUY_TAB)
	end

	return PanelTemplates_GetSelectedTab(AuctionFrame) == Atr_FindTabIndex(whichTab)
end

function Atr_IsAuctionatorTab(tabIndex)
	return tabIndex == Atr_FindTabIndex(SELL_TAB)
		or tabIndex == Atr_FindTabIndex(MORE_TAB)
		or tabIndex == Atr_FindTabIndex(BUY_TAB)
end

-----------------------------------------
-- Confirmation dialog (generic yes/no)
-----------------------------------------

local confirmYesCallback

function Atr_Confirm_Yes()
	if confirmYesCallback then
		confirmYesCallback()
		confirmYesCallback = nil
	end
	Atr_Confirm_Frame:Hide()
end

function Atr_Confirm_No()
	Atr_Confirm_Frame:Hide()
end

-----------------------------------------
-- Historical price recording
-----------------------------------------

function Atr_AddHistoricalPrice(itemName, price, stackSize, itemLink, testWhen)

	AUCTIONATOR_PRICING_HISTORY[itemName] = AUCTIONATOR_PRICING_HISTORY[itemName] or {}

	local itemID, suffixID, uniqueID = zc.ItemIDfromLink(itemLink)
	local uniqueItemInfo = itemID

	if suffixID ~= 0 then
		uniqueItemInfo = uniqueItemInfo .. ":" .. suffixID
		if tonumber(suffixID) < 0 then
			uniqueItemInfo = uniqueItemInfo .. ":" .. uniqueID
		end
	end

	AUCTIONATOR_PRICING_HISTORY[itemName]["is"] = uniqueItemInfo

	local historyValue = tostring(zc.round(price)) .. ":" .. stackSize

	-- Rounds to the minute so multiple auctions closing together don't
	-- generate a separate history entry each.
	local roundedTime = testWhen or (floor(time() / 60) * 60)
	local tag = tostring(ToTightTime(roundedTime))

	AUCTIONATOR_PRICING_HISTORY[itemName][tag] = historyValue

	currentPane.sortedHist = nil
end

function Atr_HasHistoricalData(itemName)
	return AUCTIONATOR_PRICING_HISTORY[itemName] ~= nil
end

function Atr_BuildGlobalHistoryList(includeAllItems)

	sortedHistoryItemList = {}
	local i = 1

	if includeAllItems then
		for name in pairs(AUCTIONATOR_PRICING_HISTORY) do
			sortedHistoryItemList[i] = name
			i = i + 1
		end
	else
		if zc.tableIsEmpty(activeAuctionsCache) then
			Atr_BuildActiveAuctions()
		end

		for name, count in pairs(activeAuctionsCache) do
			if name and count ~= 0 then
				sortedHistoryItemList[i] = name
				i = i + 1
			end
		end
	end

	table.sort(sortedHistoryItemList)
end

function Atr_FindHListIndexByName(itemName)
	for i, name in ipairs(sortedHistoryItemList) do
		if itemName == name then
			return i
		end
	end
	return 0
end

-----------------------------------------
-- "Check for Undercuts" workflow
-----------------------------------------

local checkingActive_NextItemName
local checkingActive_AndCancel = false

function Atr_CheckActive_OnClick(andCancel)

	if checkingActive_State == ATR_CACT_NULL then
		Atr_CheckActiveList(andCancel)
	else
		Atr_CheckingActive_Finish()
		currentPane.activeSearch:Abort()
		currentPane:ClearSearch()
		Atr_SetMessage(ZT("Checking stopped"))
	end
end

function Atr_CheckActiveList(andCancel)

	checkingActive_State          = ATR_CACT_READY
	checkingActive_NextItemName   = sortedHistoryItemList[1]
	checkingActive_AndCancel      = andCancel
	checkingActive_NumUndercuts   = 0

	currentPane:SetToShowCurrent()
	Atr_CheckingActiveIdle()
end

function Atr_CheckingActive_Finish()
	checkingActive_State = ATR_CACT_NULL
	Atr_CheckActiveButton:SetText(ZT("Check for Undercuts"))
end

function Atr_CheckingActiveIdle()

	if checkingActive_State ~= ATR_CACT_READY then
		return
	end

	if checkingActive_NextItemName == nil then

		Atr_CheckingActive_Finish()

		if checkingActive_NumUndercuts > 0 then
			Atr_CheckActives_Frame:Show()
		end

		return
	end

	checkingActive_State = ATR_CACT_PROCESSING
	Atr_CheckActiveButton:SetText(ZT("Stop Checking"))

	local itemName = checkingActive_NextItemName
	local index = Atr_FindHListIndexByName(itemName)

	checkingActive_NextItemName = (index > 0 and #sortedHistoryItemList >= index + 1) and sortedHistoryItemList[index + 1] or nil

	local cacheHit = currentPane:DoSearch(itemName, true, 15)

	Atr_Hilight_Hentry(itemName)

	if cacheHit then
		Atr_CheckingActive_OnSearchComplete()
	end
end

function Atr_CheckActive_IsBusy()
	return checkingActive_State ~= ATR_CACT_NULL
end

function Atr_CheckingActive_OnSearchComplete()
	if checkingActive_State == ATR_CACT_PROCESSING then
		if checkingActive_AndCancel then
			zc.AddDeferredCall(0.1, "Atr_CheckingActive_CheckCancel") -- defer so the UI can show what's about to be cancelled
		else
			zc.AddDeferredCall(0.1, "Atr_CheckingActive_Next")
		end
	end
end

function Atr_CheckingActive_CheckCancel()
	if checkingActive_State == ATR_CACT_PROCESSING then
		Atr_CancelUndercuts_CurrentScan(false)
		if checkingActive_State ~= ATR_CACT_WAITING_ON_CANCEL_CONFIRM then
			zc.AddDeferredCall(0.1, "Atr_CheckingActive_Next")
		end
	end
end

function Atr_CheckingActive_Next()
	if checkingActive_State == ATR_CACT_PROCESSING then
		checkingActive_State = ATR_CACT_READY
	end
end

function Atr_CancelUndercut_Confirm(confirmedCancel)
	checkingActive_State = ATR_CACT_PROCESSING
	Atr_CancelAuction_Confirm_Frame:Hide()
	if confirmedCancel then
		Atr_CancelUndercuts_CurrentScan(true)
	end
	zc.AddDeferredCall(0.1, "Atr_CheckingActive_Next")
end

function Atr_CancelUndercuts_CurrentScan(confirmed)

	local scan = currentPane.activeScan

	for i = #scan.sortedData, 1, -1 do

		local data = scan.sortedData[i]

		if data.yours and data.itemPrice > scan.absoluteBest.itemPrice then

			if not confirmed then
				checkingActive_State = ATR_CACT_WAITING_ON_CANCEL_CONFIRM
				Atr_CancelAuction_Confirm_Frame_text:SetText(string.format(ZT("Your auction has been undercut:\n%s%s"), "|cffffffff", scan.itemName))
				Atr_CancelAuction_Confirm_Frame:Show()
				return
			end

			Atr_CancelAuction_ByIndex(i)
		end
	end
end

function Atr_Cancel_Undercuts_OnClick(nameToCancel)

	local total = GetNumAuctionItems("owner")
	local cancelledByName = {}

	for i = total, 1, -1 do

		local name, _, stackSize, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("owner", i)
		if name == nil then
			break
		end

		if nameToCancel == nil or zc.StringSame(name, nameToCancel) then

			local scan = Atr_FindScan(name)

			if scan and scan.absoluteBest and scan.whenScanned ~= 0 and scan.yourBestPrice and scan.yourWorstPrice then

				local bestPrice = scan.absoluteBest.itemPrice
				local itemPrice = math.floor(buyoutPrice / stackSize)

				if itemPrice > bestPrice then

					Atr_CancelAuction(i)

					cancelledByName[name] = cancelledByName[name] or { num = 0, link = scan.itemLink, stackSize = stackSize }
					cancelledByName[name].num = cancelledByName[name].num + 1

					if scan.yourBestPrice > bestPrice then
						activeAuctionsCache[name] = nil
					end

					AuctionatorSubtractFromScan(name, stackSize, buyoutPrice)
					justPosted_ItemName = nil
				end
			end
		end
	end

	for _, cancelInfo in pairs(cancelledByName) do
		Atr_LogCancelAuction(cancelInfo.num, cancelInfo.link, cancelInfo.stackSize)
	end

	Atr_DisplayHlist()
	Atr_CheckActives_Frame:Hide()
end

function Atr_Hilight_Hentry(itemName)

	for line = 1, ITEM_HIST_NUM_LINES do

		local dataOffset = line + FauxScrollFrame_GetOffset(Atr_Hlist_ScrollFrame)
		local rowFrame = _G["AuctionatorHEntry" .. line]

		if dataOffset <= #sortedHistoryItemList and sortedHistoryItemList[dataOffset] then
			local isSelected = (sortedHistoryItemList[dataOffset] == itemName)
			rowFrame:SetButtonState(isSelected and "PUSHED" or "NORMAL", isSelected)
		end
	end
end

-----------------------------------------
-- Search-box autocomplete
-----------------------------------------

-- Suggests (and auto-highlights the suffix of) a matching item name from
-- shopping lists first, then from the recent-searches history.
function Atr_Item_Autocomplete(self)

	local typedText = self:GetText()
	local typedLength = strlen(typedText)

	local function TrySuggest(candidateName)
		if candidateName and typedText and strfind(strupper(candidateName), strupper(typedText), 1, 1) == 1 then
			self:SetText(candidateName)
			if self:IsInIMECompositionMode() then
				self:HighlightText(typedLength - strlen(arg1), -1)
			else
				self:HighlightText(typedLength, -1)
			end
			return true
		end
		return false
	end

	for _, list in ipairs(AUCTIONATOR_SHOPPING_LISTS) do
		for _, itemName in ipairs(list.items) do
			if TrySuggest(itemName) then
				return
			end
		end
	end

	for _, itemName in ipairs(sortedHistoryItemList) do
		if TrySuggest(itemName) then
			return
		end
	end
end

-----------------------------------------
-- Pane accessors (used by other modules)
-----------------------------------------

function Atr_GetCurrentPane()
	return currentPane
end

function Atr_SetUINeedsUpdate()
	currentPane.UINeedsUpdate = true
end

-----------------------------------------
-- Undercut / starting-price math
-----------------------------------------

-- Rounds `price` down to just under the nearest configured undercut
-- threshold for its price bracket.
function Atr_CalcUndercutPrice(price)

	if price > 5000000 then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._5000000) end
	if price > 1000000 then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._1000000) end
	if price > 200000  then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._200000) end
	if price > 50000   then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._50000) end
	if price > 10000   then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._10000) end
	if price > 2000    then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._2000) end
	if price > 500     then return roundPriceDown(price, AUCTIONATOR_SAVEDVARS._500) end
	if price > 0       then return math.floor(price - 1) end

	return 0
end

function Atr_CalcStartPrice(buyoutPrice)

	if AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT == 0 then
		return buyoutPrice -- zero means zero: no discount at all
	end

	local discountFactor = 1.00 - (AUCTIONATOR_SAVEDVARS.STARTING_DISCOUNT / 100)
	return Atr_CalcUndercutPrice(math.floor(buyoutPrice * discountFactor))
end

function Atr_AbbrevItemName(itemName)
	return string.gsub(itemName, "Scroll of Enchant", "SoE")
end

function Atr_IsMyToon(name)
	return name ~= nil and (AUCTIONATOR_TOONS[name] ~= nil or AUCTIONATOR_TOONS[string.lower(name)] ~= nil)
end

function Atr_Error_Display(errorMessage)
	if errorMessage then
		Atr_Error_Text:SetText(errorMessage)
		Atr_Error_Frame:Show()
	end
end

-----------------------------------------
-- Guild "who" polling entry point
-----------------------------------------

function Atr_PollWho(searchString)
	sendWhoZoneMessages = true
	quietWhoStartedAt = time()
	SetWhoToUI(1)
	zc.md(searchString)
	SendWho(searchString)
end

function Atr_FriendsFrame_OnEvent(self, eventName, ...)

	if eventName == "WHO_LIST_UPDATE" and quietWhoStartedAt > 0 and time() - quietWhoStartedAt < 10 then
		return -- suppress the default Friends-frame reaction to our own silent /who poll
	end

	if quietWhoStartedAt > 0 then
		SetWhoToUI(0)
	end

	quietWhoStartedAt = 0

	return original_FriendsFrame_OnEvent(self, eventName, ...)
end

-----------------------------------------
-- Price rounding helper
-----------------------------------------

-- Rounds `price` down to the next lowest multiple of `step`, and if the
-- result isn't at least step/2 lower, rounds down by an extra step/2.
-- Examples: (128790, 500) -> 128500; (128700, 500) -> 128000.
function roundPriceDown(price, step)

	if step == 0 then
		return price
	end

	local roundedPrice = math.floor((price - 1) / step) * step

	if (price - roundedPrice) < step / 2 then
		roundedPrice = roundedPrice - (step / 2)
	end

	if roundedPrice == price then
		roundedPrice = roundedPrice - 1
	end

	return roundedPrice
end

-----------------------------------------
-- "Tight" (compact) timestamp encoding, used for SavedVariables keys
-----------------------------------------

function ToTightHour(t)
	return floor((t - tightEpochTimeZero) / 3600)
end

function FromTightHour(tightHour)
	return (tightHour * 3600) + tightEpochTimeZero
end

function ToTightTime(t)
	return floor((t - tightEpochTimeZero) / 60)
end

function FromTightTime(tightTime)
	return (tightTime * 60) + tightEpochTimeZero
end
