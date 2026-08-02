local Routes_vDnD = LibStub("AceAddon-3.0"):GetAddon("Routes_vDnD", 1)
if not Routes_vDnD then return end

-- GEÄNDERT: SourceName und AddonFolderName aufgeteilt.
-- Vorher stand hier durchgängig "Gathermate2_vDnD" als SourceName, was 4 Dinge
-- gleichzeitig kaputt gemacht hat:
--   1) IsActive() prüfte die globale Tabelle "Gathermate2_vDnD" - die gibt es nie,
--      GatherMate2 selbst wurde intern NICHT umbenannt und setzt weiterhin
--      _G["GatherMate2"] (siehe GatherMate2_vDnD/GatherMate2.lua). IsActive() war
--      dadurch dauerhaft false.
--   2) Routes_vDnD.plugins[SourceName] registrierte sich unter "Gathermate2_vDnD",
--      aber Routes_vDnD.lua sucht in RecreateRoute() hartcodiert nach
--      Routes.plugins["GatherMate2"] - der Eintrag wurde nie gefunden.
--   3) Der AceLocale-Namespace "Gathermate2_vDnDNodes" existiert nicht,
--      GatherMate2 registriert seine Lokalisierung unter "GatherMate2Nodes".
--   4) RegisterMessage lauschte auf "Gathermate2_vDnDNodeAdded"/"...Deleted",
--      GatherMate2 sendet aber "GatherMate2NodeAdded"/"GatherMate2NodeDeleted"
--      (siehe GatherMate2.lua: AddNode()/RemoveNode()). Die Callbacks feuerten nie.
-- SourceName ist daher wieder "GatherMate2" (unveraendert, wie im Original-Addon).
-- AddonFolderName ist der tatsaechliche Ordnername "GatherMate2_vDnD" und wird
-- ausschliesslich fuer die Addon-Erkennung (GetAddOnEnableState/GetAddOnInfo)
-- gebraucht, NICHT fuer globale Tabellen, Locale-Namespaces oder Message-Namen.
local SourceName = "GatherMate2"
local AddonFolderName = "GatherMate2_vDnD"
-- GEÄNDERT: Locale-Namespace "Routes" statt "Routes_vDnD" (siehe Begründung in
-- Plugins\Gatherer_vDnD.lua - identischer Bug, alle Locale-xxx.lua registrieren
-- unter "Routes", nie unter "Routes_vDnD").
local L = LibStub("AceLocale-3.0"):GetLocale("Routes")
local LN = LibStub("AceLocale-3.0"):GetLocale("GatherMate2Nodes", true)

------------------------------------------
-- setup
Routes_vDnD.plugins[SourceName] = {}
local source = Routes_vDnD.plugins[SourceName]

do
	local loaded = true
	local function IsActive() -- Can we gather data?
		return GatherMate2 and loaded
	end
	source.IsActive = IsActive

	-- stop loading if the addon is not enabled, or
	-- stop loading if there is a reason why it can't be loaded ("MISSING" or "DISABLED")
	-- GEÄNDERT: AddonFolderName statt SourceName, da hier der tatsaechliche
	-- Ordnername gefragt werden muss ("GatherMate2_vDnD"), nicht der interne Name.
	local enabled = C_AddOns.GetAddOnEnableState(AddonFolderName, UnitName("player")) > 0
	local name, title, notes, loadable, reason, security = C_AddOns.GetAddOnInfo(AddonFolderName)
	if not enabled or (reason ~= nil and reason ~= "" and reason ~= "DEMAND_LOADED") then
		loaded = false
		return
	end
end

------------------------------------------
-- functions

local amount_of = {}
local function Summarize(data, zone)
	-- GEÄNDERT: korrekter Locale-Namespace "GatherMate2Nodes" statt "Gathermate2_vDnDNodes".
	LN = LibStub("AceLocale-3.0"):GetLocale("GatherMate2Nodes", true) -- Workaround LoD of GatherMate2 if AddonLoader is used.
	for db_type, db_data in pairs(GatherMate2.gmdbs) do
		-- reuse table
		wipe(amount_of)
		-- only look for data for this currentzone
		local zoneID = Routes_vDnD.LZName[zone]
		if db_data[zoneID] then
			-- count the unique values (structure is: location => itemID)
			for _,node in pairs(db_data[zoneID]) do
				amount_of[node] = (amount_of[node] or 0) + 1
			end
			-- XXX Localize these strings
			-- store combinations with all information we have
			for node,count in pairs(amount_of) do
				local translatednode = GatherMate2:GetNameForNode(db_type, node)
				if translatednode then
					data[ ("%s;%s;%s;%s"):format(SourceName, db_type, node, count) ] = ("%s - %s (%d)"):format(L[SourceName..db_type], translatednode, count)
				end
			end
		end
	end
	return data
end
source.Summarize = Summarize

-- returns the english name, translated name for the node so we can store it was being requested
-- also returns the type of db for use with auto show/hide route
local translate_db_type = {
	["Herb Gathering"] = "Herbalism",
	["Mining"] = "Mining",
	["Fishing"] = "Fishing",
	["Extract Gas"] = "ExtractGas",
	["Treasure"] = "Treasure",
	["Archaeology"] = "Archaeology",
	["Logging"] = "Logging",
}
local function AppendNodes(node_list, zone, db_type, node_type)
	if type(GatherMate2.gmdbs[db_type]) == "table" then
		node_type = tonumber(node_type)

		-- Find all of the notes
		local zoneID = Routes_vDnD.LZName[zone]
		for loc, t in GatherMate2:GetNodesForZone(zoneID, db_type, true) do
			-- And are of a selected type - store
			if t == node_type then
				-- Convert GM2 location to our format
				local x, y, l = GatherMate2:DecodeLoc(loc) -- ignore level for now
				local newLoc = Routes_vDnD:getID(x, y)
				tinsert( node_list, newLoc )
			end
		end

		-- return the node_type for auto-adding
		local translatednode = GatherMate2:GetNameForNode(db_type, node_type)
		for k, v in pairs(LN) do
			if v == translatednode then -- get the english name
				return k, v, translate_db_type[db_type]
			end
		end
	end
end
source.AppendNodes = AppendNodes

local function InsertNode(event, zone, nodeType, coord, node_name)
	-- Convert coords
	local x, y, l = GatherMate2:DecodeLoc(coord) -- ignore level for now
	local newCoord = Routes_vDnD:getID(x, y)
	-- Convert zone
	local zoneLocalized = Routes_vDnD.GetZoneName(zone)
	if not zoneLocalized then return end
	Routes_vDnD:InsertNode(zoneLocalized, newCoord, node_name)
end

local function DeleteNode(event, zone, nodeType, coord, node_name)
	-- Convert coords
	local x, y, l = GatherMate2:DecodeLoc(coord) -- ignore level for now
	local newCoord = Routes_vDnD:getID(x, y)
	-- Convert zone
	local zoneLocalized = Routes_vDnD.GetZoneName(zone)
	if not zoneLocalized then return end
	Routes_vDnD:DeleteNode(zoneLocalized, newCoord, node_name)
end

local function AddCallbacks()
	-- GEÄNDERT: korrekte Message-Namen "GatherMate2NodeAdded"/"GatherMate2NodeDeleted"
	-- statt "Gathermate2_vDnDNodeAdded"/"...Deleted" - so sendet GatherMate2 sie
	-- tatsaechlich (siehe GatherMate2_vDnD/GatherMate2.lua, AddNode()/RemoveNode()).
	Routes_vDnD:RegisterMessage("GatherMate2NodeAdded", InsertNode)
	Routes_vDnD:RegisterMessage("GatherMate2NodeDeleted", DeleteNode)
end
source.AddCallbacks = AddCallbacks

local function RemoveCallbacks()
	Routes_vDnD:UnregisterMessage("GatherMate2NodeAdded")
	Routes_vDnD:UnregisterMessage("GatherMate2NodeDeleted")
end
source.RemoveCallbacks = RemoveCallbacks

-- vim: ts=4 noexpandtab
