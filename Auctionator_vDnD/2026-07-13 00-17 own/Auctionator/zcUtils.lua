--[[
	zcUtils.lua

	Zirco's shared utility library ("zc" namespace). Contains no
	addon-specific globals so it can be reused by other addons from the
	same author.
]]

local addonName, addonTable = ...
local zc = {}
addonTable.zc = zc

-----------------------------------------
-- Simple value helpers
-----------------------------------------

-- Returns `ifNilValue` when `value` is nil, otherwise `value`.
function zc.Val(value, ifNilValue)
	if value == nil then
		return ifNilValue
	end
	return value
end

function zc.Min(a, b)
	if a == nil then return b end
	if b == nil then return a end
	return math.min(tonumber(a), tonumber(b))
end

function zc.Max(a, b)
	if a == nil then return b end
	if b == nil then return a end
	return math.max(tonumber(a), tonumber(b))
end

-- Ternary-style helper: returns `whenTrue` if `condition` is truthy, else `whenFalse`.
function zc.If(condition, whenTrue, whenFalse)
	if condition ~= nil and condition ~= false then
		return whenTrue
	end
	return whenFalse
end

function zc.round(value)
	return math.floor(value + 0.5)
end

-----------------------------------------
-- Boolean conversions
-----------------------------------------

function zc.BoolToString(b)
	return b and "true" or "false"
end

function zc.BoolToNum(b)
	return b and 1 or 0
end

function zc.NumToBool(n)
	return n ~= 0
end

-----------------------------------------
-- Frame convenience helpers
-----------------------------------------

function zc.EnableDisable(frame, enabled)
	if enabled then frame:Enable() else frame:Disable() end
end

function zc.ShowHide(frame, shown)
	if shown then frame:Show() else frame:Hide() end
end

function zc.SetTextIf(fontString, condition, textIfTrue, textIfFalse)
	fontString:SetText(condition and textIfTrue or textIfFalse)
end

-----------------------------------------
-- String helpers
-----------------------------------------

function zc.StringSame(a, b)
	if a == nil and b == nil then return true end
	if a == nil or b == nil then return false end
	if a == b then return true end -- fast path, also avoids locale-casing edge cases
	return string.lower(a) == string.lower(b)
end

function zc.StringContains(haystack, needle)
	if needle == nil or needle == "" then
		return false
	end
	return string.find(string.lower(haystack), string.lower(needle), 1, true) ~= nil
end

function zc.StringStartsWith(s, prefix)
	if s == nil or prefix == nil or prefix == "" then
		return false
	end
	local prefixLen = string.len(prefix)
	if string.len(s) < prefixLen then
		return false
	end
	return string.lower(string.sub(s, 1, prefixLen)) == string.lower(prefix)
end

function zc.StringEndsWith(s, suffix)
	if suffix == nil or suffix == "" then
		return false
	end
	local startIndex = string.len(s) - string.len(suffix)
	if startIndex < 0 then
		return false
	end
	return string.lower(string.sub(s, startIndex + 1)) == string.lower(suffix)
end

-- Splits `str` into up to 5 whitespace-separated words (kept small on
-- purpose: this addon never needs more than a command + a few arguments).
-- Returns a table instead if there are more than 5 words.
function zc.words(str)
	local words = {}

	local function collect(word)
		table.insert(words, word)
		return ""
	end

	if not str:gsub("%w+", collect):find("%S") then
		local count = #words
		if count == 1 then return words[1] end
		if count == 2 then return words[1], words[2] end
		if count == 3 then return words[1], words[2], words[3] end
		if count == 4 then return words[1], words[2], words[3], words[4] end
		if count == 5 then return words[1], words[2], words[3], words[4], words[5] end
		return words
	end
end

-- Truncates a UTF-8 string to at most `maxLength` bytes without splitting
-- a multi-byte character in half.
function zc.UTF8_Truncate(s, maxLength)
	if s:len() <= maxLength then
		return s
	end

	for i = maxLength, 1, -1 do
		local byte = s:byte(i + 1)
		if bit.band(byte, 0xC0) == 0x80 then -- continuation byte, keep looking backwards
			return s:sub(1, i - 1)
		end
	end
end

-----------------------------------------
-- Base64-style compact number encoding (used for SavedVariables packing)
-----------------------------------------

local ENCODE_ALPHABET = {
	"A","B","C","D","E","F","G","H","I","J","K","L","M","N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
	"a","b","c","d","e","f","g","h","i","j","k","l","m","n","o","p","q","r","s","t","u","v","w","x","y","z",
	"0","1","2","3","4","5","6","7","8","9",
	"-", "_",
}

local decodeAlphabet

local function buildDecodeAlphabet()
	if decodeAlphabet == nil then
		decodeAlphabet = {}
		for i = 1, 64 do
			decodeAlphabet[ENCODE_ALPHABET[i]] = i - 1
		end
	end
end

function zc.enc64(n)
	if n == 0 then
		return ENCODE_ALPHABET[1]
	end

	local result = ""
	while n ~= 0 do
		local chunk = bit.band(n, 63)
		result = ENCODE_ALPHABET[chunk + 1] .. result
		n = bit.rshift(n, 6)
	end

	return result
end

function zc.dec64(s)
	if s == nil or s == "" then
		return 0
	end

	buildDecodeAlphabet()

	local result = 0
	for i = 1, string.len(s) do
		result = (result * 64) + decodeAlphabet[string.sub(s, i, i)]
	end

	return result
end

-----------------------------------------
-- Deferred call queue (simple cooperative scheduler)
-----------------------------------------

local pendingDeferredCalls = {}

-- Schedules `funcname` (a GLOBAL function name, looked up via _G) to run
-- after `seconds`. If `tag` is given, any existing pending call with the
-- same tag is replaced instead of adding a second one.
function zc.AddDeferredCall(seconds, funcname, param1, param2, tag)

	local call = {
		funcname = funcname,
		param1   = param1,
		param2   = param2,
		when     = time() + seconds,
		tag      = tag or "",
	}

	if tag then
		for i = 1, #pendingDeferredCalls do
			if pendingDeferredCalls[i].tag == tag then
				pendingDeferredCalls[i] = call
				return
			end
		end
	end

	table.insert(pendingDeferredCalls, call)
end

-- Runs at most one due deferred call per invocation (called from the
-- addon's OnUpdate handler).
function zc.CheckDeferredCall()

	local now = time()

	for i = 1, #pendingDeferredCalls do
		if pendingDeferredCalls[i].when < now then
			local call = table.remove(pendingDeferredCalls, i)
			local fn = _G[call.funcname]
			if type(fn) == "function" then
				fn(call.param1, call.param2)
			end
			return -- only run one per call
		end
	end
end

-- Returns true once every `period` seconds, using `elem[name]` as the
-- accumulator. Typical use: `if zc.periodic(self, "myTimer", 0.2, elapsed) then ... end`.
function zc.periodic(elem, name, period, elapsed)

	local elapsedTotal = (elem[name] or 0) + elapsed

	if elapsedTotal > period then
		elem[name] = 0
		return true
	end

	elem[name] = elapsedTotal
	return false
end

-----------------------------------------
-- Table helpers
-----------------------------------------

function zc.tableIsEmpty(t)
	return next(t) == nil
end

function zc.CopyDeep(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = (type(value) == "table") and zc.CopyDeep(value) or value
	end
	return result
end

function zc.GetArrayElemOrFirst(array, index)
	if array and #array > 0 then
		if index == nil or index < 1 or index > #array then
			index = 1
		end
		return array[index]
	end
	return nil
end

function zc.GetArrayElemOrNil(array, index)
	if array and #array > 0 and index and index >= 1 and index <= #array then
		return array[index]
	end
	return nil
end

function zc.padstring(s, minLength, padChar)
	while string.len(s) < minLength do
		s = padChar .. s
	end
	return s
end

-- Simple frequency counter, e.g. zc.tallyAdd(counts, "Strange Dust").
function zc.tallyAdd(tally, value)
	tally[value] = (tally[value] or 0) + 1
end

-- Prints a frequency table sorted by count (or by value, see options).
-- options: { sortByValue, sortDesc, printCount }
function zc.tallyPrint(tally, options)

	local sorted = {}
	local total = 0

	for value, count in pairs(tally) do
		table.insert(sorted, { value = value, count = count })
		total = total + count
	end

	if options.sortByValue and options.sortDesc then
		table.sort(sorted, function(x, y) return x.value > y.value end)
	elseif options.sortByValue then
		table.sort(sorted, function(x, y) return x.value < y.value end)
	elseif options.sortDesc then
		table.sort(sorted, function(x, y) return x.count > y.count end)
	else
		table.sort(sorted, function(x, y) return x.count < y.count end)
	end

	for i = 1, #sorted do
		if not options.printCount or i < options.printCount then
			zc.msg_pink(sorted[i].count .. "    " .. sorted[i].value)
		end
	end

	zc.msg_yellow("Total: " .. total)
end

-----------------------------------------
-- Item link parsing
-----------------------------------------

-- Extracts itemId, suffixId and uniqueId from an item link/string.
function zc.ItemIDfromLink(itemLink)
	if itemLink == nil then
		return 0, 0, 0
	end

	local _, _, itemString = string.find(itemLink, "^|c%x+|H(.+)|h%[.*%]")
	local _, itemId, _, _, _, _, _, suffixId, uniqueId = strsplit(":", itemString)

	return itemId, suffixId, uniqueId
end

function zc.printableLink(link)
	if link == nil then
		return "nil"
	end
	return gsub(link, "\124", "\124\124")
end

-----------------------------------------
-- Color math
-----------------------------------------

function zc.RGBtoHEX(r, g, b)
	return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
end

function zc.HSV2RGB(h, s, v)

	local hueSegment = math.floor(h / 60) % 6
	local f = h / 60 - math.floor(h / 60)
	local p = v * (1 - s)
	local q = v * (1 - (f * s))
	local t = v * (1 - ((1 - f) * s))

	if hueSegment == 0 then return v, t, p end
	if hueSegment == 1 then return q, v, p end
	if hueSegment == 2 then return p, v, t end
	if hueSegment == 3 then return p, q, v end
	if hueSegment == 4 then return t, p, v end
	return v, p, q -- hueSegment == 5
end

-----------------------------------------
-- Money formatting
-----------------------------------------

local function copperToGoldSilverCopper(copperValue)
	local rounded = zc.round(copperValue)
	local gold = math.floor(rounded / 10000)
	rounded = rounded - (gold * 10000)
	local silver = math.floor(rounded / 100)
	local copper = rounded - (silver * 100)
	return gold, silver, copper
end

-- Plain-text "1g 2s 3c" style formatting.
function zc.priceToString(copperValue)

	local gold, silver, copper = copperToGoldSilverCopper(copperValue)
	local result = ""

	if gold ~= 0 then
		result = gold .. "g "
	end

	if result ~= "" then
		result = result .. format("%02is ", silver)
	elseif silver ~= 0 then
		result = result .. silver .. "s "
	end

	if result ~= "" then
		result = result .. format("%02ic", copper)
	elseif copper ~= 0 then
		result = result .. copper .. "c"
	end

	return result
end

local GOLD_ICON   = "|TInterface\\MoneyFrame\\UI-GoldIcon:12:12:4:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:12:12:4:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:12:12:4:0|t"

-- Icon-based money formatting, as used in tooltips.
function zc.priceToMoneyString(copperValue, hideZeroCopper)

	local gold, silver, copper = copperToGoldSilverCopper(copperValue)
	local result = ""

	if gold ~= 0 then
		result = gold .. GOLD_ICON .. "  "
	end

	if result ~= "" then
		result = result .. format("%02i%s  ", silver, SILVER_ICON)
	elseif silver ~= 0 then
		result = result .. silver .. SILVER_ICON .. "  "
	end

	if hideZeroCopper and copper == 0 then
		return result
	end

	if result ~= "" then
		result = result .. format("%02i%s", copper, COPPER_ICON)
	elseif copper ~= 0 then
		result = result .. copper .. COPPER_ICON
	end

	return result
end

-----------------------------------------
-- Chat output
-----------------------------------------

function zc.msg_red(...)    zc.msg_color(1, 0, 0, ...) end
function zc.msg_pink(...)   zc.msg_color(1, .6, .6, ...) end
function zc.msg_yellow(...) zc.msg_color(1, 1, 0, ...) end

function zc.msg_color(r, g, b, ...)
	zc.msg_ex({ r = r, g = g, b = b }, ...)
end

-- Builds the message string without printing it (used to compare two
-- states for "did anything change" checks, e.g. before/after saving options).
function zc.msg_str(...)
	return zc.msg_ex({ str = true }, ...)
end

function zc.msg_atr(...)
	zc.msg_yellow("|cff00ffff<Auctionator>|r", ...)
end

function zc.msg(...)
	zc.msg_ex({}, ...)
end

function zc.msg_ex(options, ...)

	if not DEFAULT_CHAT_FRAME then
		return
	end

	local msg = ""
	local argCount = select("#", ...)

	for i = 1, argCount do
		local value = select(i, ...)
		local part

		if type(value) == "boolean" then
			part = zc.BoolToString(value)
		elseif type(value) == "table" then
			part = "<table>"
		elseif type(value) == "function" then
			part = "<function>"
		elseif value == nil then
			part = "<nil>"
		else
			part = value
		end

		msg = msg .. " " .. part
	end

	if options.str then
		return msg
	end

	if options.r ~= nil then
		DEFAULT_CHAT_FRAME:AddMessage(msg, options.r, options.g, options.b)
	else
		DEFAULT_CHAT_FRAME:AddMessage(msg)
	end
end

function zc.printmem()
	local luaMemoryKB = math.floor(collectgarbage("count"))
	UpdateAddOnMemoryUsage()
	local addonMemoryKB = GetAddOnMemoryUsage("Auctionator")
	zc.msg_atr(math.floor(addonMemoryKB) .. " KB  (total LUA: " .. luaMemoryKB .. " KB)")
end

-----------------------------------------
-- Debug helpers (only active while Atr_IsDev is set)
-----------------------------------------

-- Color-codes a chat message based on which Auctionator function called it,
-- to make debug spam easier to visually distinguish while developing.
function zc.md(...)

	if not Atr_IsDev then
		return
	end

	local callStack = zc.printstack({ silent = true })
	local callerName = string.lower(callStack[2])

	if zc.StringStartsWith(callerName, "atr_") then
		callerName = callerName:sub(5)
	end

	local color = "ffffff"
	local nameLength = callerName:len()

	if nameLength > 3 then
		local x = callerName:byte(math.floor(nameLength / 2)) - string.byte("a")
		local y = callerName:byte(nameLength) - string.byte("a")

		local hue = (x > 0) and math.floor((x / 26) * 360) or 0
		local saturation = (y > 0) and (0.3 + (y / 26) * 0.7) or 0.5

		local r, g, b = zc.HSV2RGB(hue, saturation, 1)
		color = string.format("%02x%02x%02x", math.floor(r * 255), math.floor(g * 255), math.floor(b * 255))
	end

	zc.msg("|cff00ffff<" .. "|cff" .. color .. callerName .. "|cff00ffff>|r", ...)
end

function zc.printstack(options)

	options = options or {}

	local resultLine = options.prefix or ""
	local callerNames = {}

	local stackLines = { strsplit("\n", debugstack(2)) }

	local depth = 1
	for _, line in pairs(stackLines) do

		local fileName, funcName

		local fileStart, fileEnd = string.find(line, "\\[^\\]*:")
		if fileStart then
			fileName = string.sub(line, fileStart + 1, fileEnd - 1)
			fileName = string.gsub(fileName, "\\.lua", "")
		end

		local funcStart, funcEnd = string.find(line, "in function `.*\'")
		if funcStart then
			funcName = string.sub(line, funcStart + 13, funcEnd - 1)
			table.insert(callerNames, funcName)
		end

		if options.verbose then
			if fileName and funcName then
				local columnWidth = math.floor((100 - string.len(funcName)) / 2)
				local format_ = "%-" .. columnWidth .. "s (%s)"
				zc.msg_color(.5, 1, .5, string.format(format_, funcName, fileName))
			else
				zc.msg(line)
			end
		elseif not options.silent and funcName then
			if depth == 2 then
				resultLine = resultLine .. " > |cFFFFaa88" .. funcName
			else
				resultLine = resultLine .. " > " .. funcName
			end
			depth = depth + 1
		end
	end

	if not options.verbose and not options.silent then
		zc.msg(resultLine)
	end

	return callerNames
end

function zc.PrintTable(t, indent)

	indent = indent or 0
	local padding = string.rep("  ", indent)

	zc.msg("-------")

	for key, value in pairs(t) do
		if type(value) == "table" then
			zc.msg(padding .. key, "TABLE")
			zc.PrintTable(value, indent + 1)
		elseif type(value) == "userdata" then
			zc.msg(padding .. key, "userdata")
		else
			zc.msg(padding .. key, value)
		end
	end
end

function zc.PrintKeysSorted(t)

	local keys = {}
	for key in pairs(t) do
		table.insert(keys, key)
	end

	table.sort(keys, function(a, b) return a:lower() < b:lower() end)

	for i = 1, #keys do
		zc.msg_pink(i .. "   " .. keys[i])
	end
end
