--[[
	AuctionatorScan.lua

	Two related but distinct concepts live here:

	  AtrScan   - the condensed auction data for ONE item (used to show
	              "current auctions" for that item).
	  AtrSearch - a single search session, which may match one exact
	              item (AtrScan) or many items (a browse/category search).

	Also contains the "Full Scan" feature, which scans the entire
	auction house once to build a rough price database (Atr_ScanDB),
	independent of any specific AtrSearch/AtrScan.

	NOTE ON A FIXED BUG: Atr_ClearBrowseListings() used to busy-wait in a
	tight loop for up to 5 seconds waiting for CanSendAuctionQuery() to
	become true, which could freeze the game client. It now makes a
	single best-effort attempt instead of blocking.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

-- Search / scan processing states (also referenced from Auctionator.lua,
-- AuctionatorPane.lua and AuctionatorShop.lua).
KM_NULL_STATE  = 0
KM_PREQUERY    = 1
KM_INQUERY     = 2
KM_POSTQUERY   = 3
KM_ANALYZING   = 4
KM_SETTINGSORT = 5

local ATR_SORTBY_NAME_ASC   = 0
local ATR_SORTBY_NAME_DESC  = 1
local ATR_SORTBY_PRICE_ASC  = 2
local ATR_SORTBY_PRICE_DESC = 3

local BIG_NUMBER = 999999999999 -- sentinel for "no price recorded yet"
local MAX_ROWS_PER_QUERY = 50   -- the AH server returns at most 50 rows per page
local MAX_RESULTS_BEFORE_THROTTLE = 5000 -- refuse overly broad searches to protect the server

local allScans = {} -- itemName (lowercase) -> AtrScan, cached across the whole session

-----------------------------------------
-- AtrScan: condensed auction data for a single item
-----------------------------------------

AtrScan = {}
AtrScan.__index = AtrScan

function Atr_FindScanAndInit(itemName)
	return Atr_FindScan(itemName, true)
end

-- Returns the cached AtrScan for `itemName` (case-insensitive), creating
-- it if necessary. If `reinit` is true, an existing scan is reset first.
function Atr_FindScan(itemName, reinit)

	if itemName == nil or itemName == "" then
		itemName = "nil"
	end

	local key = string.lower(itemName)

	if allScans[key] == nil then
		local scan = setmetatable({}, AtrScan)
		scan:Init(itemName)
		allScans[key] = scan
	elseif reinit then
		allScans[key]:Init(itemName)
	end

	return allScans[key]
end

function Atr_ClearScanCache()
	for key in pairs(allScans) do
		if key ~= "nil" then
			allScans[key] = nil
		end
	end
end

function AtrScan:Init(itemName)

	self.itemName          = itemName
	self.itemLink           = nil
	self.scanData           = {}
	self.sortedData         = {}
	self.whenScanned        = 0
	self.lowPrices          = { BIG_NUMBER, BIG_NUMBER, BIG_NUMBER }
	self.absoluteBest       = nil
	self.itemClass          = 0
	self.itemSubclass       = 0
	self.yourBestPrice      = nil
	self.yourWorstPrice     = nil
	self.numYourSingletons  = 0
	self.itemTextColor      = { 1.0, 1.0, 1.0 }
	self.searchWasExact     = false

	self:UpdateItemLink(Atr_GetItemLink(itemName))
end

function AtrScan:UpdateItemLink(itemLink)

	self.itemLink = itemLink

	if itemLink then
		Atr_AddToItemLinkCache(self.itemName, itemLink)

		local _, _, quality, _, _, itemType, itemSubType = GetItemInfo(itemLink)
		self.itemQuality   = quality
		self.itemClass     = Atr_ItemType2AuctionClass(itemType)
		self.itemSubclass  = Atr_SubType2AuctionSubclass(self.itemClass, itemSubType)
		self.itemTextColor = ITEM_QUALITY_COLORS[quality]
	end
end

-- Records one auction-list row (or `numAuctions` identical rows).
function AtrScan:AddScanItem(name, stackSize, buyoutPrice, owner, numAuctions, pageNum)

	numAuctions = numAuctions or 1

	for i = 1, numAuctions do
		table.insert(self.scanData, {
			stackSize   = stackSize,
			buyoutPrice = buyoutPrice,
			owner       = owner,
			pageNum     = pageNum,
		})

		Atr_AddToLowPrices(self.lowPrices, math.floor(buyoutPrice / stackSize))
	end
end

-- Adds a single external price data point (Wowecon, GoingPrice, etc.) to
-- the scan, tagged by `owner` so CondenseAndSort can distinguish it from
-- real player-posted auctions.
function AtrScan:AddExternalPricePoint(price, owner, volume)

	if price and price > 0 then
		table.insert(self.scanData, { stackSize = 1, buyoutPrice = price, owner = owner, volume = volume })
	end
end

-- Pulls in price suggestions from third-party price-history addons, if present.
function AtrScan:AddExternalDataToScan()

	if self.itemLink == nil then
		return
	end

	if Wowecon and Wowecon.API then
		local priceG, volG = Wowecon.API.GetAuctionPrice_ByLink(self.itemLink, Wowecon.API.GLOBAL_PRICE)
		local priceS, volS = Wowecon.API.GetAuctionPrice_ByLink(self.itemLink, Wowecon.API.SERVER_PRICE)
		self:AddExternalPricePoint(priceG, "__wowEconG", volG)
		self:AddExternalPricePoint(priceS, "__wowEconS", volS)
	end

	local itemID = tonumber(zc.ItemIDfromLink(self.itemLink))

	if GoingPrice_Wowhead_Data and GoingPrice_Wowhead_Data[itemID] and GoingPrice_Wowhead_SV._index then
		local index = GoingPrice_Wowhead_SV._index["Buyout price"]
		if index ~= nil then
			self:AddExternalPricePoint(GoingPrice_Wowhead_Data[itemID][index], "__wowHead")
		end
	end

	if GoingPrice_Allakhazam_Data and GoingPrice_Allakhazam_Data[itemID] and GoingPrice_Allakhazam_SV._index then
		local index = GoingPrice_Allakhazam_SV._index["Median"]
		if index ~= nil then
			self:AddExternalPricePoint(GoingPrice_Allakhazam_Data[itemID][index], "__allakhazam")
		end
	end

	local recentPrice = Atr_Process_Historydata()
	if recentPrice ~= nil then
		self:AddExternalPricePoint(recentPrice, "__atrLast")
	end
end

-- Removes one matching entry (used after a successful purchase).
function AtrScan:SubtractScanItem(name, stackSize, buyoutPrice)
	for i, entry in ipairs(self.scanData) do
		if entry.stackSize == stackSize and entry.buyoutPrice == buyoutPrice then
			table.remove(self.scanData, i)
			return
		end
	end
end

local function SortByItemPrice(a, b)
	return a.itemPrice < b.itemPrice
end

-- Condenses raw scanData rows into one entry per unique
-- (stackSize, buyoutPrice, owner-type) combination, then sorts by price.
function AtrScan:CondenseAndSort()

	self.sortedData = {}
	local condensed = {}

	for _, row in ipairs(self.scanData) do

		local ownerCode = "x" -- someone else's auction
		local dataType = "n"  -- "n" = a normal (real) auction

		if row.owner == UnitName("player") then
			ownerCode = "y"
		elseif row.owner == "__wowEconG"   then dataType = "eg"
		elseif row.owner == "__wowEconS"   then dataType = "es"
		elseif row.owner == "__wowHead"    then dataType = "h"
		elseif row.owner == "__allakhazam" then dataType = "k"
		elseif row.owner == "__atrLast"    then dataType = "a"
		end

		local key = "_" .. row.stackSize .. "_" .. row.buyoutPrice .. "_" .. ownerCode .. dataType

		if condensed[key] then
			condensed[key].count = condensed[key].count + 1
			condensed[key].minPage = zc.Min(condensed[key].minPage, row.pageNum)
			condensed[key].maxPage = zc.Max(condensed[key].maxPage, row.pageNum)
		else
			local entry = {
				stackSize   = row.stackSize,
				buyoutPrice = row.buyoutPrice,
				itemPrice   = row.buyoutPrice / row.stackSize,
				minPage     = row.pageNum,
				maxPage     = row.pageNum,
				count       = 1,
				type        = dataType,
				yours       = (ownerCode == "y"),
			}

			if ownerCode ~= "x" and ownerCode ~= "y" then
				entry.altName = ownerCode
			end

			if row.volume then
				entry.volume = row.volume
			end

			condensed[key] = entry
		end
	end

	local i = 1
	for _, entry in pairs(condensed) do
		self.sortedData[i] = entry
		i = i + 1
	end

	table.sort(self.sortedData, SortByItemPrice)

	self:AnalyzeSortedData()
end

-- Computes derived summary info (best price, your own price range, etc.)
-- from the already-sorted data.
function AtrScan:AnalyzeSortedData()

	self.absoluteBest         = nil
	self.bestPrices           = {} -- one entry per stack size: the cheapest auction of that size
	self.numMatches           = 0
	self.numMatchesWithBuyout = 0
	self.hasStack             = false
	self.yourBestPrice        = nil
	self.yourWorstPrice       = nil
	self.numYourSingletons    = 0

	for _, entry in ipairs(self.sortedData) do

		if entry.type == "n" then

			self.numMatches = self.numMatches + 1

			if entry.itemPrice > 0 then

				self.numMatchesWithBuyout = self.numMatchesWithBuyout + 1

				if self.bestPrices[entry.stackSize] == nil or self.bestPrices[entry.stackSize].itemPrice >= entry.itemPrice then
					self.bestPrices[entry.stackSize] = entry
				end

				if self.absoluteBest == nil or self.absoluteBest.itemPrice > entry.itemPrice then
					self.absoluteBest = entry
				end

				if entry.yours then
					if self.yourBestPrice == nil or self.yourBestPrice > entry.itemPrice then
						self.yourBestPrice = entry.itemPrice
					end
					if self.yourWorstPrice == nil or self.yourWorstPrice < entry.itemPrice then
						self.yourWorstPrice = entry.itemPrice
					end
					if entry.stackSize == 1 then
						self.numYourSingletons = self.numYourSingletons + entry.count
					end
				end
			end

			if entry.stackSize > 1 then
				self.hasStack = true
			end
		end
	end
end

function AtrScan:FindInSortedData(stackSize, buyoutPrice)
	for i, entry in ipairs(self.sortedData) do
		if entry.stackSize == stackSize and entry.buyoutPrice == buyoutPrice and entry.yours then
			return i
		end
	end
	return 0
end

function AtrScan:FindMatchByStackSize(stackSize)

	local reference = self.bestPrices[stackSize] or self.absoluteBest

	for i, entry in ipairs(self.sortedData) do
		if reference and entry.itemPrice == reference.itemPrice
			and entry.stackSize == reference.stackSize
			and entry.yours == reference.yours then
			return i
		end
	end

	return nil
end

function AtrScan:FindMatchByYours()
	for i, entry in ipairs(self.sortedData) do
		if entry.yours then
			return i
		end
	end
	return nil
end

function AtrScan:FindCheapest()
	for i, entry in ipairs(self.sortedData) do
		if entry.itemPrice > 0 then
			return i
		end
	end
	return nil
end

function AtrScan:GetNumAvailable()
	local total = 0
	for _, entry in ipairs(self.sortedData) do
		total = total + (entry.count * entry.stackSize)
	end
	return total
end

function AtrScan:IsNil()
	return self.itemName == nil or self.itemName == "" or self.itemName == "nil"
end

-----------------------------------------
-- AtrSearch: one search session (may span multiple pages/items)
-----------------------------------------

AtrSearch = {}
AtrSearch.__index = AtrSearch

function Atr_NewSearch(searchText, exact, rescanThreshold, callback)
	local search = setmetatable({}, AtrSearch)
	search:Init(searchText, exact, rescanThreshold, callback)
	return search
end

function AtrSearch:Init(searchText, exact, rescanThreshold, callback)

	searchText = searchText or ""
	self.originalSearchText = searchText

	-- A quoted search ("Foo") is always treated as an exact match.
	if not exact and zc.StringStartsWith(searchText, "\"") and zc.StringEndsWith(searchText, "\"") then
		searchText = string.sub(searchText, 2, searchText:len() - 1)
		exact = true
	end

	self.searchText      = searchText
	self.exact           = exact
	self.processingState = KM_NULL_STATE
	self.currentPage     = -1
	self.items           = {}
	self.query           = Atr_NewQuery()
	self.sortedScans     = nil
	self.sortHow         = ATR_SORTBY_PRICE_ASC
	self.callback        = callback

	if exact then

		if rescanThreshold and rescanThreshold > 0 then
			local cachedScan = Atr_FindScan(searchText)
			if cachedScan and (time() - cachedScan.whenScanned) <= rescanThreshold then
				self.items[searchText] = cachedScan
			end
		end

		if not self.items[searchText] then
			self.items[searchText] = Atr_FindScanAndInit(searchText)
		end
	end
end

function AtrSearch:NumScans()
	if self.sortedScans then
		return #self.sortedScans
	end
	local count = 0
	for _ in pairs(self.items) do
		count = count + 1
	end
	return count
end

function AtrSearch:NumSortedScans()
	return self.sortedScans and #self.sortedScans or 0
end

function AtrSearch:GetFirstScan()
	if self.sortedScans then
		return self.sortedScans[1]
	end
	for _, scan in pairs(self.items) do
		return scan
	end
	return nil
end

function AtrSearch:Start()

	if self.searchText == "" then
		return
	end

	if Atr_IsCompoundSearch(self.searchText) then
		local _, itemClass = Atr_ParseCompoundSearch(self.searchText)
		if itemClass == 0 then
			Atr_Error_Display(ZT("The first part of this compound\n\nsearch is not a valid category."))
			return
		end
		self.sortHow = ATR_SORTBY_PRICE_DESC
	end

	self.processingState = KM_SETTINGSORT

	SortAuctionClearSort("list")

	BrowseName:SetText(self.searchText) -- kept in sync in case the user switches to the Browse tab

	self.currentPage     = 0
	self.processingState = KM_PREQUERY

	self:Continue()
end

function AtrSearch:Abort()
	if self.processingState == KM_NULL_STATE then
		return
	end
	self.processingState = KM_NULL_STATE
	self:Init()
end

-- Wrapper around AtrQuery:CheckForDuplicatePage() that also rewinds the
-- page counter so the same page gets requeried.
function AtrSearch:CheckForDuplicatePage()

	local isDuplicate = self.query:CheckForDuplicatePage(self.currentPage)

	if isDuplicate then
		self.currentPage = self.currentPage - 1
		self.processingState = KM_PREQUERY
	end

	return isDuplicate
end

-- Processes one page of query results. Returns true once the whole
-- search is complete (no more pages to fetch).
function AtrSearch:AnalyzeResultsPage()

	self.processingState = KM_ANALYZING

	if self.query.numDuplicatePages > 10 then
		return true -- safety net: avoid ever looping forever
	end

	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")

	if self.currentPage == 1 and totalAuctions > MAX_RESULTS_BEFORE_THROTTLE then
		Atr_Error_Display(ZT("Too many results\n\nPlease narrow your search"))
		return true
	end

	if totalAuctions >= MAX_ROWS_PER_QUERY then
		Atr_SetMessage(string.format(ZT("Scanning auctions: page %d"), self.currentPage))
	end

	if numBatchAuctions > 0 then
		for i = 1, numBatchAuctions do

			local name, _, count, _, _, _, _, _, buyoutPrice, _, _, owner = GetAuctionItemInfo("list", i)
			local isExactMatch = zc.StringSame(name, self.searchText)

			if isExactMatch or not self.exact then

				if self.items[name] == nil then
					self.items[name] = Atr_FindScanAndInit(name)
				end

				local scan = self.items[name]
				local pageIndex = tonumber(self.currentPage) - 1

				scan:AddScanItem(name, count, buyoutPrice, owner, 1, pageIndex)

				if scan.itemLink == nil or self.itemClass == nil then
					scan:UpdateItemLink(GetAuctionItemLink("list", i))
				end

				if self.callback then
					self.callback(i, numBatchAuctions, count, buyoutPrice, owner)
				end
			end
		end
	end

	local isDone = numBatchAuctions < MAX_ROWS_PER_QUERY

	if not isDone then
		self.processingState = KM_PREQUERY
	end

	return isDone
end

function AtrSearch:Continue()

	if not CanSendAuctionQuery() then
		return
	end

	self.processingState = KM_INQUERY

	local queryString = self.searchText
	local itemClass, itemSubclass, minLevel, maxLevel = 0, 0, nil, nil

	if self.exact then
		local scan = self:GetFirstScan()
		itemClass    = scan.itemClass
		itemSubclass = scan.itemSubclass
	end

	if Atr_IsCompoundSearch(queryString) then
		queryString, itemClass, itemSubclass, minLevel, maxLevel = Atr_ParseCompoundSearch(queryString)
	end

	queryString = zc.UTF8_Truncate(queryString, 63) -- shorter queries reduce disconnects

	QueryAuctionItems(queryString, minLevel, maxLevel, nil, itemClass, itemSubclass, self.currentPage, nil, nil)

	self.querySentWhen   = Atr_ptime
	self.processingState = KM_POSTQUERY
	self.currentPage     = self.currentPage + 1
end

local sortByField -- set just before table.sort so the comparator can read it

local function CompareScans(a, b)

	if sortByField == ATR_SORTBY_NAME_ASC  then return string.lower(a.itemName) < string.lower(b.itemName) end
	if sortByField == ATR_SORTBY_NAME_DESC then return string.lower(a.itemName) > string.lower(b.itemName) end

	local priceA = a.absoluteBest and zc.round(a.absoluteBest.buyoutPrice / a.absoluteBest.stackSize) or 0
	local priceB = b.absoluteBest and zc.round(b.absoluteBest.buyoutPrice / b.absoluteBest.stackSize) or 0

	if sortByField == ATR_SORTBY_PRICE_ASC  then return priceA < priceB end
	if sortByField == ATR_SORTBY_PRICE_DESC then return priceA > priceB end
end

local function SortScans(scans, sortHow)
	sortByField = sortHow
	table.sort(scans, CompareScans)
end

-- Finalizes the search: condenses every matched item's scan data,
-- updates the full-scan price database for exact single-item hits, and
-- builds the sorted results list.
function AtrSearch:Finish()

	local finishTime = time()

	self.processingState = KM_NULL_STATE
	self.currentPage     = -1
	self.querySentWhen   = nil
	self.sortedScans     = {}

	local wasExactSearch = (self:NumScans() == 1)

	local i = 1
	for _, scan in pairs(self.items) do

		self.sortedScans[i] = scan
		i = i + 1

		scan.whenScanned    = finishTime
		scan.searchWasExact = wasExactSearch

		scan:CondenseAndSort()

		local newPrice = Atr_CalcNewDBprice(scan.itemName, scan.lowPrices)
		if newPrice > 0 and scan.itemQuality + 1 >= AUCTIONATOR_SCAN_MINLEVEL then
			Atr_ScanDB[scan.itemName] = newPrice
		end
	end

	Atr_ClearBrowseListings()

	SortScans(self.sortedScans, self.sortHow)
end

function AtrSearch:ClickPriceCol()
	self.sortHow = (self.sortHow == ATR_SORTBY_PRICE_ASC) and ATR_SORTBY_PRICE_DESC or ATR_SORTBY_PRICE_ASC
	SortScans(self.sortedScans, self.sortHow)
end

function AtrSearch:ClickNameCol()
	self.sortHow = (self.sortHow == ATR_SORTBY_NAME_ASC) and ATR_SORTBY_NAME_DESC or ATR_SORTBY_NAME_ASC
	SortScans(self.sortedScans, self.sortHow)
end

function AtrSearch:UpdateArrows()

	Atr_Col1_Heading_ButtonArrow:Hide()
	Atr_Col3_Heading_ButtonArrow:Hide()

	if self.sortHow == ATR_SORTBY_PRICE_ASC then
		Atr_Col1_Heading_ButtonArrow:Show()
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0)
	elseif self.sortHow == ATR_SORTBY_PRICE_DESC then
		Atr_Col1_Heading_ButtonArrow:Show()
		Atr_Col1_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0)
	elseif self.sortHow == ATR_SORTBY_NAME_ASC then
		Atr_Col3_Heading_ButtonArrow:Show()
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 0, 1.0)
	elseif self.sortHow == ATR_SORTBY_NAME_DESC then
		Atr_Col3_Heading_ButtonArrow:Show()
		Atr_Col3_Heading_ButtonArrow:SetTexCoord(0, 0.5625, 1.0, 0)
	end
end

-----------------------------------------
-- Compound searches, e.g. "Cloth/Head/60/80"
-----------------------------------------

function Atr_IsCompoundSearch(searchString)
	return zc.StringContains(searchString, ">") or zc.StringContains(searchString, "/")
end

function Atr_ParseCompoundSearch(searchString)

	local delimiter = zc.StringContains(searchString, ">") and ">" or "/"
	local parts = { strsplit(delimiter, searchString) }

	local queryString = ""
	local itemClass, itemSubclass = 0, 0
	local minLevel, maxLevel

	local previousWasItemClass = false

	for _, part in ipairs(parts) do

		local handled = false

		if tonumber(part) then
			if minLevel == nil then
				minLevel = tonumber(part)
			elseif maxLevel == nil then
				maxLevel = tonumber(part)
			end
			handled = true
			previousWasItemClass = false
		end

		if not handled and previousWasItemClass and itemSubclass == 0 then
			itemSubclass = Atr_SubType2AuctionSubclass(itemClass, part)
			if itemSubclass > 0 then
				handled = true
				previousWasItemClass = false
			end
		end

		if not handled and itemClass == 0 then
			itemClass = Atr_ItemType2AuctionClass(part)
			if itemClass > 0 then
				previousWasItemClass = true
				handled = true
			end
		end

		if not handled then
			queryString = part
		end
	end

	return queryString, itemClass, itemSubclass, minLevel, maxLevel
end

-----------------------------------------
-- Low-price tracking (top-2 cheapest seen, used for the scan DB)
-----------------------------------------

-- Updates `lowPrices` (a { best, secondBest, _ } array) with `itemPrice`
-- if it's among the two cheapest seen so far.
function Atr_AddToLowPrices(lowPrices, itemPrice)

	if itemPrice <= 0 then
		return false
	end

	if itemPrice < lowPrices[1] then
		if lowPrices[1] < lowPrices[2] then
			lowPrices[2] = lowPrices[1]
		end
		lowPrices[1] = itemPrice
		return true
	elseif itemPrice < lowPrices[2] then
		lowPrices[2] = itemPrice
		return true
	end

	return false
end

function Atr_CalcNewDBprice(name, lowPrices)
	if lowPrices[1] ~= BIG_NUMBER then
		return lowPrices[1]
	end
	return 0
end

-- Clears the browse tab's listing cache with a throwaway, near-impossible
-- query. Best-effort: does nothing if the AH can't accept a query right
-- now (previously this busy-waited for up to 5 seconds, which could
-- freeze the client).
function Atr_ClearBrowseListings()
	if CanSendAuctionQuery() then
		QueryAuctionItems("xyzzy", 43, 43, 0, 7, 0)
	end
end

-----------------------------------------
-- Full Scan (whole-AH price database)
-----------------------------------------

ATR_FS_NULL        = 0
ATR_FS_STARTED     = 1
ATR_FS_ANALYZING   = 2
ATR_FS_CLEANING_UP = 3

gAtr_FullScanState = ATR_FS_NULL

local numItemsAdded, numItemsUpdated

function Atr_GetDBsize()
	local count = 0
	for _ in pairs(Atr_ScanDB) do
		count = count + 1
	end
	return count
end

function Atr_FullScanStart()

	local _, canQueryAll = CanSendAuctionQuery()

	if not canQueryAll then
		return
	end

	Atr_FullScanStatus:SetText(ZT("Scanning") .. "...")
	Atr_FullScanStartButton:Disable()
	Atr_FullScanDone:Disable()

	gAtr_FullScanState = ATR_FS_STARTED

	SortAuctionClearSort("list")

	numItemsAdded = 0
	numItemsUpdated = 0

	QueryAuctionItems("", nil, nil, 0, 0, 0, 0, 0, 0, true)
end

local fullScanDetails = {}

function Atr_FullScanMoreDetails()

	zc.msg(" ")
	zc.msg_atr(ZT("Auctions scanned") .. ": |cffffffff", fullScanDetails.numBatchAuctions, " |r(" .. fullScanDetails.totalItems, "items)")
	zc.msg_atr("|cffa335ee   " .. ZT("Epic items") .. ": |r",     fullScanDetails.numEachQuality[5])
	zc.msg_atr("|cff0070dd   " .. ZT("Rare items") .. ": |r",     fullScanDetails.numEachQuality[4])
	zc.msg_atr("|cff1eff00   " .. ZT("Uncommon items") .. ": |r", fullScanDetails.numEachQuality[3])
	zc.msg_atr("|cffffffff   " .. ZT("Common items") .. ": |r",   fullScanDetails.numEachQuality[2])
	zc.msg_atr("|cff9d9d9d   " .. ZT("Poor items") .. ": |r",     fullScanDetails.numEachQuality[1])

	local removedLabels = { [2] = "Common items", [3] = "Uncommon items", [4] = "Rare items" }
	for quality = 2, 4 do
		if fullScanDetails.numRemoved[quality] > 0 then
			zc.msg_atr(ZT(removedLabels[quality]) .. " " .. ZT("removed from database") .. ": |cffffffff", fullScanDetails.numRemoved[quality])
		end
	end

	zc.msg_atr(ZT("Items added to database") .. ": |cffffffff", fullScanDetails.numAdded)
	zc.msg_atr(ZT("Items updated in database") .. ": |cffffffff", fullScanDetails.numUpdated)
	zc.msg_atr(ZT("Items ignored") .. ": |cffffffff", fullScanDetails.totalItems - (fullScanDetails.numAdded + fullScanDetails.numUpdated))
	zc.msg(" ")
end

function Atr_FullScanAnalyze()

	gAtr_FullScanState = ATR_FS_ANALYZING
	Atr_FullScanStatus:SetText(ZT("Processing"))

	local numBatchAuctions, totalAuctions = GetNumAuctionItems("list")
	zc.md("FULL SCAN:" .. numBatchAuctions .. " out of  " .. totalAuctions)

	local lowPricesByName = {}
	local qualityByName = {}

	if numBatchAuctions > 0 then
		for i = 1, numBatchAuctions do

			local name, _, count, quality, _, _, _, _, buyoutPrice = GetAuctionItemInfo("list", i)
			qualityByName[name] = quality

			if name ~= nil and buyoutPrice ~= nil then
				local itemPrice = math.floor(buyoutPrice / count)
				if itemPrice > 0 then
					lowPricesByName[name] = lowPricesByName[name] or { BIG_NUMBER, BIG_NUMBER, BIG_NUMBER }
					Atr_AddToLowPrices(lowPricesByName[name], itemPrice)
				end
			end

			if i % 100 == 0 then
				Atr_FullScanStatus:SetText(ZT("Processing") .. " (" .. i .. ")")
			end
		end
	end

	local numEachQuality = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
	local totalItems = 0
	local numRemoved = { 0, 0, 0, 0, 0, 0, 0, 0 }

	for name, prices in pairs(lowPricesByName) do

		local newPrice = Atr_CalcNewDBprice(name, prices)

		if newPrice > 0 then

			local qualityIndex = qualityByName[name] + 1

			numEachQuality[qualityIndex] = numEachQuality[qualityIndex] + 1
			totalItems = totalItems + 1

			if qualityIndex < AUCTIONATOR_SCAN_MINLEVEL and Atr_ScanDB[name] then
				numRemoved[qualityIndex] = numRemoved[qualityIndex] + 1
				Atr_ScanDB[name] = nil
				zc.md("removed: |cffbbbbbb", name, "   (" .. qualityIndex .. ")")
			end

			if qualityIndex >= AUCTIONATOR_SCAN_MINLEVEL then
				if Atr_ScanDB[name] == nil then
					numItemsAdded = numItemsAdded + 1
				else
					numItemsUpdated = numItemsUpdated + 1
				end
				Atr_ScanDB[name] = newPrice
			end
		end
	end

	fullScanDetails.numBatchAuctions = numBatchAuctions
	fullScanDetails.totalItems       = totalItems
	fullScanDetails.numEachQuality   = numEachQuality
	fullScanDetails.numRemoved       = numRemoved
	fullScanDetails.numAdded         = numItemsAdded
	fullScanDetails.numUpdated       = numItemsUpdated

	if Atr_PrintBargains and Atr_CheckForBargain and numBatchAuctions > 0 then
		for i = 1, numBatchAuctions do
			Atr_CheckForBargain(i)
		end
		Atr_PrintBargains()
	end

	gAtr_FullScanState = ATR_FS_CLEANING_UP

	Atr_FullScanMoreDetails()

	Atr_FullScanStatus:SetText(ZT("Cleaning up"))
	Atr_FullScanStartButton:Enable()
	Atr_FullScanDone:Enable()
	Atr_FullScanStatus:SetText("")

	Atr_FSR_scanned_count:SetText(numBatchAuctions)
	Atr_FSR_added_count:SetText(numItemsAdded)
	Atr_FSR_updated_count:SetText(numItemsUpdated)
	Atr_FSR_ignored_count:SetText(totalItems - (numItemsAdded + numItemsUpdated))

	Atr_FullScanHTML:Hide()
	Atr_FullScanResults:Show()
	Atr_FullScanResults:SetBackdropColor(0.3, 0.3, 0.4)

	AUCTIONATOR_LAST_SCAN_TIME = time()

	Atr_UpdateFullScanFrame()
	Atr_ClearBrowseListings()

	collectgarbage("collect")
end

function Atr_ShowFullScanFrame()

	Atr_FullScanHTML:Show()
	Atr_FullScanResults:Hide()

	Atr_FullScanFrame:Show()
	Atr_FullScanFrame:SetBackdropColor(0, 0, 0, 100)

	Atr_UpdateFullScanFrame()
	Atr_FullScanStatus:SetText("")

	local explanationHTML = "<html><body>"
		.. "<p>"
		.. ZT("Scanning is entirely optional.")
		.. "<br/><br/>"
		.. ZT("SCAN_EXPLANATION")
		.. "</p>"
		.. "</body></html>"

	Atr_FullScanHTML:SetText(explanationHTML)
	Atr_FullScanHTML:SetSpacing(3)
end

function Atr_UpdateFullScanFrame()

	Atr_FullScanDBsize:SetText(Atr_GetDBsize())

	if AUCTIONATOR_LAST_SCAN_TIME then
		Atr_FullScanDBwhen:SetText(date("%A, %B %d at %I:%M %p", AUCTIONATOR_LAST_SCAN_TIME))
	else
		Atr_FullScanDBwhen:SetText(ZT("Never"))
	end

	local _, canQueryAll = CanSendAuctionQuery()

	if canQueryAll then
		Atr_FullScanStatus:SetText("")
		Atr_FullScanStartButton:Enable()
		Atr_FullScanNext:SetText(ZT("Now"))
		return
	end

	Atr_FullScanStartButton:Disable()

	if not AUCTIONATOR_LAST_SCAN_TIME then
		Atr_FullScanNext:SetText(ZT("unknown"))
		return
	end

	local minutesRemaining = math.floor((15 * 60 - (time() - AUCTIONATOR_LAST_SCAN_TIME)) / 60)

	if minutesRemaining == 0 then
		Atr_FullScanNext:SetText(ZT("in less than a minute"))
	elseif minutesRemaining == 1 then
		Atr_FullScanNext:SetText(ZT("in about one minute"))
	elseif minutesRemaining > 0 then
		Atr_FullScanNext:SetText(string.format(ZT("in about %d minutes"), minutesRemaining))
	else
		Atr_FullScanNext:SetText(ZT("unknown"))
	end
end

function Atr_FullScanFrameIdle()

	if gAtr_FullScanState == ATR_FS_CLEANING_UP then

		Atr_FullScanStatus:SetText("Cleaning up")

		if GetNumAuctionItems("list") < 100 then
			Atr_FullScanStatus:SetText(ZT("Scan complete"))
			PlaySound("AuctionWindowClose")
			gAtr_FullScanState = ATR_FS_NULL
		end
	end

	if gAtr_FullScanState == ATR_FS_STARTED then

		local statusText = Atr_FullScanStatus:GetText()

		if statusText then
			if string.len(statusText) > 25 then
				Atr_FullScanStatus:SetText(ZT("Scanning") .. ".")
			else
				Atr_FullScanStatus:SetText(statusText .. ".")
			end
		end
	end
end
