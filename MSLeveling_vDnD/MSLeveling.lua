-- ============================================================
-- MS Leveling - Group management addon for MS Leveling runs (5-man or 15-man)
-- Author: Bokuden (https://github.com/BokudenWow/MS-Leveling)
-- Target client: WoW 3.3.5a (Ascension private server)
-- ============================================================

local PREFIX = "|cff66b3ff[MSL]|r "

-- Saved variables table (persisted between sessions via SavedVariables in the .toc)
MSLevelingDB = MSLevelingDB or {}
local db = MSLevelingDB

-- Default LFM channel numbers (0 = slot disabled), and own role/aura state
db.channels = db.channels or { 1, 8, 0 }
db.me = db.me or {}

-- Group size presets: pick composition targets by group size instead of a
-- hardcoded 15-man raid. Add more entries here if other sizes are needed.
local GROUP_PRESETS = {
	[5] = { tank = 1, heal = 1, dps = 3, aura = 1 },
	[15] = { tank = 2, heal = 3, dps = 10, aura = 3 },
}
local GROUP_SIZE_CYCLE = { [5] = 15, [15] = 5 }
db.groupSize = db.groupSize or 15

-- Group composition limits, derived from the current preset (see
-- ApplyGroupPreset below). Not local constants anymore since they change
-- when the group size is toggled.
local MAX_TANK, MAX_HEAL, MAX_DPS, MAX_AURA, MAX_TOTAL

local function ApplyGroupPreset()
	local p = GROUP_PRESETS[db.groupSize] or GROUP_PRESETS[15]
	MAX_TANK, MAX_HEAL, MAX_DPS, MAX_AURA = p.tank, p.heal, p.dps, p.aura
	MAX_TOTAL = p.tank + p.heal + p.dps
end
ApplyGroupPreset()

local ROW_HEIGHT = 22
local ROWS_CAND = 8
local ROWS_INV = 9

-- Runtime-only lists (not saved): whisper candidates, and tracked/invited members
local CANDIDATES = {}
local INVITED = {}

-- Role cycle order used when clicking a role button
local ROLE_CYCLE = { Tank = "Heal", Heal = "DPS", DPS = "?", ["?"] = "Tank" }
local ROLE_COLORS = {
	Tank = { 1.0, 0.6, 0.3 },
	Heal = { 0.3, 1.0, 0.5 },
	DPS = { 1.0, 0.85, 0.2 },
	["?"] = { 0.7, 0.7, 0.7 },
}

-- Forward declarations: widgets and handlers are created further down the file,
-- but the event frame below needs to reference them as upvalues before that.
local f, counts, selfRow, selfRoleText, selfAuraText, candScroll, candRows, invScroll, invRows
local HandleWhisper, RefreshStatus, RefreshSelf, PositionMinimap, HandleRaidChat

-- Collection state for the "Load Raid" role-poll flow
local collecting = false
local collectUntil = 0
local memberReplies = {}

local addon = CreateFrame("Frame")
addon:RegisterEvent("CHAT_MSG_WHISPER")
addon:RegisterEvent("CHAT_MSG_RAID")
addon:RegisterEvent("CHAT_MSG_RAID_WARNING")
addon:RegisterEvent("CHAT_MSG_PARTY")
addon:RegisterEvent("GROUP_ROSTER_UPDATE")
addon:RegisterEvent("PLAYER_LOGIN")
addon:SetScript("OnEvent", function(self, event, ...)
	if event == "CHAT_MSG_WHISPER" then
		if HandleWhisper then
			HandleWhisper(...)
		end
	elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_WARNING" or event == "CHAT_MSG_PARTY" then
		if HandleRaidChat then
			HandleRaidChat(...)
		end
	elseif event == "GROUP_ROSTER_UPDATE" then
		if RefreshStatus then
			RefreshStatus()
		end
	elseif event == "PLAYER_LOGIN" then
		if db.framePos and type(db.framePos) == "table" and f then
			f:ClearAllPoints()
			f:SetPoint("TOPLEFT", UIParent, "TOPLEFT", db.framePos[1], db.framePos[2])
		end
		if PositionMinimap then
			PositionMinimap()
		end
		if RefreshSelf then
			RefreshSelf()
		end
	end
end)

-- Returns true if word `w` occurs in `m` as a whole word, using a Lua frontier
-- pattern for correct boundary detection. This replaces the previous manual
-- boundary checks, which had a bug: any word 3+ letters long skipped the
-- boundary check entirely (e.g. "tank" matched inside "tanking").
local function HasWord(m, w)
	return m:find("%f[%a]" .. w .. "%f[%A]") ~= nil
end

-- Role keywords. Spanish variants (tanque, sanador, cura, dano, ...) are kept
-- intentionally: this parses player chat input on a server with a mixed
-- playerbase, not addon code, so it's left as functional data rather than
-- translated/removed.
local function DetectRole(m)
	if HasWord(m, "tank") or HasWord(m, "tanque") or HasWord(m, "tanq") then
		return "Tank"
	end
	if HasWord(m, "heal") or HasWord(m, "healer") or HasWord(m, "sanador") or HasWord(m, "cura") or HasWord(m, "curar") or HasWord(m, "curacion") then
		return "Heal"
	end
	if HasWord(m, "dps") or HasWord(m, "dd") or HasWord(m, "dano") then
		return "DPS"
	end
	return nil
end

-- Detects whether the message mentions aura/buff, and if so, whether it's
-- negated (no/sin/without/wout).
local function DetectAura(m)
	local mentions = HasWord(m, "aura") or HasWord(m, "buff")
	if not mentions then
		return nil
	end
	local neg = HasWord(m, "no") or HasWord(m, "sin") or HasWord(m, "without") or HasWord(m, "wout")
	return not neg
end

-- Returns true if digit `n` occurs in `m` as a standalone number (e.g. "1" does
-- not match inside "10"). Same frontier-pattern fix as HasWord.
local function HasNum(m, n)
	return m:find("%f[%d]" .. n .. "%f[%D]") ~= nil
end

-- Shorthand numeric reply parsing: "1" = Tank, "2" = Heal, "3" = Aura.
-- If both 1 and 2 are present the role is ambiguous, so it's left unset.
local function ParseNumbers(m)
	local t = HasNum(m, "1")
	local h = HasNum(m, "2")
	local a = HasNum(m, "3")
	if t and h then
		return nil, a
	end
	if t then
		return "Tank", a
	end
	if h then
		return "Heal", a
	end
	return nil, a
end

-- Merges a parsed role/aura reply into the poll results for the "Load Raid"
-- flow. Defaults to DPS if no role has ever been given (no reply = DPS).
local function MergeReply(name, role, aura)
	local rep = memberReplies[name]
	if not rep then
		memberReplies[name] = { role = role or "DPS", aura = aura }
		return
	end
	if role then
		rep.role = role
	end
	if aura ~= nil then
		rep.aura = aura
	end
end

-- Counts current roles/auras across yourself + everyone in INVITED.
local function GetCounts()
	local t, h, d, a = 0, 0, 0, 0
	if db.me.role == "Tank" then
		t = t + 1
	elseif db.me.role == "Heal" then
		h = h + 1
	elseif db.me.role == "DPS" then
		d = d + 1
	end
	if db.me.aura then
		a = a + 1
	end
	for _, inv in ipairs(INVITED) do
		if inv.role == "Tank" then
			t = t + 1
		elseif inv.role == "Heal" then
			h = h + 1
		elseif inv.role == "DPS" then
			d = d + 1
		end
		if inv.aura then
			a = a + 1
		end
	end
	return t, h, d, a, 1 + #INVITED
end

local function FindCandidate(name)
	for i, v in ipairs(CANDIDATES) do
		if v.name == name then
			return i, v
		end
	end
end

local function FindInvited(name)
	for _, v in ipairs(INVITED) do
		if v.name == name then
			return v
		end
	end
end

-- Shared row-fill logic for the candidate and invited scroll lists.
-- `showStatus` controls whether the Joined/Pending status text is drawn
-- (only the invited list has it).
local function RefreshRows(list, rows, scroll, numRows, showStatus)
	local num = #list
	FauxScrollFrame_Update(scroll, num, numRows, ROW_HEIGHT)
	local offset = FauxScrollFrame_GetOffset(scroll)
	for i = 1, numRows do
		local row = rows[i]
		local d = list[offset + i]
		if d then
			row:Show()
			row.data = d
			row.name:SetText(d.name)
			row.roleText:SetText(d.role or "?")
			local c = ROLE_COLORS[d.role or "?"]
			row.roleText:SetTextColor(c[1], c[2], c[3])
			row.auraText:SetText(d.aura == nil and "?" or (d.aura and "Aura" or "No"))
			if d.aura then
				row.auraText:SetTextColor(0.3, 1.0, 0.5)
			elseif d.aura == nil then
				row.auraText:SetTextColor(0.7, 0.7, 0.7)
			else
				row.auraText:SetTextColor(0.8, 0.8, 0.8)
			end
			if showStatus then
				if d.status == "Joined" then
					row.status:SetText("In group")
					row.status:SetTextColor(0.3, 1.0, 0.5)
				else
					row.status:SetText("Pending")
					row.status:SetTextColor(1.0, 0.9, 0.3)
				end
			end
		else
			row:Hide()
			row.data = nil
		end
	end
end

local function RefreshCandidates()
	RefreshRows(CANDIDATES, candRows, candScroll, ROWS_CAND, false)
end

local function RefreshInvited()
	RefreshRows(INVITED, invRows, invScroll, ROWS_INV, true)
end

local function CountColor(cur, max)
	if cur >= max then
		return "ff5c5c"
	end
	return "7dff7d"
end

local function RefreshCounts()
	local t, h, d, a, tot = GetCounts()
	counts:SetFormattedText(
		"|cff66b3ffTanks|r |cff%s%d/%d|r   |cff66b3ffHeals|r |cff%s%d/%d|r   |cff66b3ffDPS|r |cff%s%d/%d|r   |cff66b3ffAuras|r |cff%s%d/%d|r   |cff66b3ffTotal|r |cff%s%d/%d|r",
		CountColor(t, MAX_TANK), t, MAX_TANK,
		CountColor(h, MAX_HEAL), h, MAX_HEAL,
		CountColor(d, MAX_DPS), d, MAX_DPS,
		CountColor(a, MAX_AURA), a, MAX_AURA,
		CountColor(tot, MAX_TOTAL), tot, MAX_TOTAL
	)
end

function RefreshSelf()
	local pname = UnitName("player") or "?"
	selfRow.name:SetText("You: " .. pname)
	selfRoleText:SetText(db.me.role or "?")
	local c = ROLE_COLORS[db.me.role or "?"]
	selfRoleText:SetTextColor(c[1], c[2], c[3])
	selfAuraText:SetText(db.me.aura == nil and "?" or (db.me.aura and "Aura" or "No"))
	if db.me.aura then
		selfAuraText:SetTextColor(0.3, 1.0, 0.5)
	elseif db.me.aura == nil then
		selfAuraText:SetTextColor(0.7, 0.7, 0.7)
	else
		selfAuraText:SetTextColor(0.8, 0.8, 0.8)
	end
end

local function RefreshAll()
	RefreshSelf()
	RefreshCounts()
	RefreshCandidates()
	RefreshInvited()
end

-- GetNumRaidMembers() only returns a nonzero value once the group has been
-- converted into an actual raid. A normal 5-man party never shows up there,
-- so group-wide checks need to also look at GetNumPartyMembers().
local function IsGrouped()
	return GetNumPartyMembers() > 0 or GetNumRaidMembers() > 0
end

-- Returns the names of all current group members excluding the player,
-- covering both a plain party and a raid.
local function GetGroupMemberNames()
	local names = {}
	if GetNumRaidMembers() > 0 then
		for i = 1, GetNumRaidMembers() do
			local n = GetRaidRosterInfo(i)
			if n then
				table.insert(names, (n:gsub("%-.*", "")))
			end
		end
	else
		for i = 1, GetNumPartyMembers() do
			local n = UnitName("party" .. i)
			if n then
				table.insert(names, (n:gsub("%-.*", "")))
			end
		end
	end
	return names
end

-- Moves a candidate to the invited list and sends the in-game invite.
local function InvitePlayer(name)
	if FindInvited(name) then
		return
	end
	local idx, cand = FindCandidate(name)
	if not cand then
		return
	end
	table.remove(CANDIDATES, idx)
	table.insert(INVITED, { name = name, role = cand.role or "?", aura = cand.aura, status = "Pending" })
	local ok = pcall(InviteUnit, name)
	if ok then
		print(PREFIX .. "Invited " .. name .. " (" .. (cand.role or "?") .. (cand.aura and " - Aura" or "") .. ")")
	else
		print(PREFIX .. "Could not invite " .. name)
	end
	RefreshAll()
end

-- Starts a 20-second role poll among current raid members (used to figure out
-- roles/auras for a raid that already exists, as opposed to the whisper
-- candidate flow used to fill an empty group).
local function LoadRaid()
	if not IsGrouped() then
		print(PREFIX .. "You are not in a group or raid.")
		return
	end
	wipe(CANDIDATES)
	wipe(INVITED)
	wipe(memberReplies)
	collecting = true
	collectUntil = GetTime() + 20
	-- RAID_WARNING only exists for actual raids and requires assist/lead;
	-- a plain party uses PARTY chat instead.
	local chatType = GetNumRaidMembers() > 0 and "RAID_WARNING" or "PARTY"
	local ok = pcall(SendChatMessage, "MSLeveling: reply with '1' Tank, '2' Heal, '3' Aura (e.g. '1 3'). No reply = DPS without aura.", chatType)
	if not ok then
		print(PREFIX .. "Could not send the announcement (need assist/lead for a raid warning). Continuing to collect replies anyway.")
	end
	RefreshAll()
	print(PREFIX .. "Group/raid poll started: reply in chat with 1 (Tank), 2 (Heal), 3 (Aura), e.g. '1 3'. Collecting for 20s.")
end

-- Finalizes the role poll: rebuilds INVITED from the current raid roster,
-- using each member's poll reply (or DPS/no aura by default), then posts a
-- summary to raid chat.
local function FinalizeCollect()
	collecting = false
	wipe(INVITED)
	local count = 0
	for _, name in ipairs(GetGroupMemberNames()) do
		local rep = memberReplies[name]
		table.insert(INVITED, {
			name = name,
			role = rep and rep.role or "DPS",
			aura = rep and rep.aura or false,
			status = "Joined",
		})
		count = count + 1
	end
	wipe(memberReplies)
	local chatType = GetNumRaidMembers() > 0 and "RAID" or "PARTY"
	local t, h, d, a = GetCounts()
	pcall(SendChatMessage, string.format("MSLeveling: Group ready: {circle}%d Tank {square}%d Heal {skull}%d DPS {triangle}%d Aura", t, h, d, a), chatType)
	local tanks, heals, auras = {}, {}, {}
	local pn = UnitName("player") or "?"
	if db.me.role == "Tank" then
		table.insert(tanks, pn)
	end
	if db.me.role == "Heal" then
		table.insert(heals, pn)
	end
	if db.me.aura then
		table.insert(auras, pn)
	end
	for _, inv in ipairs(INVITED) do
		if inv.role == "Tank" then
			table.insert(tanks, inv.name)
		end
		if inv.role == "Heal" then
			table.insert(heals, inv.name)
		end
		if inv.aura then
			table.insert(auras, inv.name)
		end
	end
	pcall(SendChatMessage, "MSLeveling: Tanks: " .. (#tanks > 0 and table.concat(tanks, ", ") or "none"), chatType)
	pcall(SendChatMessage, "MSLeveling: Heals: " .. (#heals > 0 and table.concat(heals, ", ") or "none"), chatType)
	pcall(SendChatMessage, "MSLeveling: Auras: " .. (#auras > 0 and table.concat(auras, ", ") or "none"), chatType)
	print(PREFIX .. string.format("Group/raid collected: %d players (DPS without aura by default).", count))
	RefreshAll()
end

-- Polls every 0.5s while collecting: finalizes early once everyone in the
-- raid has replied, or after the 20s timeout, whichever comes first.
local timerFrame = CreateFrame("Frame")
timerFrame:Show()
timerFrame:SetScript("OnUpdate", function()
	if not collecting then
		return
	end
	if GetTime() >= collectUntil then
		FinalizeCollect()
		return
	end
	if not timerFrame._nextCheck or GetTime() >= timerFrame._nextCheck then
		timerFrame._nextCheck = GetTime() + 0.5
		local roster = GetGroupMemberNames()
		local allReplied = true
		for _, name in ipairs(roster) do
			if not memberReplies[name] then
				allReplied = false
				break
			end
		end
		if #roster > 0 and allReplied then
			FinalizeCollect()
		end
	end
end)

local function ResetAll()
	wipe(CANDIDATES)
	wipe(INVITED)
	print(PREFIX .. "List reset.")
	RefreshAll()
end

-- Posts an LFM message to up to 3 configured channels. The outgoing message
-- stays fixed wording with no numbers/group size in it; the preview line
-- printed locally still shows current counts for your own reference.
local function BroadcastLFM()
	local msg = "LFM MS. Whisper role (dps/heal/tank), + aura if you got it."
	local t, h, d, a = GetCounts()
	local preview = string.format(
		"|cffffd000[MS Leveling]|r |cff66b3ffLFM sent:|r \"%s\" |cff66b3ff(current: |cff%s%d/%d|r Tank |cff%s%d/%d|r Heal |cff%s%d/%d|r DPS |cff%s%d/%d|r Aura)|r",
		msg,
		CountColor(t, MAX_TANK), t, MAX_TANK,
		CountColor(h, MAX_HEAL), h, MAX_HEAL,
		CountColor(d, MAX_DPS), d, MAX_DPS,
		CountColor(a, MAX_AURA), a, MAX_AURA
	)
	local sent = 0
	local failed = {}
	local channelNames = {}
	local joined = {}
	for i = 1, 50 do
		local name, num = GetChannelList(i)
		if not name then
			break
		end
		channelNames[num] = name
		table.insert(joined, name .. " (" .. num .. ")")
	end
	for i = 1, 3 do
		local ch = db.channels[i]
		if ch and ch > 0 then
			local ok = pcall(SendChatMessage, msg, "CHANNEL", nil, ch)
			if ok then
				sent = sent + 1
			else
				table.insert(failed, tostring(ch) .. (channelNames[ch] and (" (" .. channelNames[ch] .. ")") or ""))
			end
		end
	end
	if sent == 0 and #failed > 0 then
		print(PREFIX .. "LFM not sent: channel" .. (#failed > 1 and "s" or "") .. " " .. table.concat(failed, ", ") .. " failed. Make sure you are joined to them (channel buttons).")
		print(PREFIX .. "Your joined channels: " .. (#joined > 0 and table.concat(joined, ", ") or "none"))
	elseif sent == 0 then
		print(PREFIX .. "Configure at least one LFM channel (channel buttons).")
	else
		print(PREFIX .. preview)
	end
end

-- Keeps the invited list in sync with the actual party/raid roster:
-- 1) updates Joined/Pending status for entries already tracked
-- 2) adds any current group member who isn't tracked yet (e.g. invited
--    manually through the default Blizzard UI, or already grouped before
--    the addon was loaded) so their role/aura can be set by clicking, same
--    as any other row
-- 3) drops candidates who have already joined
function RefreshStatus()
	local rosterNames = GetGroupMemberNames()
	local names = {}
	local pname = UnitName("player")
	if pname then
		names[pname] = true
	end
	for _, n in ipairs(rosterNames) do
		names[n] = true
	end
	local changed = false
	for _, inv in ipairs(INVITED) do
		local st = names[inv.name] and "Joined" or "Pending"
		if st ~= inv.status then
			inv.status = st
			changed = true
		end
	end
	for _, n in ipairs(rosterNames) do
		if not FindInvited(n) then
			table.insert(INVITED, { name = n, role = "?", aura = nil, status = "Joined" })
			changed = true
		end
	end
	for i = #CANDIDATES, 1, -1 do
		if names[CANDIDATES[i].name] then
			table.remove(CANDIDATES, i)
			changed = true
		end
	end
	if changed then
		RefreshAll()
	end
end

local function UpsertCandidate(name, role, aura)
	local idx = FindCandidate(name)
	if idx then
		local c = CANDIDATES[idx]
		if role then
			c.role = role
		end
		if aura ~= nil then
			c.aura = aura
		end
		c.time = GetTime()
	else
		table.insert(CANDIDATES, { name = name, role = role or "?", aura = aura, time = GetTime() })
	end
end

-- Whisper handler. During an active "Load Raid" poll, replies are parsed as
-- role/aura poll answers. Otherwise, whispers add/update whisper candidates.
-- No automatic reply is ever sent back to the whisperer.
function HandleWhisper(msg, author)
	msg = msg or ""
	author = author or "?"
	local m = string.lower(msg)
	local role = DetectRole(m)
	local aura = DetectAura(m)
	local name = author:gsub("%-.*", "")
	if collecting then
		if role == nil or aura == nil then
			local r, a = ParseNumbers(m)
			if not role and r then
				role = r
			end
			if aura == nil and a ~= nil then
				aura = a
			end
		end
		if role or aura then
			MergeReply(name, role, aura)
			local rep = memberReplies[name]
			print(PREFIX .. name .. " replied (" .. rep.role .. (rep.aura and " - Aura" or " - Without aura") .. ")")
		end
		return
	end
	local inv = FindInvited(name)
	if inv then
		if role then
			inv.role = role
		end
		if aura ~= nil then
			inv.aura = aura
		end
		print(PREFIX .. name .. " updated (" .. inv.role .. " - " .. (inv.aura == nil and "?" or (inv.aura and "Aura" or "No")) .. ")")
		RefreshAll()
		return
	end
	local isNew = not FindCandidate(name)
	UpsertCandidate(name, role, aura)
	if isNew then
		local _, c = FindCandidate(name)
		print(PREFIX .. "New candidate: " .. name .. " (" .. (c.role or "?") .. " - " .. (c.aura == nil and "?" or (c.aura and "Aura" or "No")) .. ")")
	end
	RefreshAll()
end

-- Raid/party chat handler, only active during an active poll. Ignores your
-- own messages so you don't accidentally overwrite your own manual role/aura.
function HandleRaidChat(msg, author)
	if not collecting then
		return
	end
	local m = string.lower(msg or "")
	local name = (author or "?"):gsub("%-.*", "")
	local pname = UnitName("player")
	if pname and name == pname:gsub("%-.*", "") then
		return
	end
	local role = DetectRole(m)
	local aura = DetectAura(m)
	if role == nil or aura == nil then
		local r, a = ParseNumbers(m)
		if not role and r then
			role = r
		end
		if aura == nil and a ~= nil then
			aura = a
		end
	end
	if role or aura then
		MergeReply(name, role, aura)
		local rep = memberReplies[name]
		print(PREFIX .. name .. " replied (" .. rep.role .. (rep.aura and " - Aura" or " - Without aura") .. ")")
	end
end

-- Removes a tracked entry from the invited list AND kicks the player from
-- the party/raid (requires assist/lead permission for a raid).
local function RemoveInvited(name)
	for i, inv in ipairs(INVITED) do
		if inv.name == name then
			table.remove(INVITED, i)
			break
		end
	end
	local ok = pcall(UninviteUnit, name)
	if ok then
		print(PREFIX .. name .. " removed from the list and kicked from the group.")
	else
		print(PREFIX .. name .. " removed from the list (could not kick - missing permission, or already gone).")
	end
	RefreshAll()
end

-- Builds one list row. Used for both the candidate list and the invited
-- list; role/aura are always clickable/editable on every row regardless of
-- which list it belongs to. `isCandidate` only controls whether an "Invite"
-- button or a "Kick" button + status text is shown.
local function CreateRow(parent, isCandidate)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(360, ROW_HEIGHT)
	row.bg = row:CreateTexture(nil, "BACKGROUND")
	row.bg:SetAllPoints(row)
	row.bg:SetTexture(1, 1, 1, 0.06)
	row.bg:Hide()
	row:EnableMouse(true)
	row:SetScript("OnEnter", function(self)
		self.bg:Show()
	end)
	row:SetScript("OnLeave", function(self)
		self.bg:Hide()
	end)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.name:SetPoint("LEFT", 2, 0)
	row.name:SetWidth(150)
	row.name:SetJustifyH("LEFT")

	row.role = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.role:SetSize(52, ROW_HEIGHT - 4)
	row.role:SetPoint("LEFT", 154, 0)
	row.roleText = row.role:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.roleText:SetAllPoints(row.role)
	row.roleText:SetJustifyH("CENTER")
	row.roleText:SetJustifyV("MIDDLE")
	row.role:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.role = ROLE_CYCLE[d.role or "?"]
			RefreshAll()
		end
	end)

	row.aura = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.aura:SetSize(56, ROW_HEIGHT - 4)
	row.aura:SetPoint("LEFT", 210, 0)
	row.auraText = row.aura:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.auraText:SetAllPoints(row.aura)
	row.auraText:SetJustifyH("CENTER")
	row.auraText:SetJustifyV("MIDDLE")
	row.aura:SetScript("OnClick", function(self)
		local d = self:GetParent().data
		if d then
			d.aura = not d.aura
			RefreshAll()
		end
	end)

	if isCandidate then
		row.action = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.action:SetSize(68, ROW_HEIGHT - 4)
		row.action:SetPoint("LEFT", 274, 0)
		row.actionText = row.action:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.actionText:SetAllPoints(row.action)
		row.actionText:SetJustifyH("CENTER")
		row.actionText:SetJustifyV("MIDDLE")
		row.actionText:SetText("Invite")
		row.action:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				InvitePlayer(d.name)
			end
		end)
	else
		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.status:SetPoint("LEFT", 262, 0)
		row.status:SetWidth(48)
		row.status:SetJustifyH("LEFT")
		row.kick = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.kick:SetSize(48, ROW_HEIGHT - 4)
		row.kick:SetPoint("LEFT", 312, 0)
		row.kickText = row.kick:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.kickText:SetAllPoints(row.kick)
		row.kickText:SetJustifyH("CENTER")
		row.kickText:SetJustifyV("MIDDLE")
		row.kickText:SetText("Kick")
		row.kick:SetScript("OnClick", function(self)
			local d = self:GetParent().data
			if d then
				RemoveInvited(d.name)
			end
		end)
	end
	return row
end

-- ============================================================
-- Main window
-- ============================================================

f = CreateFrame("Frame", "MSLevelingFrame", UIParent)
f:SetSize(430, 604)
f:SetPoint("CENTER")
f:SetBackdrop({
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
})
f:SetBackdropColor(0, 0, 0, 0.92)
f:SetBackdropBorderColor(0.4, 0.5, 0.7, 0.9)
f:SetFrameStrata("DIALOG")
f:EnableMouse(true)
f:SetMovable(true)
f:RegisterForDrag("LeftButton")
f:SetClampedToScreen(true)
f:SetScript("OnDragStart", function(self)
	self:StartMoving()
end)
f:SetScript("OnDragStop", function(self)
	self:StopMovingOrSizing()
	local _, _, x, y = self:GetPoint(1)
	db.framePos = { x, y }
end)
f:SetScript("OnShow", function()
	RefreshAll()
end)

local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -10)
title:SetText("|cff66b3ffMS Leveling|r")

local closeBtn = CreateFrame("Button", nil, f, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", -5, -5)
closeBtn:SetScript("OnClick", function()
	f:Hide()
end)

counts = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
counts:SetPoint("TOPLEFT", 16, -60)
counts:SetJustifyH("LEFT")

selfRow = CreateFrame("Frame", nil, f)
selfRow:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
selfRow:SetSize(360, ROW_HEIGHT)

selfRow.name = selfRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
selfRow.name:SetPoint("LEFT", 2, 0)
selfRow.name:SetWidth(150)
selfRow.name:SetJustifyH("LEFT")

local selfRole = CreateFrame("Button", nil, selfRow, "UIPanelButtonTemplate")
selfRole:SetSize(52, ROW_HEIGHT - 4)
selfRole:SetPoint("LEFT", 154, 0)
selfRoleText = selfRole:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
selfRoleText:SetAllPoints(selfRole)
selfRoleText:SetJustifyH("CENTER")
selfRoleText:SetJustifyV("MIDDLE")
selfRole:SetScript("OnClick", function()
	db.me.role = ROLE_CYCLE[db.me.role or "?"]
	RefreshAll()
end)

local selfAura = CreateFrame("Button", nil, selfRow, "UIPanelButtonTemplate")
selfAura:SetSize(56, ROW_HEIGHT - 4)
selfAura:SetPoint("LEFT", 210, 0)
selfAuraText = selfAura:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
selfAuraText:SetAllPoints(selfAura)
selfAuraText:SetJustifyH("CENTER")
selfAuraText:SetJustifyV("MIDDLE")
selfAura:SetScript("OnClick", function()
	if db.me.aura == nil then
		db.me.aura = true
	elseif db.me.aura then
		db.me.aura = false
	else
		db.me.aura = nil
	end
	RefreshAll()
end)

local lfmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
lfmBtn:SetSize(110, 22)
lfmBtn:SetPoint("TOPLEFT", 16, -84)
lfmBtn:SetText("Post LFM")
lfmBtn:SetScript("OnClick", BroadcastLFM)

local raidBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
raidBtn:SetSize(95, 22)
raidBtn:SetPoint("LEFT", lfmBtn, "RIGHT", 6, 0)
raidBtn:SetText("Load Raid")
raidBtn:SetScript("OnClick", LoadRaid)

local resetBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
resetBtn:SetSize(70, 22)
resetBtn:SetPoint("LEFT", raidBtn, "RIGHT", 6, 0)
resetBtn:SetText("Reset")
resetBtn:SetScript("OnClick", function()
	StaticPopup_Show("MSLEVELING_RESET")
end)

local groupSizeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
groupSizeBtn:SetSize(90, 22)
groupSizeBtn:SetPoint("LEFT", resetBtn, "RIGHT", 6, 0)
groupSizeBtn:SetText("Group: " .. db.groupSize)
groupSizeBtn:SetScript("OnClick", function(self)
	db.groupSize = GROUP_SIZE_CYCLE[db.groupSize] or 15
	ApplyGroupPreset()
	self:SetText("Group: " .. db.groupSize)
	RefreshAll()
end)

local chLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
chLabel:SetPoint("TOPLEFT", 16, -114)
chLabel:SetText("LFM channels (click to change, 0 = none):")

local chButtons = {}
for i = 1, 3 do
	local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	b:SetSize(36, 20)
	b:SetPoint("TOPLEFT", 16 + (i - 1) * 42, -130)
	b:SetText(tostring(db.channels[i] or 0))
	b:SetScript("OnClick", function(self)
		db.channels[i] = ((db.channels[i] or 0) + 1) % 11
		self:SetText(tostring(db.channels[i]))
	end)
	chButtons[i] = b
end

local candHeader = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
candHeader:SetPoint("TOPLEFT", 16, -158)
candHeader:SetText("Candidates (whispers):")

candScroll = CreateFrame("ScrollFrame", "MSLevelingCandScroll", f, "FauxScrollFrameTemplate")
candScroll:SetPoint("TOPLEFT", 8, -174)
candScroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -174)
candScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 8, -350)
candScroll:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -24, -350)
candScroll:SetScript("OnVerticalScroll", function(self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshCandidates)
end)
candScroll:EnableMouseWheel(true)
candScroll:SetScript("OnMouseWheel", function(self, delta)
	local sb = _G[self:GetName() .. "ScrollBar"]
	sb:SetValue(sb:GetValue() - delta * ROW_HEIGHT)
end)

candRows = {}
for i = 1, ROWS_CAND do
	candRows[i] = CreateRow(f, true)
	candRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -174 - (i - 1) * ROW_HEIGHT)
end

local invHeader = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
invHeader:SetPoint("TOPLEFT", 16, -358)
invHeader:SetText("Invited:")

invScroll = CreateFrame("ScrollFrame", "MSLevelingInvScroll", f, "FauxScrollFrameTemplate")
invScroll:SetPoint("TOPLEFT", 8, -374)
invScroll:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, -374)
invScroll:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 8, -584)
invScroll:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", -24, -584)
invScroll:SetScript("OnVerticalScroll", function(self, offset)
	FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, RefreshInvited)
end)
invScroll:EnableMouseWheel(true)
invScroll:SetScript("OnMouseWheel", function(self, delta)
	local sb = _G[self:GetName() .. "ScrollBar"]
	sb:SetValue(sb:GetValue() - delta * ROW_HEIGHT)
end)

invRows = {}
for i = 1, ROWS_INV do
	invRows[i] = CreateRow(f, false)
	invRows[i]:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -374 - (i - 1) * ROW_HEIGHT)
end

local hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
hint:SetPoint("BOTTOMLEFT", 16, 8)
hint:SetText("Click Role/Aura to edit | /lfms toggles the window")

StaticPopupDialogs["MSLEVELING_RESET"] = {
	text = "Reset the MS Leveling list? Candidates and invited players will be removed.",
	button1 = "Reset",
	button2 = "Cancel",
	timeout = 0,
	whileDead = 1,
	hideOnEscape = 1,
	preferredIndex = 3,
	OnAccept = function()
		ResetAll()
	end,
}

-- ============================================================
-- Minimap button
-- ============================================================

local mm = CreateFrame("Button", "MSLevelingMinimapButton", Minimap)
mm:SetSize(32, 32)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetClampedToScreen(true)

local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetTexture("Interface\\Icons\\spell_holy_guardianspirit")
mmIcon:SetSize(26, 26)
mmIcon:SetPoint("CENTER", mm, "CENTER", 0, -1)

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
mmBorder:SetSize(52, 52)
mmBorder:SetPoint("CENTER", mm, "CENTER", 0, -1)

function PositionMinimap()
	local angle = math.rad(db.minimapPos or 0)
	mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
end

mm:SetScript("OnClick", function()
	if f:IsShown() then
		f:Hide()
	else
		f:Show()
		f:Raise()
	end
end)

mm:SetScript("OnDragStart", function()
	mm:SetScript("OnUpdate", function()
		local x, y = GetCursorPosition()
		local scale = Minimap:GetEffectiveScale()
		x = x / scale
		y = y / scale
		local cx, cy = Minimap:GetCenter()
		local angle = math.atan2(y - cy, x - cx)
		db.minimapPos = math.deg(angle)
		mm:SetPoint("CENTER", Minimap, "CENTER", 80 * math.cos(angle), 80 * math.sin(angle))
	end)
end)

mm:SetScript("OnDragStop", function()
	mm:SetScript("OnUpdate", nil)
end)

-- ============================================================
-- Slash commands
-- ============================================================

SLASH_LFMS1 = "/lfms"
SLASH_LFMS2 = "/msleveling"
SlashCmdList["LFMS"] = function(arg)
	arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if arg == "reset" then
		ResetAll()
	elseif arg == "lfm" then
		BroadcastLFM()
	elseif arg == "raid" then
		LoadRaid()
	else
		if f:IsShown() then
			f:Hide()
		else
			f:Show()
			f:Raise()
		end
	end
end

RefreshAll()
PositionMinimap()
