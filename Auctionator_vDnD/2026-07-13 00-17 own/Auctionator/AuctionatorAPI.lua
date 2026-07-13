--[[
	AuctionatorAPI.lua

	Overrides the global GetSellValue/GetAuctionBuyout functions (a
	de-facto convention originally established by Tekkub) so that other
	addons can query Auctionator's price data through a common API.
]]

local originalGetSellValue     = GetSellValue
local originalGetAuctionBuyout = GetAuctionBuyout

-- Tekkub's API: vendor sell price for an item.
function GetSellValue(item)
	return Atr_GetSellValue(item)
end

-- Tekkub's API: auction house buyout price for an item.
function GetAuctionBuyout(item)
	return Atr_GetAuctionBuyout(item)
end

-- Same as GetSellValue, but guaranteed to be Auctionator's implementation
-- even if another addon has since overridden the global again.
function Atr_GetSellValue(item)

	local sellValue = select(11, GetItemInfo(item))
	if sellValue ~= nil then
		return sellValue
	end

	if originalGetSellValue then
		return originalGetSellValue(item)
	end

	return 0
end

-- Same as GetAuctionBuyout, but guaranteed to be Auctionator's implementation.
function Atr_GetAuctionBuyout(item)

	local price

	if type(item) == "string" then
		price = Atr_GetAuctionPrice(item)
	end

	if price == nil then
		local itemName = GetItemInfo(item)
		if itemName then
			price = Atr_GetAuctionPrice(itemName)
		end
	end

	if price then
		return price
	end

	if originalGetAuctionBuyout then
		return originalGetAuctionBuyout(item)
	end

	return nil
end

function Atr_GetDisenchantValue(item)

	local _, itemLink, itemRarity, itemLevel, _, itemType = GetItemInfo(item)

	if itemLink then
		return Atr_CalcDisenchantPrice(itemType, itemRarity, itemLevel)
	end

	return nil
end
