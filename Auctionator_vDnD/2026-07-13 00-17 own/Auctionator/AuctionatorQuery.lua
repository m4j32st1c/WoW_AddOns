--[[
	AuctionatorQuery.lua

	Tracks successive auction-list query results so callers can detect
	when the server returned the same page twice in a row (which can
	happen when a query is sent again before the client noticed the
	auction list didn't change).
]]

AtrQuery = {}
AtrQuery.__index = AtrQuery

function Atr_NewQuery()
	local query = setmetatable({}, AtrQuery)
	query.previousPage = nil
	query.numDuplicatePages = 0
	return query
end

-- Builds a compact identity string for one auction-list row, used to
-- compare whether two pages contain the same auctions.
function AtrQuery:BuildItemIDstr(name, count, minBid, buyoutPrice, bidAmount)
	if name == nil then
		return ""
	end
	return name .. "_" .. count .. "_" .. minBid .. "_" .. buyoutPrice .. "_" .. bidAmount
end

-- Returns true if the current auction-list page is identical to the
-- previous one seen by this query (a sign the server hasn't updated
-- yet). Also stores the current page for the next comparison.
function AtrQuery:CheckForDuplicatePage(pageNumber)

	local numBatchAuctions = GetNumAuctionItems("list")

	-- Same page number requested again with nothing new in between: not a duplicate.
	if self.previousPage and self.previousPage.pageNumber == pageNumber then
		return false
	end

	if numBatchAuctions == 0 then
		self.previousPage = { pageNumber = pageNumber, numOnPage = 0, items = {} }
		return false
	end

	local currentPage = { pageNumber = pageNumber, numOnPage = numBatchAuctions, items = {} }

	local allRowsIdentical = true
	local allRowsMatchPrevious = true

	for i = 1, numBatchAuctions do
		local name, _, count, _, _, _, minBid, _, buyoutPrice, bidAmount = GetAuctionItemInfo("list", i)

		currentPage.items[i] = self:BuildItemIDstr(name, count, minBid, buyoutPrice, bidAmount)

		if self.previousPage == nil or currentPage.items[i] ~= self.previousPage.items[i] then
			allRowsMatchPrevious = false
		end

		-- Guards against sellers who post 200 identical auctions: if every
		-- row on the page is the same item, row-by-row comparison alone
		-- can't reliably detect a duplicate page.
		if i > 1 and allRowsIdentical and currentPage.items[i] ~= currentPage.items[i - 1] then
			allRowsIdentical = false
		end
	end

	local isDuplicate = allRowsMatchPrevious
		and not allRowsIdentical
		and self.previousPage ~= nil
		and self.previousPage.numOnPage == currentPage.numOnPage

	if isDuplicate then
		self.numDuplicatePages = self.numDuplicatePages + 1
	else
		self.previousPage = currentPage
	end

	return isDuplicate
end

-- Returns true if `pageNumber` is (or is past) the final page of results.
function AtrQuery:IsLastPage(pageNumber)
	local _, totalAuctions = GetNumAuctionItems("list")
	return ((pageNumber + 1) * 50) >= totalAuctions
end
