-- =============================================================
-- EmberHeal Init — events, ticker, slash commands (Emberveil)
-- Event/OnUpdate argument shapes vary on this client, so every
-- handler resolves its inputs at runtime and the ticker uses
-- GetTime() deltas instead of the elapsed argument.
-- =============================================================

local EV = EVH
local GetTime = GetTime

local function resolveEvent(a, b)
	if type(a) == "string" then return a end
	if type(b) == "string" then return b end
	if type(event) == "string" then return event end
	return nil
end

local function rosterChanged()
	if not EV.db() then return end
	EV.buildRoster()
	EV.rebuildLayout()
	EV.refreshAll()
end

local function onEvent(a, b)
	local ev = resolveEvent(a, b)
	if not ev then return end
	if ev == "VARIABLES_LOADED" then
		EV.loadDB()
		EV.buildRoster()
		EV.buildAll()
		EV.refreshAll()
		EV.applyMiddleCast()
		EV.echo((EV.L.title or "EmberHeal") .. " " .. (EV.VERSION or "?") .. " 已加载 / loaded")
	elseif ev == "PLAYER_ENTERING_WORLD" then
		if EV.db() then
			EV.buildRoster()
			EV.rebuildLayout()
			EV.refreshAll()
		end
	elseif ev == "RAID_ROSTER_UPDATE" or ev == "PARTY_MEMBERS_CHANGED"
		or ev == "GROUP_ROSTER_UPDATE" then
		rosterChanged()
	elseif ev == "UNIT_AURA" or ev == "UNIT_HEALTH" or ev == "UNIT_MAXHEALTH"
		or ev == "UNIT_MANA" or ev == "UNIT_MAXMANA"
		or ev == "UNIT_TARGET" or ev == "PLAYER_TARGET_CHANGED" then
		-- handled by the throttled ticker
	elseif ev == "SPELLS_CHANGED" then
		if EV.db() then EV.refreshOptions() end
	end
end

local eventFrame = CreateFrame("Frame", "EVH_EventFrame")
do
	local events = {
		"VARIABLES_LOADED", "PLAYER_ENTERING_WORLD",
		"RAID_ROSTER_UPDATE", "PARTY_MEMBERS_CHANGED", "GROUP_ROSTER_UPDATE",
		"UNIT_AURA", "UNIT_HEALTH", "UNIT_MAXHEALTH",
		"UNIT_MANA", "UNIT_MAXMANA", "UNIT_TARGET", "PLAYER_TARGET_CHANGED",
		"SPELLS_CHANGED",
	}
	for _, e in ipairs(events) do
		pcall(eventFrame.RegisterEvent, eventFrame, e)
	end
end
eventFrame:SetScript("OnEvent", function(a, b)
	local ok, err = pcall(onEvent, a, b)
	if not ok then
		EV.echo("event error: " .. tostring(err))
	end
end)

-- throttled ticker: refresh visible grid
local lastUI = 0
local lastRoster = 0
eventFrame:SetScript("OnUpdate", function()
	local now = GetTime()
	if now - lastUI >= 0.3 then
		lastUI = now
		if EV.db() and EV.grid then
			EV.refreshAll()
			if now - lastRoster >= 3 then
				lastRoster = now
				if EV.rosterCount() == 0 and (GetNumRaidMembers() > 0 or GetNumPartyMembers() > 0) then
					EV.buildRoster()
					EV.rebuildLayout()
				end
			end
		end
	end
end)

-- -------------------------------------------------------------
-- Slash commands
-- -------------------------------------------------------------
local function slashCmd(msg)
	msg = string.gsub(string.lower(msg or ""), "^%s*(.-)%s*$", "%1")
	if not EV.db() then EV.loadDB() end
	if msg == "opts" or msg == "opt" or msg == "options" then
		EV.toggleOptions()
		return
	elseif msg == "lock" then
		EV.db().opts.locked = (EV.db().opts.locked == 1) and 0 or 1
		EV.echo(EV.L.locked .. " = " .. (EV.db().opts.locked == 1 and EV.L.on or EV.L.off))
		EV.refreshOptions()
		return
	elseif msg == "reset" then
		EV.resetPositions()
		EV.rebuildLayout()
		EV.echo(EV.L.resetPos)
		return
	elseif msg == "test" then
		EV.setTestMode(not EV.testMode)
		EV.refreshAll()
		EV.echo(EV.L.testMode .. " = " .. (EV.testMode and EV.L.on or EV.L.off))
		return
	elseif msg == "clickdebug" then
		local o = EV.db().opts
		o.clickDebug = (o.clickDebug == 1) and 0 or 1
		EVH.clickDebug = (o.clickDebug == 1)
		EV.echo(EV.L.clickDbg .. " = " .. (EVH.clickDebug and EV.L.on or EV.L.off))
		return
	elseif msg == "diag" then
		local d = EV.db().diag or {}
		EV.echo("diag: " .. #d .. " entries (written to SavedVariables on logout/reload)")
		for i = math.max(1, #d - 9), #d do
			if d[i] then EV.echo(d[i]) end
		end
		return
	elseif msg == "diagclear" then
		EV.db().diag = {}
		EV.echo("diag: cleared")
		return
	elseif msg == "size" then
		local o = EV.db().opts
		o.barSize = ((o.barSize or 2) % 3) + 1
		EV.rebuildLayout()
		EV.echo(EV.L.barSize .. " = " .. o.barSize)
		return
	elseif msg == "scale" then
		local o = EV.db().opts
		local seq = { [0.8] = 1.0, [1.0] = 1.2, [1.2] = 1.4, [1.4] = 0.8 }
		o.scale = seq[o.scale] or 1.0
		EV.rebuildLayout()
		EV.echo(EV.L.scale .. " = " .. string.format("%.1f", o.scale))
		return
	elseif msg == "help" then
		EV.echo(EV.L.help)
		return
	end
	-- default: toggle healing grid
	EV.toggleGrid()
end

SlashCmdList["EMBERHEAL"] = slashCmd
SlashCmdList["EVH"] = slashCmd
-- alias globals first, then the handler: some engines snapshot SLASH_*
-- when the handler is registered, others when the global appears
setglobal("SLASH_EMBERHEAL1", "/emberheal")
setglobal("SLASH_EH1", "/eh")
setglobal("SLASH_EVH1", "/evh")

-- /ehrun <lua>: evaluate one line of Lua in the addon's environment and
-- echo the first three return values -- remote diagnostics without needing
-- a chat-log transcription. Kept case-sensitive (slashCmd lowercases).
SlashCmdList["EHRUN"] = function(msg)
	msg = string.gsub(msg or "", "^%s*(.-)%s*$", "%1")
	if msg == "" then
		EV.echo("/ehrun <lua code>  (result of the first 3 returns is echoed)")
		return
	end
	local f, cerr = loadstring(msg)
	if not f then
		EV.echo("ehrun compile err: " .. tostring(cerr))
		return
	end
	local ok, r1, r2, r3 = pcall(f)
	if EV.diag then EV.diag("ehrun: " .. msg .. " => " .. tostring(r1) .. " " .. tostring(r2) .. " " .. tostring(r3)) end
	EV.echo("ehrun ok=" .. tostring(ok)
		.. " r1=" .. tostring(r1) .. " r2=" .. tostring(r2) .. " r3=" .. tostring(r3))
end
setglobal("SLASH_EHRUN1", "/ehrun")
