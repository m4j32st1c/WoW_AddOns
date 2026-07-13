--[[
	AuctionatorConflicts.lua

	Some other addons react to AUCTION_ITEM_LIST_UPDATE by re-scanning
	the auction list, which is expensive and unnecessary while
	Auctionator itself is driving that update. This module patches those
	addons' event handlers so they skip their own work while an
	Auctionator tab is active and a full scan (>50 results) is not in
	progress.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

local MAX_ROWS_BEFORE_FULL_SCAN = 50 -- results above this size are treated as a full scan, not our search

local originalRecipeKnownEventScan
local originalLootLinkOnEvent
local originalWowEconScanAH

-- Returns true if the caller should skip its own AUCTION_ITEM_LIST_UPDATE handling.
local function ShouldSkipAuctionUpdate()
	if not Atr_IsTabSelected() then
		return false
	end
	return GetNumAuctionItems("list") <= MAX_ROWS_BEFORE_FULL_SCAN
end

local function PatchedRecipeKnownEventScan(self, eventName, arg1)
	if eventName == "AUCTION_ITEM_LIST_UPDATE" and ShouldSkipAuctionUpdate() then
		return
	end
	originalRecipeKnownEventScan(self, eventName, arg1)
end

local function PatchedLootLinkOnEvent()
	if event == "AUCTION_ITEM_LIST_UPDATE" and ShouldSkipAuctionUpdate() then
		return
	end
	originalLootLinkOnEvent()
end

local function PatchedWowEconScanAH()
	if ShouldSkipAuctionUpdate() then
		return
	end
	originalWowEconScanAH()
end

-- Called once per loaded addon (see Atr_OnAddonLoaded) to check whether
-- it's one of the known conflicting addons and patch it if so.
function Atr_Check_For_Conflicts(loadedAddonName)

	if zc.StringSame(loadedAddonName, "recipeknown") and RecipeKnown_EventScan then
		originalRecipeKnownEventScan = RecipeKnown_EventScan
		RecipeKnown_EventScan = PatchedRecipeKnownEventScan
		zc.msg_yellow("Auctionator is patching RecipeKnown to prevent a known conflict.")
	end

	if zc.StringContains(loadedAddonName, "lootlink") and LootLink_OnEvent then
		originalLootLinkOnEvent = LootLink_OnEvent
		LootLink_OnEvent = PatchedLootLinkOnEvent
		zc.msg_yellow("Auctionator is patching LootLink to prevent a known conflict.")
	end

	if zc.StringContains(loadedAddonName, "wowecon") and WOWEcon_Scan_AH then
		originalWowEconScanAH = WOWEcon_Scan_AH
		WOWEcon_Scan_AH = PatchedWowEconScanAH
		zc.msg_yellow("Auctionator is patching WowEcon to prevent a known conflict.")
	end
end
