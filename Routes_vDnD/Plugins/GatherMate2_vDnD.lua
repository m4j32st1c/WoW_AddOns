local Routes_vDnD = LibStub("AceAddon-3.0"):GetAddon("Routes_vDnD", 1)
if not Routes_vDnD then return end

local SourceName = "Gathermate2_vDnD"
local L = LibStub("AceLocale-3.0"):GetLocale("Routes_vDnD")
local LN = LibStub("AceLocale-3.0"):GetLocale("Gathermate2_vDnDNodes", true)

------------------------------------------
-- setup
Routes_vDnD.plugins[SourceName] = {}
local source = Routes_vDnD.plugins[SourceName]

do
	local loaded = true
	local function IsActive() -- Can we gather data?
		return Gathermate2_vDnD and loaded
	end
	source.IsActive = IsActive

	-- stop loading if the addon is not enabled, or
	-- stop loading if there is a reason why it can't be loaded ("MISSING" or "DISABLED")
	local enabled = C_AddOns.GetAddOnEnableState(SourceName, UnitName("player")) > 0
	local name, title, notes, loadable, reason, security = C_AddOns.GetAddOnInfo(SourceName)
	if not enabled or (reason ~= nil and reason ~= "" and reason ~= "DEMAND_LOADED") then
		loaded = false
		return
	end
end

------------------------------------------
-- functions

local amount_of = {}
local function Summarize(data, zone)
	LN = LibStub("AceLocale-3.0"):GetLocale("Gathermate2_vDnDNodes", true) -- Workaround LoD of Gathermate2_vDnD if AddonLoader is used.
	for db_type, db_data in pairs(Gathermate2_vDnD.gmdbs) do
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
				local translatednode = Gathermate2_vDnD:GetNameForNode(db_type, node)
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
	if type(Gathermate2_vDnD.gmdbs[db_type]) == "table" then
		node_type = tonumber(node_type)

		-- Find all of the notes
		local zoneID = Routes_vDnD.LZName[zone]
		for loc, t in Gathermate2_vDnD:GetNodesForZone(zoneID, db_type, true) do
			-- And are of a selected type - store
			if t == node_type then
				-- Convert GM2 location to our format
				local x, y, l = Gathermate2_vDnD:DecodeLoc(loc) -- ignore level for now
				local newLoc = Routes_vDnD:getID(x, y)
				tinsert( node_list, newLoc )
			end
		end

		-- return the node_type for auto-adding
		local translatednode = Gathermate2_vDnD:GetNameForNode(db_type, node_type)
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
	local x, y, l = Gathermate2_vDnD:DecodeLoc(coord) -- ignore level for now
	local newCoord = Routes_vDnD:getID(x, y)
	-- Convert zone
	local zoneLocalized = Routes_vDnD.GetZoneName(zone)
	if not zoneLocalized then return end
	Routes_vDnD:InsertNode(zoneLocalized, newCoord, node_name)
end

local function DeleteNode(event, zone, nodeType, coord, node_name)
	-- Convert coords
	local x, y, l = Gathermate2_vDnD:DecodeLoc(coord) -- ignore level for now
	local newCoord = Routes_vDnD:getID(x, y)
	-- Convert zone
	local zoneLocalized = Routes_vDnD.GetZoneName(zone)
	if not zoneLocalized then return end
	Routes_vDnD:DeleteNode(zoneLocalized, newCoord, node_name)
end

local function AddCallbacks()
	Routes_vDnD:RegisterMessage("Gathermate2_vDnDNodeAdded", InsertNode)
	Routes_vDnD:RegisterMessage("Gathermate2_vDnDNodeDeleted", DeleteNode)
end
source.AddCallbacks = AddCallbacks

local function RemoveCallbacks()
	Routes_vDnD:UnregisterMessage("Gathermate2_vDnDNodeAdded")
	Routes_vDnD:UnregisterMessage("Gathermate2_vDnDNodeDeleted")
end
source.RemoveCallbacks = RemoveCallbacks

-- vim: ts=4 noexpandtab
