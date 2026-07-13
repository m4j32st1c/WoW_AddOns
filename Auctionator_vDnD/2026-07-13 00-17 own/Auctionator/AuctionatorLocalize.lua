--[[
	AuctionatorLocalize.lua

	English-only build: no locale table lookup is needed, ZT() simply
	returns the string it was given. Kept as a function (instead of
	removing all ZT(...) call sites) so the rest of the codebase does
	not need to change.
]]

local addonName, addonTable = ...
local zc = addonTable.zc

-- Returns the (already English) UI string unchanged.
-- Kept for API compatibility with the rest of the addon.
function ZT(s)
	return s
end

-----------------------------------------
-- Frame text localization (kept from the original addon; still useful
-- for developer tooling / consistency checks even without translations)
-----------------------------------------

local EXCLUDED_BUTTON_TEXTS = { Cancel = 1, Okay = 1, Done = 1, Close = 1 }

local function LocalizeChildText(frame)

	for _, child in ipairs({ frame:GetRegions() }) do
		if type(child.GetText) == "function" then
			local text = child:GetText()
			local name = tostring(child:GetName())

			if text and text ~= "" and not EXCLUDED_BUTTON_TEXTS[text]
				and not zc.StringStartsWith(name, "AuctionatorEntry") then
				child:SetText(ZT(text))
			end
		end
	end

	for _, child in ipairs({ frame:GetChildren() }) do
		if type(child.GetText) == "function" then
			local text = child:GetText()
			local name = tostring(child:GetName())

			if text and text ~= "" and not EXCLUDED_BUTTON_TEXTS[text]
				and not zc.StringStartsWith(name, "AuctionatorEntry") then

				if child:GetObjectType() == "Button" then
					local oldWidth = math.floor(child:GetWidth())
					child:SetText(ZT(text))
					local newWidth = math.floor(child:GetTextWidth()) + 15
					if newWidth > oldWidth then
						child:SetWidth(newWidth + 20)
					end
				else
					child:SetText(ZT(text))
				end
			end
		end

		if child:GetObjectType() ~= "Button" then
			LocalizeChildText(child)
		end
	end
end

function Atr_LocalizeFrames()

	local frame = EnumerateFrames()

	while frame do
		local frameName  = frame:GetName()
		local parentName = frame:GetParent() and frame:GetParent():GetName() or nil

		local isAuctionatorFrame = frameName == "Atr_Main_Panel"
			or ((zc.StringStartsWith(frameName, "Atr") or zc.StringStartsWith(frameName, "Auctionator"))
				and zc.StringSame(parentName, "UIParent"))

		if isAuctionatorFrame then
			LocalizeChildText(frame)
		end

		frame = EnumerateFrames(frame)
	end
end

-----------------------------------------
-- Item classification helpers (used by stacking preferences)
-----------------------------------------

local UNCUT_GEM_ITEM_IDS = {
	36924, 36925, -- sky sapphire, majestic zircon
	36918, 36919, -- scarlet ruby, cardinal ruby
	36933, 36934, -- forest emerald, eye of zul
	36930, 36931, -- monarch topaz, ametrine
	36927, 36928, -- twilight opal, dreadstone
	36921, 36922, -- autumn's glow, king's amber
	41334, 41266, -- earthsiege diamond, skyflare diamond
	42225,        -- dragon's eye
}

function Atr_IsCutGem(itemLink)

	if not Atr_IsGem(itemLink) then
		return false
	end

	local itemID = zc.ItemIDfromLink(itemLink)

	for _, uncutID in ipairs(UNCUT_GEM_ITEM_IDS) do
		if itemID == tostring(uncutID) then
			return false
		end
	end

	return true
end

function Atr_IsGlyph(itemLink)           return Atr_IsClass(itemLink, 5) end
function Atr_IsGem(itemLink)             return Atr_IsClass(itemLink, 10) end
function Atr_IsItemEnhancement(itemLink) return Atr_IsClass(itemLink, 4, 6) end
function Atr_IsPotion(itemLink)          return Atr_IsClass(itemLink, 4, 2) end
function Atr_IsElixir(itemLink)          return Atr_IsClass(itemLink, 4, 3) end
function Atr_IsFlask(itemLink)           return Atr_IsClass(itemLink, 4, 4) end
function Atr_IsHerb(itemLink)            return Atr_IsClass(itemLink, 6, 6) end

-- NOTE: if Blizzard ever adds new auction house classes, these need updating.
function Atr_IsWeaponType(itemType) return Atr_ItemType2AuctionClass(itemType) == 1 end
function Atr_IsArmorType(itemType)  return Atr_ItemType2AuctionClass(itemType) == 2 end

function Atr_IsClass(itemLink, class, subclass)

	if itemLink == nil then
		return false
	end

	local _, _, _, _, _, itemType, itemSubType = GetItemInfo(itemLink)
	local itemClass = Atr_ItemType2AuctionClass(itemType)

	if itemClass ~= class then
		return false
	end

	if subclass == nil then
		return true
	end

	return Atr_SubType2AuctionSubclass(itemClass, itemSubType) == subclass
end

-----------------------------------------
-- Auction house class / subclass caches
-----------------------------------------

local gItemClasses
local gItemSubClasses

function Atr_GetAuctionClasses()
	gItemClasses = gItemClasses or { GetAuctionItemClasses() }
	return gItemClasses
end

function Atr_GetAuctionSubclasses(auctionClass)
	gItemSubClasses = gItemSubClasses or {}
	gItemSubClasses[auctionClass] = gItemSubClasses[auctionClass] or { GetAuctionItemSubClasses(auctionClass) }
	return gItemSubClasses[auctionClass]
end

function Atr_ItemType2AuctionClass(itemType)

	for index, className in pairs(Atr_GetAuctionClasses()) do
		if zc.StringSame(className, itemType) then
			return index
		end
	end

	return 0
end

function Atr_SubType2AuctionSubclass(auctionClass, itemSubtype)

	for index, subClassName in pairs(Atr_GetAuctionSubclasses(auctionClass)) do
		if zc.StringSame(subClassName, itemSubtype) then
			return index
		end
	end

	return 0
end
