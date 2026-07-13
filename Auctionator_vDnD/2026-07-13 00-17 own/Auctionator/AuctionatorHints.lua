--[[
	AuctionatorHints.lua

	Two responsibilities:
	  1. "Hints" - price suggestions shown when no current auction data
	     exists for an item (scan database, price history, third-party
	     price add-ons).
	  2. Tooltip augmentation - hooks GameTooltip to append auction /
	     vendor / disenchant price lines to item tooltips.

	Also contains the static disenchanting-yield tables used to estimate
	an item's disenchant value.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

-----------------------------------------
-- Price hints
-----------------------------------------

local function AppendHint(results, price, sourceText, volume)
	if price and price > 0 then
		table.insert(results, { price = price, text = sourceText, volume = volume })
	end
end

-- Gathers every available price suggestion for an item (scan DB, price
-- history, third-party price data) as a list of { price, text, volume }.
function Atr_BuildHints(itemName)

	local results = {}
	local itemLink = Atr_GetItemLink(itemName)

	if itemLink == nil and itemName == nil then
		return results
	end

	if itemName ~= nil and Atr_ScanDB[itemName] ~= nil then
		AppendHint(results, Atr_ScanDB[itemName], ZT("Auctionator scan data"))
	end

	local recentPrice = Atr_GetMostRecentSale(itemName)
	if recentPrice ~= nil then
		AppendHint(results, recentPrice, ZT("your most recent posting"))
	end

	if Wowecon and Wowecon.API then

		local globalPrice, globalVolume, serverPrice, serverVolume

		if itemLink then
			globalPrice, globalVolume = Wowecon.API.GetAuctionPrice_ByLink(itemLink, Wowecon.API.GLOBAL_PRICE)
			serverPrice, serverVolume = Wowecon.API.GetAuctionPrice_ByLink(itemLink, Wowecon.API.SERVER_PRICE)
		else
			globalPrice, globalVolume = Wowecon.API.GetAuctionPrice_ByName(itemName, Wowecon.API.GLOBAL_PRICE)
			serverPrice, serverVolume = Wowecon.API.GetAuctionPrice_ByName(itemName, Wowecon.API.SERVER_PRICE)
		end

		AppendHint(results, globalPrice, ZT("Wowecon global price"), globalVolume)
		AppendHint(results, serverPrice, ZT("Wowecon server price"), serverVolume)
	end

	if itemLink then

		local itemID = tonumber(zc.ItemIDfromLink(itemLink))

		if GoingPrice_Wowhead_Data and GoingPrice_Wowhead_Data[itemID] and GoingPrice_Wowhead_SV._index then
			local index = GoingPrice_Wowhead_SV._index["Buyout price"]
			if index ~= nil then
				AppendHint(results, GoingPrice_Wowhead_Data[itemID][index], "GoingPrice - Wowhead")
			end
		end

		if GoingPrice_Allakhazam_Data and GoingPrice_Allakhazam_Data[itemID] and GoingPrice_Allakhazam_SV._index then
			local index = GoingPrice_Allakhazam_SV._index["Median"]
			if index ~= nil then
				AppendHint(results, GoingPrice_Allakhazam_Data[itemID][index], "GoingPrice - Allakhazam")
			end
		end
	end

	return results
end

function Atr_SetMFcolor(moneyFrameName, useBlue)

	local goldButton   = _G[moneyFrameName .. "GoldButton"]
	local silverButton = _G[moneyFrameName .. "SilverButton"]
	local copperButton = _G[moneyFrameName .. "CopperButton"]

	local font = useBlue and NumberFontNormalRightATRblue or NumberFontNormalRight

	goldButton:SetNormalFontObject(font)
	silverButton:SetNormalFontObject(font)
	copperButton:SetNormalFontObject(font)
end

function Atr_ShowHints()

	Atr_Col1_Heading:Hide()
	Atr_Col3_Heading:Hide()
	Atr_Col4_Heading:Hide()
	Atr_Col3_Heading:SetText(ZT("Source"))

	local currentPane = Atr_GetCurrentPane()
	currentPane.hints = Atr_BuildHints(currentPane.activeScan.itemName)

	local numRows = currentPane.hints and #currentPane.hints or 0

	if numRows > 0 then
		Atr_Col1_Heading:Show()
		Atr_Col3_Heading:Show()
	end

	FauxScrollFrame_Update(AuctionatorScrollFrame, numRows, 12, 16)

	for line = 1, 12 do

		local dataOffset = line + FauxScrollFrame_GetOffset(AuctionatorScrollFrame)
		local lineEntry = _G["AuctionatorEntry" .. line]
		lineEntry:SetID(dataOffset)

		if dataOffset <= numRows and currentPane.hints[dataOffset] then

			local data = currentPane.hints[dataOffset]
			local priceFrameName = "AuctionatorEntry" .. line .. "_PerItem_Price"

			_G[priceFrameName]:Show()
			_G["AuctionatorEntry" .. line .. "_PerItem_Text"]:Hide()
			_G["AuctionatorEntry" .. line .. "_StackPrice"]:SetText("")

			Atr_SetMFcolor(priceFrameName, true)
			MoneyFrame_Update(priceFrameName, zc.round(data.price))

			local text = data.text
			if data.volume then
				text = text .. " (" .. ZT("trade volume") .. ": " .. data.volume .. ")"
			end

			local textFrame = _G["AuctionatorEntry" .. line .. "_EntryText"]
			textFrame:SetText(text)
			textFrame:SetTextColor(0.8, 0.8, 1.0)

			lineEntry:Show()
		else
			lineEntry:Hide()
		end
	end

	Atr_HighlightEntry(currentPane.hintsIndex)
end

-----------------------------------------
-- Combined price lookup (own scan DB, falls back to price history)
-----------------------------------------

function Atr_GetAuctionPrice(item) -- item may be an itemName (string) or itemID (number)

	local itemName = (type(item) == "number") and GetItemInfo(item) or item

	if itemName == nil then
		return nil
	end

	if Atr_ScanDB[itemName] then
		return Atr_ScanDB[itemName]
	end

	return Atr_GetMostRecentSale(itemName)
end

-----------------------------------------
-- Disenchant material name resolution
-----------------------------------------

local ITEM_QUALITY_UNCOMMON = 2
local ITEM_QUALITY_RARE     = 3
local ITEM_QUALITY_EPIC     = 4

local AUCTION_CLASS_WEAPON = 1
local AUCTION_CLASS_ARMOR  = 2

-- Disenchant material item IDs, grouped by essence/dust tier.
local LESSER_MAGIC, GREATER_MAGIC, STRANGE_DUST = 10938, 10939, 10940
local SMALL_GLIMMERING, LESSER_ASTRAL = 10978, 10998
local GREATER_ASTRAL, SOUL_DUST, LARGE_GLIMMERING = 11082, 11083, 11084
local LESSER_MYSTIC, GREATER_MYSTIC, VISION_DUST, SMALL_GLOWING, LARGE_GLOWING = 11134, 11135, 11137, 11138, 11139
local LESSER_NETHER, GREATER_NETHER, DREAM_DUST, SMALL_RADIANT, LARGE_RADIANT = 11174, 11175, 11176, 11177, 11178
local SMALL_BRILLIANT, LARGE_BRILLIANT = 14343, 14344
local LESSER_ETERNAL, GREATER_ETERNAL, ILLUSION_DUST = 16202, 16203, 16204
local NEXUS_CRYSTAL = 20725
local ARCANE_DUST, GREATER_PLANAR, LESSER_PLANAR, SMALL_PRISMATIC, LARGE_PRISMATIC, VOID_CRYSTAL = 22445, 22446, 22447, 22448, 22449, 22450
local DREAM_SHARD, SMALL_DREAM = 34052, 34053
local INFINITE_DUST, GREATER_COSMIC, LESSER_COSMIC, ABYSS_CRYSTAL = 34054, 34055, 34056, 34057

-- English fallback names, used only if GetItemInfo() hasn't cached the
-- item yet (see Atr_GetNextDustIntoCache below).
local ENGLISH_DE_ITEM_NAMES = {
	[LESSER_MAGIC]       = "Lesser Magic Essence",
	[GREATER_MAGIC]      = "Greater Magic Essence",
	[STRANGE_DUST]       = "Strange Dust",
	[SMALL_GLIMMERING]   = "Small Glimmering Shard",
	[LESSER_ASTRAL]      = "Lesser Astral Essence",
	[GREATER_ASTRAL]     = "Greater Astral Essence",
	[SOUL_DUST]          = "Soul Dust",
	[LARGE_GLIMMERING]   = "Large Glimmering Essence",
	[LESSER_MYSTIC]      = "Lesser Mystic Essence",
	[GREATER_MYSTIC]     = "Greater Mystic Essence",
	[VISION_DUST]        = "Vision Dust",
	[SMALL_GLOWING]      = "Small Glowing Shard",
	[LARGE_GLOWING]      = "Large Glowing Shard",
	[LESSER_NETHER]      = "Lesser Nether Essence",
	[GREATER_NETHER]     = "Greater Nether Essence",
	[DREAM_DUST]         = "Dream Dust",
	[SMALL_RADIANT]      = "Small Radiant",
	[LARGE_RADIANT]      = "Large Radiant",
	[SMALL_BRILLIANT]    = "Small Brilliant Shard",
	[LARGE_BRILLIANT]    = "Large Brilliant Shard",
	[LESSER_ETERNAL]     = "Lesser Eternal Essence",
	[GREATER_ETERNAL]    = "Greater Eternal Essence",
	[ILLUSION_DUST]      = "Illusion Dust",
	[NEXUS_CRYSTAL]      = "Nexus Crystal",
	[ARCANE_DUST]        = "Arcane Dust",
	[GREATER_PLANAR]     = "Greater Planar Essence",
	[LESSER_PLANAR]      = "Lesser Planar Essence",
	[SMALL_PRISMATIC]    = "Small Prismatic Shard",
	[LARGE_PRISMATIC]    = "Large Prismatic Shard",
	[VOID_CRYSTAL]       = "Void Crystal",
	[DREAM_SHARD]        = "Dream Shard",
	[SMALL_DREAM]        = "Small Dream Shard",
	[INFINITE_DUST]      = "Infinite Dust",
	[GREATER_COSMIC]     = "Greater Cosmic Essence",
	[LESSER_COSMIC]      = "Lesser Cosmic Essence",
	[ABYSS_CRYSTAL]      = "Abyss Crystal",
}

-- All disenchant material item IDs, used to pre-warm the item cache.
local DUST_AND_ESSENCE_ITEM_IDS = {
	LESSER_MAGIC, GREATER_MAGIC, STRANGE_DUST,
	SMALL_GLIMMERING, LESSER_ASTRAL,
	GREATER_ASTRAL, SOUL_DUST, LARGE_GLIMMERING,
	LESSER_MYSTIC, GREATER_MYSTIC, VISION_DUST, SMALL_GLOWING, LARGE_GLOWING,
	LESSER_NETHER, GREATER_NETHER, DREAM_DUST, SMALL_RADIANT, LARGE_RADIANT,
	SMALL_BRILLIANT, LARGE_BRILLIANT,
	LESSER_ETERNAL, GREATER_ETERNAL, ILLUSION_DUST,
	NEXUS_CRYSTAL,
	ARCANE_DUST, GREATER_PLANAR, LESSER_PLANAR, SMALL_PRISMATIC, LARGE_PRISMATIC, VOID_CRYSTAL,
	DREAM_SHARD, SMALL_DREAM,
	INFINITE_DUST, GREATER_COSMIC, LESSER_COSMIC, ABYSS_CRYSTAL,
}

gAtr_dustCacheIndex = 1 -- 0 once every material has been cached; read by Atr_OnUpdate
local dustCacheRequestPending = false

-- Slowly pulls every disenchant material into GetItemInfo's local cache
-- (only actually needed once, right after a client/DB wipe) by issuing
-- one SetHyperlink() tooltip probe per idle tick.
function Atr_GetNextDustIntoCache()

	if gAtr_dustCacheIndex == 0 then
		return
	end

	local itemID = DUST_AND_ESSENCE_ITEM_IDS[gAtr_dustCacheIndex]
	local itemString = "item:" .. itemID .. ":0:0:0:0:0:0:0"

	local itemName, itemLink = GetItemInfo(itemString)

	if itemLink == nil and not dustCacheRequestPending then
		dustCacheRequestPending = true
		zc.md("pulling " .. itemString .. " into the local cache")
		AtrScanningTooltip:SetHyperlink(itemString)
	end

	if itemLink then
		dustCacheRequestPending = false
		gAtr_dustCacheIndex = gAtr_dustCacheIndex + 1

		if gAtr_dustCacheIndex > #DUST_AND_ESSENCE_ITEM_IDS then
			gAtr_dustCacheIndex = 0 -- done
		end
	end
end

local resolvedDeItemNames = {}

local function GetDisenchantItemName(itemID)

	if resolvedDeItemNames[itemID] == nil then
		local itemName = GetItemInfo(itemID)
		if itemName == nil then
			zc.md("defaulting to english DE mat name: " .. ENGLISH_DE_ITEM_NAMES[itemID])
			return ENGLISH_DE_ITEM_NAMES[itemID]
		end
		resolvedDeItemNames[itemID] = itemName
	end

	return resolvedDeItemNames[itemID]
end

-- Same as Atr_GetAuctionPrice, but aware that some "lesser" essences can
-- be crafted down from "greater" ones - if that's cheaper, use it instead.
function Atr_GetAuctionPriceDE(itemID)

	local lesserPrice, greaterPrice

	if itemID == LESSER_COSMIC then
		lesserPrice  = Atr_GetAuctionPrice(GetDisenchantItemName(LESSER_COSMIC))
		greaterPrice = Atr_GetAuctionPrice(GetDisenchantItemName(GREATER_COSMIC))
	elseif itemID == LESSER_PLANAR then
		lesserPrice  = Atr_GetAuctionPrice(GetDisenchantItemName(LESSER_PLANAR))
		greaterPrice = Atr_GetAuctionPrice(GetDisenchantItemName(GREATER_PLANAR))
	end

	if lesserPrice ~= nil and greaterPrice ~= nil and lesserPrice * 3 > greaterPrice then
		return math.floor(greaterPrice / 3)
	end

	return Atr_GetAuctionPrice(GetDisenchantItemName(itemID))
end

-----------------------------------------
-- Disenchanting yield tables
-- (source: community-compiled disenchanting tables for WotLK)
-----------------------------------------

local disenchantTablesByClassAndRarity = {}

local function TableKey(itemType, itemRarity)
	return tostring(itemType) .. "_" .. itemRarity
end

-- Expands a compact { minLevel, maxLevel, chance, qty, itemID, ... }
-- definition into a normalized entry. `qty` may be a single number or a
-- { min, max } range, in which case the chance is split evenly across
-- each possible quantity.
local function AddDisenchantEntry(table_, definition)

	local entry = { definition[1], definition[2] }
	local writeIndex = 3

	for i = 3, #definition, 3 do
		local qty = definition[i + 1]

		if type(qty) == "number" then
			entry[writeIndex]     = definition[i]
			entry[writeIndex + 1] = definition[i + 1]
			entry[writeIndex + 2] = definition[i + 2]
			writeIndex = writeIndex + 3
		else
			for q = qty[1], qty[2] do
				entry[writeIndex]     = definition[i] / (qty[2] - qty[1] + 1)
				entry[writeIndex + 1] = q
				entry[writeIndex + 2] = definition[i + 2]
				writeIndex = writeIndex + 3
			end
		end
	end

	table.insert(table_, entry)
end

-- Builds the full disenchanting.yield table set. Called once at startup.
-- Values are based on the classic WotLK disenchanting yield tables.
function Atr_InitDETable()

	-- Uncommon armor
	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_UNCOMMON)] = {}
	local uncommonArmor = disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_UNCOMMON)]

	AddDisenchantEntry(uncommonArmor, {5, 15,     80, {1,2}, STRANGE_DUST,   20, {1,2}, LESSER_MAGIC})
	AddDisenchantEntry(uncommonArmor, {16, 20,     75, {2,3}, STRANGE_DUST,   20, {1,2}, GREATER_MAGIC,  5, 1, SMALL_GLIMMERING})
	AddDisenchantEntry(uncommonArmor, {21, 25,     75, {4,6}, STRANGE_DUST,   15, {1,2}, LESSER_ASTRAL,  10, 1, SMALL_GLIMMERING})
	AddDisenchantEntry(uncommonArmor, {26, 30,     75, {1,2}, SOUL_DUST,      20, {1,2}, GREATER_ASTRAL, 5, 1, LARGE_GLIMMERING})
	AddDisenchantEntry(uncommonArmor, {31, 35,     75, {2,5}, SOUL_DUST,      20, {1,2}, LESSER_MYSTIC,  5, 1, SMALL_GLOWING})
	AddDisenchantEntry(uncommonArmor, {36, 40,     75, {1,2}, VISION_DUST,    20, {1,2}, GREATER_MYSTIC, 5, 1, LARGE_GLOWING})
	AddDisenchantEntry(uncommonArmor, {41, 45,     75, {2,5}, VISION_DUST,    20, {1,2}, LESSER_NETHER,  5, 1, SMALL_RADIANT})
	AddDisenchantEntry(uncommonArmor, {46, 50,     75, {1,2}, DREAM_DUST,     20, {1,2}, GREATER_NETHER, 5, 1, LARGE_RADIANT})
	AddDisenchantEntry(uncommonArmor, {51, 55,     75, {2,5}, DREAM_DUST,     20, {1,2}, LESSER_ETERNAL, 5, 1, SMALL_BRILLIANT})
	AddDisenchantEntry(uncommonArmor, {56, 60,     75, {1,2}, ILLUSION_DUST,  20, {1,2}, GREATER_ETERNAL,5, 1, LARGE_BRILLIANT})
	AddDisenchantEntry(uncommonArmor, {61, 65,     75, {2,5}, ILLUSION_DUST,  20, {2,3}, GREATER_ETERNAL,5, 1, LARGE_BRILLIANT})
	AddDisenchantEntry(uncommonArmor, {66, 80,     75, {1,3}, ARCANE_DUST,    22, {1,3}, LESSER_PLANAR,  3, 1, SMALL_PRISMATIC})
	AddDisenchantEntry(uncommonArmor, {81, 99,     75, {2,3}, ARCANE_DUST,    22, {2,3}, LESSER_PLANAR,  3, 1, SMALL_PRISMATIC})
	AddDisenchantEntry(uncommonArmor, {100, 120,   75, {2,5}, ARCANE_DUST,    22, {1,2}, GREATER_PLANAR, 3, 1, LARGE_PRISMATIC})
	AddDisenchantEntry(uncommonArmor, {121, 151,   75, {1,3}, INFINITE_DUST,  22, {1,2}, LESSER_COSMIC,  3, 1, SMALL_DREAM})
	AddDisenchantEntry(uncommonArmor, {152, 200,   75, {4,7}, INFINITE_DUST,  22, {1,2}, GREATER_COSMIC, 3, 1, DREAM_SHARD})

	-- Uncommon weapons
	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_WEAPON, ITEM_QUALITY_UNCOMMON)] = {}
	local uncommonWeapon = disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_WEAPON, ITEM_QUALITY_UNCOMMON)]

	AddDisenchantEntry(uncommonWeapon, {6, 15,      20, {1,2}, STRANGE_DUST,   80, {1,2}, LESSER_MAGIC})
	AddDisenchantEntry(uncommonWeapon, {16, 20,     20, {2,3}, STRANGE_DUST,   75, {1,2}, GREATER_MAGIC,  5, 1, SMALL_GLIMMERING})
	AddDisenchantEntry(uncommonWeapon, {21, 25,     15, {4,6}, STRANGE_DUST,   75, {1,2}, LESSER_ASTRAL,  10, 1, SMALL_GLIMMERING})
	AddDisenchantEntry(uncommonWeapon, {26, 30,     20, {1,2}, SOUL_DUST,      75, {1,2}, GREATER_ASTRAL, 5, 1, LARGE_GLIMMERING})
	AddDisenchantEntry(uncommonWeapon, {31, 35,     20, {2,5}, SOUL_DUST,      75, {1,2}, LESSER_MYSTIC,  5, 1, SMALL_GLOWING})
	AddDisenchantEntry(uncommonWeapon, {36, 40,     20, {1,2}, VISION_DUST,    75, {1,2}, GREATER_MYSTIC, 5, 1, LARGE_GLOWING})
	AddDisenchantEntry(uncommonWeapon, {41, 45,     20, {2,5}, VISION_DUST,    75, {1,2}, LESSER_NETHER,  5, 1, SMALL_RADIANT})
	AddDisenchantEntry(uncommonWeapon, {46, 50,     20, {1,2}, DREAM_DUST,     75, {1,2}, GREATER_NETHER, 5, 1, LARGE_RADIANT})
	AddDisenchantEntry(uncommonWeapon, {51, 55,     22, {2,5}, DREAM_DUST,     75, {1,2}, LESSER_ETERNAL, 5, 1, SMALL_BRILLIANT})
	AddDisenchantEntry(uncommonWeapon, {56, 60,     22, {1,2}, ILLUSION_DUST,  75, {1,2}, GREATER_ETERNAL,5, 1, LARGE_BRILLIANT})
	AddDisenchantEntry(uncommonWeapon, {61, 65,     22, {2,5}, ILLUSION_DUST,  75, {2,3}, GREATER_ETERNAL,5, 1, LARGE_BRILLIANT})
	AddDisenchantEntry(uncommonWeapon, {66, 99,     22, {2,3}, ARCANE_DUST,    75, {2,3}, LESSER_PLANAR,  3, 1, SMALL_PRISMATIC})
	AddDisenchantEntry(uncommonWeapon, {100, 120,   22, {2,5}, ARCANE_DUST,    75, {1,2}, GREATER_PLANAR, 3, 1, LARGE_PRISMATIC})
	AddDisenchantEntry(uncommonWeapon, {121, 151,   22, {1,3}, INFINITE_DUST,  75, {1,2}, LESSER_COSMIC,  3, 1, SMALL_DREAM})
	AddDisenchantEntry(uncommonWeapon, {152, 200,   22, {4,7}, INFINITE_DUST,  75, {1,2}, GREATER_COSMIC, 3, 1, DREAM_SHARD})

	-- Rare items (armor and weapon share the same table)
	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_RARE)] = {}
	local rareItems = disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_RARE)]

	AddDisenchantEntry(rareItems, {11, 25,    100, 1, SMALL_GLIMMERING})
	AddDisenchantEntry(rareItems, {26, 30,    100, 1, LARGE_GLIMMERING})
	AddDisenchantEntry(rareItems, {31, 35,    100, 1, SMALL_GLOWING})
	AddDisenchantEntry(rareItems, {36, 40,    100, 1, LARGE_GLOWING})
	AddDisenchantEntry(rareItems, {41, 45,    100, 1, SMALL_RADIANT})
	AddDisenchantEntry(rareItems, {46, 50,    100, 1, LARGE_RADIANT})
	AddDisenchantEntry(rareItems, {51, 55,    100, 1, SMALL_BRILLIANT})
	AddDisenchantEntry(rareItems, {56, 65,    99.5, 1, LARGE_BRILLIANT,  0.5, 1, NEXUS_CRYSTAL})
	AddDisenchantEntry(rareItems, {66, 99,    99.5, 1, SMALL_PRISMATIC,  0.5, 1, NEXUS_CRYSTAL})
	AddDisenchantEntry(rareItems, {100, 120,  99.5, 1, LARGE_PRISMATIC,  0.5, 1, VOID_CRYSTAL})
	AddDisenchantEntry(rareItems, {121, 164,  99.5, 1, SMALL_DREAM,      0.5, 1, ABYSS_CRYSTAL})
	AddDisenchantEntry(rareItems, {165, 999,  99.5, 1, DREAM_SHARD,      0.5, 1, ABYSS_CRYSTAL})

	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_WEAPON, ITEM_QUALITY_RARE)] = rareItems

	-- Epic items (weapon table is a deep copy since it diverges partway through)
	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_EPIC)] = {}
	local epicArmor = disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_EPIC)]

	AddDisenchantEntry(epicArmor, {40, 45,    100, {2,4}, SMALL_RADIANT})
	AddDisenchantEntry(epicArmor, {46, 50,    100, {2,4}, LARGE_RADIANT})
	AddDisenchantEntry(epicArmor, {51, 55,    100, {2,4}, SMALL_BRILLIANT})
	AddDisenchantEntry(epicArmor, {56, 60,    100, 1, NEXUS_CRYSTAL})
	-- 61-80 range is added below (differs between armor and weapon)
	AddDisenchantEntry(epicArmor, {95, 100,   100, {1,2}, VOID_CRYSTAL})
	AddDisenchantEntry(epicArmor, {105, 164,  33.3, 1, VOID_CRYSTAL,  66.6, 2, VOID_CRYSTAL})
	AddDisenchantEntry(epicArmor, {165, 200,  100, 1, ABYSS_CRYSTAL})
	AddDisenchantEntry(epicArmor, {200, 999,  100, 1, ABYSS_CRYSTAL})

	disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_WEAPON, ITEM_QUALITY_EPIC)] = zc.CopyDeep(epicArmor)

	AddDisenchantEntry(disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_ARMOR, ITEM_QUALITY_EPIC)],
		{61, 80, 50,   1, NEXUS_CRYSTAL, 50,   2, NEXUS_CRYSTAL})
	AddDisenchantEntry(disenchantTablesByClassAndRarity[TableKey(AUCTION_CLASS_WEAPON, ITEM_QUALITY_EPIC)],
		{61, 80, 33.3, 1, NEXUS_CRYSTAL, 66.6, 2, NEXUS_CRYSTAL})
end

local function FindDisenchantEntry(itemType, itemRarity, itemLevel)

	local itemTypeNum = Atr_ItemType2AuctionClass(itemType)
	local table_ = disenchantTablesByClassAndRarity[TableKey(itemTypeNum, itemRarity)]

	if table_ then
		for i = 1, #table_ do
			local entry = table_[i]
			if itemLevel >= entry[1] and itemLevel <= entry[2] then
				return entry
			end
		end
	end
end

local function AppendDisenchantDetailsToTooltip(tooltip, itemType, itemRarity, itemLevel, requiredSkillLevel)

	local entry = FindDisenchantEntry(itemType, itemRarity, itemLevel)

	if entry then
		for i = 3, #entry, 3 do
			local percent = math.floor(entry[i] * 100) / 100
			local materialName = GetDisenchantItemName(entry[i + 2]) or "???"
			tooltip:AddLine("  |cFFFFFFFF" .. percent .. "%|r   " .. entry[i + 1] .. " " .. materialName)
		end
	end

	tooltip:AddLine("  |cFFAAAAFF" .. ZT("Required DE skill level") .. ": " .. requiredSkillLevel)
end

-- Estimated disenchant value in copper, or nil if the item can't be disenchanted.
function Atr_CalcDisenchantPrice(itemType, itemRarity, itemLevel)

	if not (Atr_IsWeaponType(itemType) or Atr_IsArmorType(itemType)) then
		return nil
	end

	if itemRarity ~= ITEM_QUALITY_UNCOMMON and itemRarity ~= ITEM_QUALITY_RARE and itemRarity ~= ITEM_QUALITY_EPIC then
		return nil
	end

	local totalPrice = 0
	local entry = FindDisenchantEntry(itemType, itemRarity, itemLevel)

	if entry then
		for i = 3, #entry, 3 do
			local materialPrice = Atr_GetAuctionPriceDE(entry[i + 2])
			if materialPrice then
				totalPrice = totalPrice + (entry[i] * entry[i + 1] * materialPrice)
			end
		end
	end

	return math.floor(totalPrice / 100)
end

-----------------------------------------
-- Tooltip augmentation
-----------------------------------------

local function ShowTipWithPricing(tooltip, itemLink, stackCount)

	if itemLink == nil then
		return
	end

	local itemName, _, itemRarity, itemLevel, _, itemType, _, _, _, _, vendorPrice = GetItemInfo(itemLink)
	local itemID = tonumber(zc.ItemIDfromLink(itemLink))

	local auctionPrice = 0
	local disenchantPrice = nil

	if AUCTIONATOR_A_TIPS == 1 then auctionPrice = Atr_GetAuctionPrice(itemName) end
	if AUCTIONATOR_D_TIPS == 1 then disenchantPrice = Atr_CalcDisenchantPrice(itemType, itemRarity, itemLevel) end

	local stackSuffix = ""
	local showStackPrices = IsShiftKeyDown()

	if AUCTIONATOR_SHIFT_TIPS == 2 then
		showStackPrices = not IsShiftKeyDown()
	end

	if stackCount and showStackPrices then
		if auctionPrice then auctionPrice = auctionPrice * stackCount end
		if vendorPrice then vendorPrice = vendorPrice * stackCount end
		if disenchantPrice then disenchantPrice = disenchantPrice * stackCount end
		stackSuffix = "|cFFAAAAFF x" .. stackCount .. "|r"
	end

	vendorPrice = vendorPrice or 0

	if AUCTIONATOR_A_TIPS == 1 then

		local bonding = Atr_GetBonding(itemID)
		local isSoulbound = (bonding == 1)
		local isQuestItem = (bonding == 4 or bonding == 5)

		if isSoulbound then
			tooltip:AddDoubleLine(ZT("Auction") .. stackSuffix, "|cFFFFFFFF" .. ZT("BOP") .. "  ")
		elseif isQuestItem then
			tooltip:AddDoubleLine(ZT("Auction") .. stackSuffix, "|cFFFFFFFF" .. ZT("Quest Item") .. "  ")
		elseif auctionPrice ~= nil then
			tooltip:AddDoubleLine(ZT("Auction") .. stackSuffix, "|cFFFFFFFF" .. zc.priceToMoneyString(auctionPrice))
		else
			tooltip:AddDoubleLine(ZT("Auction") .. stackSuffix, "|cFFFFFFFF" .. ZT("unknown") .. "  ")
		end
	end

	if AUCTIONATOR_D_TIPS == 1 and disenchantPrice ~= nil then
		if disenchantPrice > 0 then
			tooltip:AddDoubleLine(ZT("Disenchant") .. stackSuffix, "|cFFFFFFFF" .. zc.priceToMoneyString(disenchantPrice))
		else
			tooltip:AddDoubleLine(ZT("Disenchant") .. stackSuffix, "|cFFFFFFFF" .. ZT("unknown") .. "  ")
		end
	end

	local showDisenchantDetails = true
	if AUCTIONATOR_DE_DETAILS_TIPS == 1 then showDisenchantDetails = IsShiftKeyDown() end
	if AUCTIONATOR_DE_DETAILS_TIPS == 2 then showDisenchantDetails = IsControlKeyDown() end
	if AUCTIONATOR_DE_DETAILS_TIPS == 3 then showDisenchantDetails = IsAltKeyDown() end
	if AUCTIONATOR_DE_DETAILS_TIPS == 4 then showDisenchantDetails = false end
	if AUCTIONATOR_DE_DETAILS_TIPS == 5 then showDisenchantDetails = true end

	if showDisenchantDetails and disenchantPrice ~= nil then
		AppendDisenchantDetailsToTooltip(tooltip, itemType, itemRarity, itemLevel, Atr_DEReqLevel(itemID))
	end

	tooltip:Show()
end

hooksecurefunc(GameTooltip, "SetBagItem", function(tooltip, bag, slot)
	local _, count = GetContainerItemInfo(bag, slot)
	ShowTipWithPricing(tooltip, GetContainerItemLink(bag, slot), count)
end)

hooksecurefunc(GameTooltip, "SetAuctionItem", function(tooltip, listType, index)
	local _, _, count = GetAuctionItemInfo(listType, index)
	ShowTipWithPricing(tooltip, GetAuctionItemLink(listType, index), count)
end)

hooksecurefunc(GameTooltip, "SetAuctionSellItem", function(tooltip)
	local name, _, count = GetAuctionSellItemInfo()
	local _, link = GetItemInfo(name)
	ShowTipWithPricing(tooltip, link, count) -- fixed: was referencing an undeclared "num"
end)

hooksecurefunc(GameTooltip, "SetLootItem", function(tooltip, slot)
	if LootSlotIsItem(slot) then
		local link, _, count = GetLootSlotLink(slot)
		ShowTipWithPricing(tooltip, link, count)
	end
end)

hooksecurefunc(GameTooltip, "SetLootRollItem", function(tooltip, slot)
	local _, _, count = GetLootRollItemInfo(slot)
	ShowTipWithPricing(tooltip, GetLootRollItemLink(slot), count)
end)

hooksecurefunc(GameTooltip, "SetInventoryItem", function(tooltip, unit, slot)
	ShowTipWithPricing(tooltip, GetInventoryItemLink(unit, slot), GetInventoryItemCount(unit, slot))
end)

hooksecurefunc(GameTooltip, "SetGuildBankItem", function(tooltip, tab, slot)
	local _, count = GetGuildBankItemInfo(tab, slot)
	ShowTipWithPricing(tooltip, GetGuildBankItemLink(tab, slot), count)
end)

hooksecurefunc(GameTooltip, "SetTradeSkillItem", function(tooltip, skillIndex, reagentIndex)
	local link = GetTradeSkillItemLink(skillIndex)
	local count = GetTradeSkillNumMade(skillIndex)
	if reagentIndex then
		link = GetTradeSkillReagentItemLink(skillIndex, reagentIndex)
		count = select(3, GetTradeSkillReagentInfo(skillIndex, reagentIndex))
	end
	ShowTipWithPricing(tooltip, link, count)
end)

hooksecurefunc(GameTooltip, "SetTradePlayerItem", function(tooltip, index)
	local _, _, count = GetTradePlayerItemInfo(index)
	ShowTipWithPricing(tooltip, GetTradePlayerItemLink(index), count)
end)

hooksecurefunc(GameTooltip, "SetTradeTargetItem", function(tooltip, index)
	local _, _, count = GetTradeTargetItemInfo(index)
	ShowTipWithPricing(tooltip, GetTradeTargetItemLink(index), count)
end)

hooksecurefunc(GameTooltip, "SetQuestItem", function(tooltip, questType, index)
	local _, _, count = GetQuestItemInfo(questType, index)
	ShowTipWithPricing(tooltip, GetQuestItemLink(questType, index), count)
end)

hooksecurefunc(GameTooltip, "SetQuestLogItem", function(tooltip, questType, index)
	local count
	if questType == "choice" then
		_, _, count = GetQuestLogChoiceInfo(index)
	else
		_, _, count = GetQuestLogRewardInfo(index)
	end
	ShowTipWithPricing(tooltip, GetQuestLogItemLink(questType, index), count)
end)

hooksecurefunc(GameTooltip, "SetInboxItem", function(tooltip, index, attachIndex)
	local _, _, count = GetInboxItem(index, attachIndex)
	ShowTipWithPricing(tooltip, GetInboxItemLink(index, attachIndex), count)
end)

hooksecurefunc(GameTooltip, "SetSendMailItem", function(tooltip, index)
	local name, _, count = GetSendMailItem(index)
	local _, link = GetItemInfo(name)
	ShowTipWithPricing(tooltip, link, count)
end)

hooksecurefunc(GameTooltip, "SetHyperlink", function(tooltip, itemString, count)
	local _, link = GetItemInfo(itemString)
	ShowTipWithPricing(tooltip, link, count)
end)

hooksecurefunc(ItemRefTooltip, "SetHyperlink", function(tooltip, itemString)
	local _, link = GetItemInfo(itemString)
	ShowTipWithPricing(tooltip, link, nil)
end)
