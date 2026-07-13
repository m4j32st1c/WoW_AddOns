--[[
	AuctionatorBuy.lua

	Implements the "buy N stacks of this auction" workflow used by the
	Buy tab and the "buy matching auctions" button on the Sell tab.

	-----------------------------------------------------------------
	ASCENSION FIX
	-----------------------------------------------------------------
	The original implementation scanned every auction on the current
	results page and called PlaceAuctionBid() for ALL matching entries
	inside a single loop (i.e. within one game tick). This happens
	frequently right after a scan, because identical auctions are
	sorted next to each other on the same page.

	Retail WotLK tolerates this, but the Ascension auction house server
	does not: sending a second PlaceAuctionBid() request before the
	first one has been acknowledged by the server returns an internal
	error and leaves the clicked auctions stuck in a non-interactable
	state until the auction list is fully refreshed (e.g. by reloading
	the addon).

	Fix: matching auctions on a page are collected into a small queue
	and bought ONE AT A TIME, with a short delay between purchases
	(see BUY_QUEUE_DELAY_SECONDS). This never sends overlapping
	PlaceAuctionBid() requests.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

-----------------------------------------
-- Constants
-----------------------------------------

local BUY_STATE_IDLE               = 0
local BUY_STATE_QUERY_SENT         = 1
local BUY_STATE_PROCESSING_RESULTS = 2
local BUY_STATE_BUYING_QUEUE       = 3
local BUY_STATE_WAITING_FOR_QUERY  = 4

local AUCTION_QUERY_TIMEOUT_SECONDS = 10  -- give up if the AH doesn't respond in time
local BUY_QUEUE_DELAY_SECONDS       = 0.3 -- pause between successive purchases

-----------------------------------------
-- Module state
-----------------------------------------

local gBuyState = BUY_STATE_IDLE

-- Current purchase request
local gBuyoutPrice
local gItemName
local gStackSize
local gNumBought
local gNumWanted
local gMaxAvailable
local gCurrentPage
local gQuery
local gPass -- 1 = first full pass over every page, 2 = revisit pages for leftovers

-- Timers
local gWaitStartTime
local gNextQueuedPurchaseTime

-- Purchase queue for the current page (list of auction-list indices)
local gPendingPurchaseIndices = {}

-----------------------------------------
-- Public: state reset / opening the confirmation dialog
-----------------------------------------

function Atr_ClearBuyState()
	gBuyState = BUY_STATE_IDLE
	wipe(gPendingPurchaseIndices)
end

function Atr_Buy1_Onclick()

	if not Atr_ShowingCurrentAuctions() then
		return
	end

	local currentPane = Atr_GetCurrentPane()
	local scan = currentPane.activeScan
	local data = scan.sortedData[currentPane.currIndex]

	gQuery        = Atr_NewQuery()
	gNumWanted    = -1
	gNumBought    = 0
	gBuyoutPrice  = data.buyoutPrice
	gItemName     = scan.itemName
	gStackSize    = data.stackSize
	gMaxAvailable = data.count
	gPass         = 1

	Atr_Buy_Confirm_ItemName:SetText(gItemName .. " x" .. gStackSize)
	Atr_Buy_Confirm_Numstacks:SetNumber(1)
	Atr_Buy_Confirm_Max_Text:SetText(ZT("max") .. ": " .. gMaxAvailable)

	Atr_Buy_Part1:Show()
	Atr_Buy_Part2:Hide()
	Atr_Buy_Confirm_OKBut:SetText(ZT("Buy"))
	Atr_Buy_Confirm_OKBut:Disable()
	Atr_Buy_Confirm_Frame:Show()

	local startPage = (scan.searchWasExact and data.minpage) or 0
	Atr_Buy_QueueQuery(startPage)
end

-----------------------------------------
-- Querying the auction house
-----------------------------------------

function Atr_Buy_QueueQuery(page)
	gCurrentPage   = page
	gBuyState      = BUY_STATE_WAITING_FOR_QUERY
	gWaitStartTime = time()
	Atr_Buy_SendQuery()
end

function Atr_Buy_SendQuery()
	if CanSendAuctionQuery() then
		gBuyState = BUY_STATE_QUERY_SENT
		local searchTerm = zc.UTF8_Truncate(gItemName, 63) -- short queries reduce disconnects
		QueryAuctionItems(searchTerm, "", "", nil, 0, 0, gCurrentPage, nil, nil)
	end
end

-----------------------------------------
-- Frame update / idle handling
-----------------------------------------

function Atr_Buy_Idle()

	if gBuyState == BUY_STATE_WAITING_FOR_QUERY then

		if GetMoney() < gBuyoutPrice then
			Atr_Buy_Cancel(ZT("You do not have enough gold\n\nto make any more purchases."))
		elseif time() - gWaitStartTime > AUCTION_QUERY_TIMEOUT_SECONDS then
			Atr_Buy_Cancel(ZT("Auction House timed out"))
		else
			Atr_Buy_SendQuery()
		end

	elseif gBuyState == BUY_STATE_BUYING_QUEUE then
		Atr_Buy_ProcessPurchaseQueue()
	end
end

function Atr_Buy_OnAuctionUpdate()
	if gBuyState == BUY_STATE_QUERY_SENT then
		Atr_Buy_CheckForMatches()
	end
	return gBuyState ~= BUY_STATE_IDLE
end

-----------------------------------------
-- Matching auctions on the current page
-----------------------------------------

function Atr_Buy_CheckForMatches()

	gBuyState = BUY_STATE_PROCESSING_RESULTS

	if gQuery:CheckForDuplicatePage(gCurrentPage) then
		Atr_Buy_QueueQuery(gCurrentPage)
		return
	end

	local numMatches = Atr_Buy_CountMatches()

	if numMatches > 0 then
		Atr_Buy_Confirm_OKBut:Enable()

		if gNumWanted ~= -1 then
			Atr_Buy_Continue_Text:SetText(string.format(ZT("%d of %d bought so far"), gNumBought, gNumWanted))
			Atr_Buy_Part1:Hide()
			Atr_Buy_Part2:Show()
			Atr_Buy_Confirm_OKBut:SetText(ZT("Continue"))
		end
	else
		Atr_Buy_NextPageOrFinish()
	end
end

-- Returns how many auctions on the current page match the selected item.
function Atr_Buy_CountMatches()

	local numMatches = 0
	local index = 1

	while true do
		local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", index)
		if name == nil then
			break
		end

		if zc.StringSame(name, gItemName) and buyoutPrice == gBuyoutPrice and count == gStackSize then
			numMatches = numMatches + 1
		end

		index = index + 1
	end

	return numMatches
end

-- Builds the queue of auction-list indices to buy from the current page,
-- capped to the number of stacks still needed.
local function BuildPurchaseQueue()

	wipe(gPendingPurchaseIndices)

	local index = 1
	local stillNeeded = gNumWanted - gNumBought

	while stillNeeded > 0 do
		local name, _, count, _, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", index)
		if name == nil then
			break
		end

		if zc.StringSame(name, gItemName) and buyoutPrice == gBuyoutPrice and count == gStackSize then
			table.insert(gPendingPurchaseIndices, index)
			stillNeeded = stillNeeded - 1
		end

		index = index + 1
	end
end

-- Buys ONE queued auction per call, waiting BUY_QUEUE_DELAY_SECONDS between
-- purchases so we never send overlapping PlaceAuctionBid() requests.
-- This is the core fix for the Ascension "internal error" bug.
function Atr_Buy_ProcessPurchaseQueue()

	if #gPendingPurchaseIndices == 0 then
		Atr_Buy_NextPageOrFinish()
		return
	end

	if gNextQueuedPurchaseTime and time() < gNextQueuedPurchaseTime then
		return -- still waiting out the stagger delay
	end

	local index = table.remove(gPendingPurchaseIndices, 1)

	PlaceAuctionBid("list", index, gBuyoutPrice)
	AuctionatorSubtractFromScan(gItemName, gStackSize, gBuyoutPrice, 1)

	gNumBought = gNumBought + 1
	gNextQueuedPurchaseTime = time() + BUY_QUEUE_DELAY_SECONDS
end

-----------------------------------------
-- Confirmation dialog
-----------------------------------------

function Atr_Buy_Confirm_Update()
	local numStacks = Atr_Buy_Confirm_Numstacks:GetNumber()
	Atr_Buy_Confirm_Text2:SetText(numStacks == 1 and ZT("stack for") or ZT("stacks for"))
	MoneyFrame_Update("Atr_Buy_Confirm_TotalPrice", gBuyoutPrice * numStacks)
end

function Atr_Buy_Confirm_OK()

	if gNumWanted == -1 then
		local numToBuy = Atr_Buy_Confirm_Numstacks:GetNumber()

		if numToBuy > gMaxAvailable then
			Atr_Error_Text:SetText(string.format(ZT("You can buy at most %d auctions"), gMaxAvailable))
			Atr_Error_Frame:Show()
			return
		end

		gNumWanted = numToBuy
	end

	BuildPurchaseQueue()

	if #gPendingPurchaseIndices > 0 then
		gBuyState = BUY_STATE_BUYING_QUEUE
		gNextQueuedPurchaseTime = nil
		Atr_Buy_Confirm_OKBut:Disable()
	else
		Atr_Buy_NextPageOrFinish()
	end
end

-----------------------------------------
-- Page / completion logic
-----------------------------------------

function Atr_Buy_NextPageOrFinish()

	if Atr_Buy_IsComplete() then
		Atr_Buy_Cancel()
		return
	end

	if Atr_Buy_IsFirstPassComplete() then
		gPass = 2
		Atr_Buy_QueueQuery(0)
	else
		Atr_Buy_QueueQuery(gCurrentPage + 1)
	end
end

function Atr_Buy_IsComplete()

	if gNumWanted ~= -1 and gNumWanted <= gNumBought then
		return true
	end

	return gQuery:IsLastPage(gCurrentPage) and gPass == 2
end

function Atr_Buy_IsFirstPassComplete()
	return gQuery:IsLastPage(gCurrentPage) and gPass == 1
end

function Atr_Buy_Cancel(errorMessage)
	gBuyState = BUY_STATE_IDLE
	wipe(gPendingPurchaseIndices)
	Atr_Buy_Confirm_Frame:Hide()
	Atr_Error_Display(errorMessage)
end
