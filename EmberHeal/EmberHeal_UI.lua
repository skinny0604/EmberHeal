-- =============================================================
-- EmberHeal UI — healing grid, unit buttons, options panel
-- Conventions (from EmberBless):
--   * This client ships almost no usable icon textures (missing
--     textures render as green blocks) -> indicators are CJK glyphs
--     + WHITE8X8 colored squares instead of icon textures.
--   * Scaling is PURELY GEOMETRIC (frame:SetScale has anchor quirks):
--     every metric is multiplied by the scale at layout time.
--   * Child frames (StatusBar etc.) paint OVER all of their parent's own
--     textures/fontstrings -> per-button text & markers live on a dedicated
--     transparent overlay frame stacked above the health bar.
-- =============================================================

local EV = EVH
local _G = _G
local floor = math.floor
local strformat = string.format

local L = EV.L
local db

local FONT_PATH, FONT_SIZE
local BAR_SIZES = {
	[1] = { w = 72,  h = 20 },
	[2] = { w = 92,  h = 26 },
	[3] = { w = 120, h = 34 },
}

EVH.grid = nil
EVH.optionsFrame = nil
EVH.minimapBtn = nil

-- -------------------------------------------------------------
-- widget helpers
-- -------------------------------------------------------------
local function hexc(r, g, b)
	return strformat("|cff%02x%02x%02x", floor(r * 255 + 0.5), floor(g * 255 + 0.5), floor(b * 255 + 0.5))
end

-- This engine draws a frame's SetBackdrop ON TOP of its child frames,
-- so panels get a separate skin frame rendered behind the content frame.
local function skinFrame(f, strata, bgA, br, bgg, bb)
	local okN, baseName = pcall(f.GetName, f)
	local skin = CreateFrame("Frame", (okN and baseName) and (baseName .. "Skin") or nil, UIParent)
	-- (1.0.20) INPUT EATER: on this client a plain Frame is mouse-enabled by
	-- default and swallows hover/click/drag for everything underneath (EH_Grid
	-- documents the same trap: 必须 EnableMouse(false)，否则"点不动、拖不动、
	-- hover 不出气泡"). The skin is a pure visual overlay → make it click-through.
	pcall(skin.EnableMouse, skin, false)
	skin:SetFrameStrata(strata)
	skin:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
	skin:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
	local bg = skin:CreateTexture(nil, "BACKGROUND")
	bg:SetTexture(0.04, 0.04, 0.06, bgA)
	bg:SetAllPoints(skin)
	local edges = {}
	for i = 1, 4 do
		local t = skin:CreateTexture(nil, "BORDER")
		t:SetTexture(br, bgg, bb, 1)
		edges[i] = t
	end
	edges[1]:SetPoint("TOPLEFT", skin, "TOPLEFT", 0, 0)
	edges[1]:SetPoint("TOPRIGHT", skin, "TOPRIGHT", 0, 0)
	edges[1]:SetHeight(1)
	edges[2]:SetPoint("BOTTOMLEFT", skin, "BOTTOMLEFT", 0, 0)
	edges[2]:SetPoint("BOTTOMRIGHT", skin, "BOTTOMRIGHT", 0, 0)
	edges[2]:SetHeight(1)
	edges[3]:SetPoint("TOPLEFT", skin, "TOPLEFT", 0, 0)
	edges[3]:SetPoint("BOTTOMLEFT", skin, "BOTTOMLEFT", 0, 0)
	edges[3]:SetWidth(1)
	edges[4]:SetPoint("TOPRIGHT", skin, "TOPRIGHT", 0, 0)
	edges[4]:SetPoint("BOTTOMRIGHT", skin, "BOTTOMRIGHT", 0, 0)
	edges[4]:SetWidth(1)
	f.evhSkin = skin
	skin:Hide()
	pcall(f.HookScript, f, "OnShow", function() skin:Show() end)
	pcall(f.HookScript, f, "OnHide", function() skin:Hide() end)
	return skin
end

local function syncSkin(f)
	local s = f.evhSkin
	if not s then return end
	local ok, shown = pcall(f.IsShown, f)
	if ok and shown then s:Show() else s:Hide() end
end
EV.syncSkin = syncSkin

local function styleButton(b)
	if not b.evhBG then
		local bg = b:CreateTexture(nil, "BACKGROUND")
		bg:SetTexture(0.16, 0.16, 0.16, 0.72)
		bg:SetAllPoints(b)
		b.evhBG = bg
	end
end

local function setBtnText(b, text, r, g, bl)
	text = text or ""
	if r then text = hexc(r, g, bl) .. text .. "|r" end
	if b.evhLab then b.evhLab:SetText(text) end
	pcall(b.SetText, b, "")
end

local function mkButton(parent, name, w, h, text, onClick)
	local b = CreateFrame("Button", name, parent)
	b:SetWidth(w)
	b:SetHeight(h)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	-- this engine gates ALL mouse input behind EnableMouse (unrealUI calls it
	-- "the verified input gate"): a Button without it is click-through
	pcall(b.EnableMouse, b, true)
	if onClick then b:SetScript("OnClick", onClick) end
	styleButton(b)
	local lab = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	lab:SetPoint("CENTER", b, "CENTER", 0, 0)
	b.evhLab = lab
	setBtnText(b, text)
	return b
end

local function mkText(parent, name, w, h, justify)
	local fs = parent:CreateFontString(name, "OVERLAY", "GameFontNormalSmall")
	fs:SetWidth(w)
	fs:SetHeight(h)
	fs:SetJustifyH(justify or "CENTER")
	return fs
end

local function tip(frameObj, anchor, build)
	frameObj:SetScript("OnEnter", function()
		GameTooltip:SetOwner(frameObj, anchor or "ANCHOR_RIGHT")
		build(GameTooltip)
		GameTooltip:Show()
	end)
	frameObj:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- -------------------------------------------------------------
-- Unit button template
-- -------------------------------------------------------------
local function buildUnitButton(i)
	local g = EVH.grid
	local b = CreateFrame("Button", "EVH_Unit" .. i, g.GridFrame)
	-- register the bindable mouse buttons shown on the clicks page;
	-- unregistered buttons never fire OnClick, so e.g. middle click did nothing.
	-- Down variants included too: some engines key OnClick off the DOWN type.
	b:RegisterForClicks("LeftButtonUp", "MiddleButtonUp", "RightButtonUp")
	pcall(b.RegisterForClicks, b,
		"LeftButtonUp", "MiddleButtonUp", "RightButtonUp",
		"MiddleButtonDown", "Button4Up", "Button5Up", "Button4Down", "Button5Down")
	-- INPUT GATE (1.0.18): this engine delivers no mouse events to a Button
	-- until EnableMouse(true) -- see unrealUI core/widgets.lua ("the verified
	-- input gate used throughout unrealUI") and EvalHelp's buttons. Without
	-- it the unit buttons were click-through and every click landed on the
	-- grid's drag handler instead.
	pcall(b.EnableMouse, b, true)
	-- (1.0.19) raise above unrealUI's bottom-center panels: a MEDIUM-strata
	-- frame under one of those never sees hover OR click
	pcall(b.SetFrameStrata, b, "HIGH")
	if i == 1 and EVH.diag then
		local okM, en = pcall(b.IsMouseEnabled, b)
		EVH.diag("unitBtn1 built mouseEnabled=" .. tostring(okM and tostring(en) or "?"))
	end
	-- this engine may still fire OnClick ONLY for left/right even when middle
	-- is registered -> catch MiddleButton/Button4/Button5 in OnMouseUp too.
	-- Mouse scripts can lack formal args here, so read the arg1 global.
	-- fireUnitClick dedupes so the two paths never cast twice.
	local lastClickBtn, lastClickT = nil, 0
	local lastHover = nil
	local function fireUnitClick(btnName)
		if not btnName then return end
		local now = (GetTime and GetTime() or 0)
		if btnName == lastClickBtn and (now - lastClickT) < 0.25 then return end
		lastClickBtn, lastClickT = btnName, now
		if EVH.clickDebug then EV.dbug("dbg click: " .. btnName) end
		EV.diag("rawclick btn=" .. tostring(btnName)
			.. " unit=" .. tostring(b.evhMember and b.evhMember.unit)
			.. " name=" .. tostring(b.evhMember and b.evhMember.name))
		EV.handleUnitClick(b, btnName, btnName)
	end
	local onUnitClick = function(a1)
		EV.diag("ubtn onclick a1=" .. tostring(a1) .. " arg1=" .. tostring(arg1))
		fireUnitClick(EV.resolveButton(a1, arg1))
	end
	local onUnitMouseUp = function(a1)
		local a = (type(a1) == "string" and a1) or arg1
		EV.diag("ubtn mouseup a1=" .. tostring(a1) .. " arg1=" .. tostring(arg1))
		if EVH.clickDebug then
			local gmc = "no api"
			if GetMouseButtonClicked then
				local okG, g = pcall(GetMouseButtonClicked)
				if okG then gmc = tostring(g) end
			end
			EV.dbug("dbg mouseup: a1=" .. tostring(a1) .. " arg1=" .. tostring(arg1) .. " gmc=" .. gmc)
		end
		if not a and GetMouseButtonClicked then
			local okG, g = pcall(GetMouseButtonClicked)
			if okG and type(g) == "string" then a = g end
		end
		if a == "LeftButton" or a == "RightButton" or a == "MiddleButton"
		   or a == "Button4" or a == "Button5" then
			fireUnitClick(a)
		end
	end
	b:SetScript("OnMouseDown", function(a1)
		EV.diag("ubtn mousedown a1=" .. tostring(a1) .. " arg1=" .. tostring(arg1))
	end)
	local onUnitLeave = function() GameTooltip:Hide() end
	b:SetScript("OnClick", onUnitClick)
	b:SetScript("OnMouseUp", onUnitMouseUp)
	local onUnitEnter = function()
		local m = b.evhMember
		EV.diag("ubtn enter member=" .. tostring(m and m.name) .. " unit=" .. tostring(m and m.unit))
		if not m then return end
		if lastHover ~= m.name then
			lastHover = m.name
		end
		GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
		local r, gg, bl = EV.classColor(m.class)
		GameTooltip:SetText(m.name or "?", r, gg, bl)
		GameTooltip:AddLine(strformat("%d / %d (%.0f%%)", m.hp or 0, m.max or 0, m.pct or 0), 0.7, 1, 0.7)
		if m.dead then GameTooltip:AddLine(L.uDead, 1, 0.3, 0.3) end
		if m.offline then GameTooltip:AddLine(L.uOffline, 0.5, 0.5, 0.5) end
		if m.oor then GameTooltip:AddLine(L.uOor, 0.7, 0.7, 0.7) end
		if m.aggro then GameTooltip:AddLine(L.uAggro, 1, 0.3, 0.3) end
		if m.debuffs then
			for _, d in ipairs(m.debuffs) do
				local dr, dg, dbl = EV.dispelColor(d.dispel)
				GameTooltip:AddLine(L.uDebuff .. tostring(d.dispel or "?"), dr, dg, dbl)
			end
		end
		local slot = EV.bindFor("LeftButton", "")
		if slot then
			local n = EV.slotName(slot)
			GameTooltip:AddLine(L.clickLeft .. ": " .. tostring(n or L.slotColon .. slot), 0.8, 0.8, 1)
		end
		GameTooltip:Show()
	end
	b:SetScript("OnEnter", onUnitEnter)
	b:SetScript("OnLeave", onUnitLeave)

	-- health bar background
	local barBg = b:CreateTexture(nil, "BACKGROUND")
	barBg:SetTexture(0.06, 0.06, 0.06, 0.9)
	barBg:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
	barBg:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	b.barBg = barBg

	-- health bar
	local bar = CreateFrame("StatusBar", "EVH_Unit" .. i .. "Bar", b)
	bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
	bar:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
	bar:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	b.bar = bar
	-- this engine may let a child StatusBar eat clicks aimed at the button:
	-- strip its mouse, and mirror the handlers onto it as a fallback.
	-- (1.0.21) NOTE: EnableMouse(0) does NOT disable on this client -- 0 is
	-- truthy in Lua -- only `false` takes.
	pcall(bar.EnableMouse, bar, false)
	pcall(bar.RegisterForClicks, bar, "LeftButtonUp", "MiddleButtonUp", "RightButtonUp", "Button4Up", "Button5Up")
	pcall(bar.SetScript, bar, "OnClick", onUnitClick)
	pcall(bar.SetScript, bar, "OnMouseUp", onUnitMouseUp)
	pcall(bar.SetScript, bar, "OnEnter", onUnitEnter)
	pcall(bar.SetScript, bar, "OnLeave", onUnitLeave)

	-- overlay layer for all markers + text. A frame's own textures and
	-- fontstrings always render BENEATH its child frames, so anything
	-- parented straight to the button (name, hp%, debuff/watch marks,
	-- aggro edges, low-hp tint) is painted over by the StatusBar above.
	-- Stack them on a transparent frame created AFTER the bar instead
	-- (no SetFrameLevel bump: this engine double-draws re-leveled frames).
	local ov = CreateFrame("Frame", nil, b)
	ov:SetAllPoints(b)
	-- (1.0.21) `false`, not 0: on this client EnableMouse(0) leaves the
	-- overlay mouse-ON (0 is truthy), and it then eats every hover/click --
	-- the GetMouseFocus probe caught exactly this unnamed child holding focus
	ov:EnableMouse(false)
	b.evhOverlay = ov

	-- low-health / highlight overlay (tint, beneath the marks on this frame)
	local hl = ov:CreateTexture(nil, "BACKGROUND")
	hl:SetTexture("Interface\\Buttons\\WHITE8X8")
	hl:SetAllPoints(b)
	hl:Hide()
	b.hl = hl

	-- name text
	local name = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	name:SetJustifyH("LEFT")
	name:SetPoint("TOPLEFT", b, "TOPLEFT", 3, -1)
	b.name = name

	-- health / percent text
	local hp = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	hp:SetJustifyH("RIGHT")
	hp:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -3, 0)
	b.hp = hp

	-- debuff indicator squares (glyph + colored square)
	b.debuffs = {}
	for k = 1, 4 do
		local sq = ov:CreateTexture(nil, "ARTWORK")
		sq:SetTexture("Interface\\Buttons\\WHITE8X8")
		sq:SetWidth(13)
		sq:SetHeight(13)
		sq:SetPoint("TOPRIGHT", b, "TOPRIGHT", -2 - (k - 1) * 14, -2)
		sq:Hide()
		local fs = ov:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		fs:SetPoint("CENTER", sq, "CENTER", 0, 0)
		fs:Hide()
		b.debuffs[k] = { sq = sq, fs = fs }
	end

	-- buff-watch missing markers (yellow squares)
	b.watch = {}
	for k = 1, 6 do
		local sq = ov:CreateTexture(nil, "ARTWORK")
		sq:SetTexture("Interface\\Buttons\\WHITE8X8")
		sq:SetWidth(6)
		sq:SetHeight(6)
		sq:SetPoint("TOPLEFT", b, "TOPLEFT", 2 + (k - 1) * 8, -2)
		sq:Hide()
		b.watch[k] = sq
	end

	-- aggro border (red edges)
	b.aggro = {}
	local edges = b.aggro
	edges[1] = ov:CreateTexture(nil, "OVERLAY")
	edges[1]:SetTexture("Interface\\Buttons\\WHITE8X8")
	edges[1]:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	edges[1]:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
	edges[1]:SetHeight(2)
	edges[2] = ov:CreateTexture(nil, "OVERLAY")
	edges[2]:SetTexture("Interface\\Buttons\\WHITE8X8")
	edges[2]:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	edges[2]:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	edges[2]:SetHeight(2)
	edges[3] = ov:CreateTexture(nil, "OVERLAY")
	edges[3]:SetTexture("Interface\\Buttons\\WHITE8X8")
	edges[3]:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	edges[3]:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	edges[3]:SetWidth(2)
	edges[4] = ov:CreateTexture(nil, "OVERLAY")
	edges[4]:SetTexture("Interface\\Buttons\\WHITE8X8")
	edges[4]:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
	edges[4]:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	edges[4]:SetWidth(2)
	for k = 1, 4 do edges[k]:Hide() end

	-- (1.0.21) INPUT FIX, re-asserted after every child exists: on this
	-- engine a plain child Frame is mouse-ON by default and eats hover and
	-- click for everything it covers. EnableMouse(0) did NOT disable (0 is
	-- truthy in Lua); only `false` takes. bar + evhOverlay are the only
	-- child frames, but sweep GetChildren too in case one is added later.
	local nkids = 0
	if b.GetChildren then
		local raw = { pcall(b.GetChildren, b) }
		for j = 2, #raw do
			local kid = raw[j]
			if type(kid) == "table" and kid.EnableMouse then
				nkids = nkids + 1
				pcall(kid.EnableMouse, kid, false)
			end
		end
	end
	if i == 1 and EVH.diag then
		local _, om = pcall(ov.IsMouseEnabled, ov)
		local _, bm = pcall(bar.IsMouseEnabled, bar)
		EVH.diag("unitBtn1 1.0.21 kids=" .. nkids
			.. " ovMouse=" .. tostring(om) .. " barMouse=" .. tostring(bm))
	end

	b:Hide()
	return b
end

-- -------------------------------------------------------------
-- Unit glyph for debuff type
-- -------------------------------------------------------------
local function debuffGlyph(dispel)
	if not dispel then return "!" end
	if dispel == "Magic" then return L.gMagic end
	if dispel == "Disease" then return L.gDisease end
	if dispel == "Poison" then return L.gPoison end
	if dispel == "Curse" then return L.gCurse end
	return "?"
end

-- -------------------------------------------------------------
-- Grid frame
-- -------------------------------------------------------------
local groupHeaders = {}

local function buildGroupHeaders()
	local g = EVH.grid
	for i = 1, 8 do
		local fs = mkText(g.GridFrame, "EVH_GroupHdr" .. i, 16, 10, "CENTER")
		fs:SetTextColor(0.7, 0.7, 0.7)
		fs:Hide()
		groupHeaders[i] = fs
	end
end

local function layoutGrid()
	local g = EVH.grid
	if not g then return end
	local opts = db.opts
	local scale = opts.scale or 1
	local bs = BAR_SIZES[opts.barSize or 2]
	local w = bs.w * scale
	local h = bs.h * scale
	local gap = 3 * scale
	g.metrics = { w = w, h = h, gap = gap, scale = scale }

	local roster = EVH.roster
	local cols = {}
	for _, m in ipairs(roster) do
		local c = m.subgroup or 1
		cols[c] = cols[c] or {}
		cols[c][#cols[c] + 1] = m
	end
	local colKeys = {}
	for c in pairs(cols) do colKeys[#colKeys + 1] = c end
	table.sort(colKeys)

	local shown = 0
	for _, c in ipairs(colKeys) do
		local members = cols[c]
		for r, m in ipairs(members) do
			shown = shown + 1
			local b = g.buttons[shown]
			if b then
				b.evhMember = m
				b:Show()
				b:ClearAllPoints()
				b:SetWidth(w)
				b:SetHeight(h)
				b:SetPoint("TOPLEFT", g.GridFrame, "TOPLEFT", (c - 1) * (w + gap), -((r - 1) * (h + gap)))
			end
		end
	end
	for i = shown + 1, #g.buttons do
		local b = g.buttons[i]
		b.evhMember = nil
		b:Hide()
	end
	g.shown = shown

	-- (1.0.19) ground truth for hit-testing: the on-screen rect of the grid
	-- and of the first visible unit button, logged after every layout
	-- (consecutive identical lines collapse in EVH.diag)
	do
		local function rect(f)
			local ok, l = pcall(f.GetLeft, f)
			if not ok or l == nil then return "hidden" end
			local _, r = pcall(f.GetRight, f)
			local _, t = pcall(f.GetTop, f)
			local _, bm = pcall(f.GetBottom, f)
			return string.format("%.0f,%.0f - %.0f,%.0f", l or -1, t or -1, r or -1, bm or -1)
		end
		local b1 = shown >= 1 and g.buttons[1]
		EVH.diag("grid rect [" .. rect(g.GridFrame) .. "] btn1 rect ["
			.. (b1 and rect(b1) or "none") .. "] shown=" .. shown)
	end

	local colsN = #colKeys
	local maxRows = 0
	for _, c in ipairs(colKeys) do
		if #cols[c] > maxRows then maxRows = #cols[c] end
	end
	local gw = colsN * (w + gap) - gap
	local gh = maxRows * (h + gap) - gap
	g.GridFrame:SetWidth(math.max(gw, w))
	g.GridFrame:SetHeight(math.max(gh, h))

	-- column headers
	local headerY = 2
	for i = 1, 8 do
		local fs = groupHeaders[i]
		if not fs then break end
		if cols[i] and #cols[i] > 0 then
			fs:ClearAllPoints()
			fs:SetPoint("TOPLEFT", g.GridFrame, "TOPLEFT", (i - 1) * (w + gap) + w / 2 - 8, headerY)
			fs:SetText(tostring(i))
			fs:Show()
		else
			fs:Hide()
		end
	end
	g.headerOffset = headerY + 12
	-- shift buttons down below the headers
	local off = g.headerOffset * scale
	for i = 1, shown do
		local b = g.buttons[i]
		b:ClearAllPoints()
		local m = b.evhMember
		if m then
			local c = m.subgroup or 1
			local r = 0
			for k = 1, i do
				local prev = g.buttons[k]
				if prev and prev.evhMember and prev.evhMember.subgroup == c then r = r + 1 end
			end
			b:SetPoint("TOPLEFT", g.GridFrame, "TOPLEFT", (c - 1) * (w + gap), -(off + (r - 1) * (h + gap)))
		end
	end
	-- resize to include header
	g.GridFrame:SetHeight(math.max(gh + off, h + off))
end

-- -------------------------------------------------------------
-- Per-button refresh
-- -------------------------------------------------------------
local function updateButton(b, m)
	local opts = db.opts
	local g = EVH.grid
	local scale = g.metrics.scale or 1
	local w = g.metrics.w
	local h = g.metrics.h

	EV.snapshot(m)

	-- test mode override
	local test = EV.testMode
	if test then
		m.pct = 30
		m.hp = floor((m.max or 1000) * 0.3)
		m.dead = false
		m.offline = false
		m.aggro = true
		m.oor = (m.unit ~= "player")
		m.debuffs = { { dispel = "Poison" }, { dispel = "Magic" } }
		m.highDebuff = true
		m.missingBuffs = { "watch" }
	end

	-- health bar
	local bar = b.bar
	local mx = m.max or 0
	if mx > 0 then
		bar:SetMinMaxValues(0, mx)
		bar:SetValue(m.hp or 0)
	else
		bar:SetMinMaxValues(0, 1)
		bar:SetValue(0)
	end
	local cr, cg, cb
	local scheme = opts.colorScheme or 1
	if scheme == 1 then
		cr, cg, cb = EV.classColor(m.class)
	elseif scheme == 2 then
		local p = m.pct or 100
		if p >= 50 then
			local t = (p - 50) / 50
			cr = 0.3 + 0.7 * t; cg = 1 - 0.2 * t; cb = 0.3
		else
			local t = p / 50
			cr = 1; cg = 0.3 + 0.7 * t; cb = 0.3
		end
	else
		cr, cg, cb = 0.9, 0.9, 0.9
	end
	if m.dead then cr, cg, cb = 0.2, 0.2, 0.2 end
	if m.offline then cr, cg, cb = 0.25, 0.25, 0.25 end
	if test then cr, cg, cb = 1, 0.3, 0.2 end
	bar:SetStatusBarColor(cr, cg, cb)

	-- name
	local name = b.name
	name:SetText(m.name or "?")
	-- integer pixel size + auto-extent (no SetWidth/SetHeight): the
	-- wrapped-fontstring path double-renders on this engine (ghosting)
	local fsize = floor((opts.fontSize or 11) * scale + 0.5)
	name:SetFont(FONT_PATH, fsize)
	name:SetTextColor(1, 1, 1)

	-- health text
	local hpfs = b.hp
	local hpText = ""
	if opts.showPct == 1 then hpText = strformat("%.0f%%", m.pct or 0) end
	if opts.showHealth == 1 then
		if hpText ~= "" then
			hpText = strformat("%d %s", m.hp or 0, hpText)
		else
			hpText = strformat("%d", m.hp or 0)
		end
	end
	hpfs:SetText(hpText)
	hpfs:SetFont(FONT_PATH, fsize)
	hpfs:SetTextColor(1, 1, 1)

	-- debuff squares
	local d = m.debuffs or {}
	for k = 1, 4 do
		local slot = b.debuffs[k]
		local e = d[k]
		if e and opts.showDebuffs == 1 then
			local dr, dg, dbl = EV.dispelColor(e.dispel)
			slot.sq:SetVertexColor(dr, dg, dbl, 1)
			slot.sq:Show()
			slot.fs:SetText(debuffGlyph(e.dispel))
			slot.fs:SetFont(FONT_PATH, 10)
			slot.fs:SetTextColor(1, 1, 1)
			slot.fs:Show()
		else
			slot.sq:Hide()
			slot.fs:Hide()
		end
	end

	-- buff watch markers
	local missing = m.missingBuffs or {}
	if opts.showBuffW == 1 then
		for k = 1, 6 do
			if missing[k] then
				b.watch[k]:SetVertexColor(1, 0.9, 0.2, 1)
				b.watch[k]:Show()
			else
				b.watch[k]:Hide()
			end
		end
	else
		for k = 1, 6 do b.watch[k]:Hide() end
	end

	-- aggro border
	if m.aggro then
		for k = 1, 4 do b.aggro[k]:SetVertexColor(1, 0.15, 0.15, 1) end
		for k = 1, 4 do b.aggro[k]:Show() end
	else
		for k = 1, 4 do b.aggro[k]:Hide() end
	end

	-- low health / highlight overlay
	local low = (not m.dead) and (m.pct or 100) <= (opts.lowHp or 35)
	local needHl = low or m.highDebuff or test
	if needHl then
		if test then
			b.hl:SetTexture(1, 0.9, 0.2, 0.35)
		elseif m.highDebuff then
			b.hl:SetTexture(1, 0.2, 0.2, 0.30)
		else
			b.hl:SetTexture(1, 0.3, 0.2, 0.20 + 0.15 * ((math.sin(GetTime() * 6) + 1) / 2))
		end
		b.hl:Show()
		b.lowFlash = true
	else
		b.hl:Hide()
		b.lowFlash = false
	end

	-- range dimming
	if m.oor and opts.showRange == 1 and not test then
		b:SetAlpha(0.45)
	else
		b:SetAlpha(1)
	end
end

local function refreshAll()
	local g = EVH.grid
	if not g or not g.GridFrame then return end
	if not g.GridFrame:IsShown() then return end
	for i = 1, g.shown or 0 do
		local b = g.buttons[i]
		if b and b.evhMember then
			updateButton(b, b.evhMember)
		end
	end
end

EVH.refreshAll = refreshAll
EVH.updateButton = updateButton

-- -------------------------------------------------------------
-- Grid construction
-- -------------------------------------------------------------
-- manual drag (engine RegisterForDrag/OnDragStart proved unreliable here)
local gridDrag
local function uiScale()
	local okS, s = pcall(UIParent.GetEffectiveScale, UIParent)
	if okS and s and s > 0 then return s end
	return 1
end
local function startGridDrag()
	local g = EVH.grid
	if not g or not g.GridFrame then return end
	if db.opts.locked == 1 then return end
	local okP, a, _, _, x, y = pcall(g.GridFrame.GetPoint, g.GridFrame)
	if not okP or not a then return end
	if not GetCursorPosition then return end
	local cx, cy = GetCursorPosition()
	if not cx then return end
	local s = uiScale()
	gridDrag = { a = a, x = x or 0, y = y or 0, sx = cx / s, sy = cy / s }
end
local function stopGridDrag(save)
	if gridDrag and save and EVH.grid and EVH.grid.GridFrame then
		EV.savePos(EVH.grid.GridFrame, "pos")
	end
	gridDrag = nil
end
local function gridDragUpdate()
	local d = gridDrag
	if not d then return end
	local g = EVH.grid
	local f = g and g.GridFrame
	if not f then gridDrag = nil return end
	if not GetCursorPosition then return end
	local cx, cy = GetCursorPosition()
	if not cx then return end
	local s = uiScale()
	f:ClearAllPoints()
	f:SetPoint(d.a, UIParent, d.a, d.x + (cx / s - d.sx), d.y + (cy / s - d.sy))
end

local function buildGrid()
	if EVH.grid then return EVH.grid end
	local g = {}
	EVH.grid = g
	g.GridFrame = CreateFrame("Frame", "EVH_Grid", UIParent)
	g.GridFrame:SetWidth(200)
	g.GridFrame:SetHeight(120)
	g.GridFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	g.skin = skinFrame(g.GridFrame, "MEDIUM", 0.55, 0.4, 0.4, 0.5)
	g.GridFrame:SetMovable(1)
	g.GridFrame:EnableMouse(1)
	g.GridFrame:SetScript("OnMouseDown", function()
		EV.diag("GRID mousedown arg1=" .. tostring(arg1))
		startGridDrag()
	end)
	g.GridFrame:SetScript("OnMouseUp", function()
		EV.diag("GRID mouseup arg1=" .. tostring(arg1))
		stopGridDrag(true)
	end)
	g.GridFrame:SetScript("OnUpdate", gridDragUpdate)
	-- (1.0.19) HIGH so the grid and its buttons sit above unrealUI's
	-- MEDIUM-strata bottom-center panels; children do NOT inherit a later
	-- parent strata change, so the buttons set their own in buildUnitButton
	g.GridFrame:SetFrameStrata("HIGH")
	local okLv, lv = pcall(g.GridFrame.GetFrameLevel, g.GridFrame)
	if okLv and lv and lv > 0 then g.skin:SetFrameLevel(lv - 1) end

	g.buttons = {}
	for i = 1, 40 do
		g.buttons[i] = buildUnitButton(i)
	end
	EVH.grid = g
	buildGroupHeaders()
	return g
end

-- -------------------------------------------------------------
-- Options panel
local optFrame, optPages, optTabs
local optLabels = {}
local currentOptPage

local function optLabel(name, getText, onClick, x, y)
	local b = mkButton(currentOptPage, name, 250, 17, "", onClick)
	b:SetPoint("TOPLEFT", currentOptPage, "TOPLEFT", x or 10, y or -8)
	b.getText = getText
	optLabels[#optLabels + 1] = b
	return b
end
local function optToggle(name, label, getBool, onToggle, x, y, tipText)
	local b = optLabel(name,
		function()
			local on = getBool()
			return (on and "● " or "○ ") .. label .. ": " .. (on and L.on or L.off)
		end,
		function()
			onToggle()
			EV.refreshOptions()
		end, x, y)
	if tipText then
		tip(b, "ANCHOR_RIGHT", function(T)
			T:SetText(label, 1, 0.9, 0.55)
			T:AddLine(tipText, 0.85, 0.85, 0.85, 1)
			T:Show()
		end)
	end
	return b
end

local function yNext(y, d)
	return y - (d or 18)
end

-- -------------------------------------------------------------
-- Tab 1: display options
-- -------------------------------------------------------------
local function buildDisplayPage(page)
	currentOptPage = page
	local y = -8
	local function opt(name, getText, onClick)
		optLabel(name, getText, onClick, 10, y)
		y = y - 18
	end
	local function tog(name, label, getBool, onToggle, tipText)
		optToggle(name, label, getBool, onToggle, 10, y, tipText)
		y = y - 18
	end
	opt("EVH_Scale", function() return L.scale .. ": " .. strformat("%.1f", db.opts.scale or 1) end, function()
		local seq = { [0.8] = 1.0, [1.0] = 1.2, [1.2] = 1.4, [1.4] = 0.8 }
		db.opts.scale = seq[db.opts.scale] or 1.0
		EV.rebuildLayout()
		EV.refreshOptions()
	end)
	opt("EVH_BarSize", function()
		local names = { [1] = L.barSmall, [2] = L.barMedium, [3] = L.barLarge }
		return L.barSize .. ": " .. (names[db.opts.barSize] or L.barMedium)
	end, function()
		db.opts.barSize = ((db.opts.barSize or 2) % 3) + 1
		EV.rebuildLayout()
		EV.refreshOptions()
	end)
	opt("EVH_Font", function() return L.fontSize .. ": " .. (db.opts.fontSize or 11) end, function()
		local seq = { [9] = 10, [10] = 11, [11] = 12, [12] = 13, [13] = 14, [14] = 9 }
		db.opts.fontSize = seq[db.opts.fontSize] or 11
		EV.refreshOptions()
	end)
	opt("EVH_Scheme", function()
		local names = { [1] = L.colClass, [2] = L.colGradient, [3] = L.colWhite }
		return L.colorScheme .. ": " .. (names[db.opts.colorScheme] or L.colClass)
	end, function()
		db.opts.colorScheme = ((db.opts.colorScheme or 1) % 3) + 1
		EV.refreshOptions()
	end)
	opt("EVH_LowHp", function() return L.lowHp .. ": " .. (db.opts.lowHp or 35) .. "%" end, function()
		local seq = { [20] = 30, [30] = 35, [35] = 40, [40] = 50, [50] = 60, [60] = 20 }
		db.opts.lowHp = seq[db.opts.lowHp] or 35
		EV.refreshOptions()
	end)
	tog("EVH_Pct", L.showPct, function() return db.opts.showPct == 1 end, function()
		db.opts.showPct = (db.opts.showPct == 1) and 0 or 1
	end, L.tipPct)
	tog("EVH_HpText", L.showHealth, function() return db.opts.showHealth == 1 end, function()
		db.opts.showHealth = (db.opts.showHealth == 1) and 0 or 1
	end, L.tipHealth)
	tog("EVH_Debuff", L.showDebuffs, function() return db.opts.showDebuffs == 1 end, function()
		db.opts.showDebuffs = (db.opts.showDebuffs == 1) and 0 or 1
	end, L.tipDebuff)
	tog("EVH_BuffW", L.showBuffW, function() return db.opts.showBuffW == 1 end, function()
		db.opts.showBuffW = (db.opts.showBuffW == 1) and 0 or 1
	end, L.tipBuffW)
	tog("EVH_Range", L.showRange, function() return db.opts.showRange == 1 end, function()
		db.opts.showRange = (db.opts.showRange == 1) and 0 or 1
	end, L.tipRange)
	tog("EVH_Aggro", L.showAggro, function() return db.opts.showAggro == 1 end, function()
		db.opts.showAggro = (db.opts.showAggro == 1) and 0 or 1
	end, L.tipAggro)
	tog("EVH_Lock", L.lockPos, function() return db.opts.locked == 1 end, function()
		db.opts.locked = (db.opts.locked == 1) and 0 or 1
	end, L.tipLock)
	tog("EVH_ClickDbg", L.clickDbg, function() return db.opts.clickDebug == 1 end, function()
		db.opts.clickDebug = (db.opts.clickDebug == 1) and 0 or 1
		EVH.clickDebug = (db.opts.clickDebug == 1)
	end, L.tipClickDbg)
	tog("EVH_MidCast", L.midCast, function() return db.opts.midFree == 1 end, function()
		EV.setMiddleCast(not (db.opts.midFree == 1))
	end, L.tipMidCast)
	local bTest = mkButton(page, "EVH_Test", 250, 17, "", function()
		EV.setTestMode(not EV.testMode)
		EV.refreshOptions()
		EV.refreshAll()
	end)
	bTest:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	bTest.getText = function() return L.testMode .. ": " .. (EV.testMode and L.on or L.off) end
	optLabels[#optLabels + 1] = bTest
	y = y - 18
	local bReset = mkButton(page, "EVH_ResetPos", 250, 17, L.resetPos, function()
		EV.resetPositions()
		EV.refreshOptions()
	end)
	bReset:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	optLabels[#optLabels + 1] = bReset
end

-- -------------------------------------------------------------
-- Tab 2: click-casting bindings
-- -------------------------------------------------------------
local CLICK_LABELS = {
	{ btn = "LeftButton", mod = "",      name = L.clickLeft },
	{ btn = "LeftButton", mod = "Shift", name = L.clickLeftShift },
	{ btn = "LeftButton", mod = "Ctrl",  name = L.clickLeftCtrl },
	{ btn = "LeftButton", mod = "Alt",   name = L.clickLeftAlt },
	{ btn = "RightButton", mod = "",     name = L.clickRight },
	{ btn = "RightButton", mod = "Shift",name = L.clickRightShift },
	{ btn = "RightButton", mod = "Ctrl", name = L.clickRightCtrl },
	{ btn = "RightButton", mod = "Alt",  name = L.clickRightAlt },
	-- NOTE: no MiddleButton rows — this client never delivers middle-button
	-- input to the Lua UI (verified: BUTTON3 unbound + zero events)
	{ btn = "Button4", mod = "",         name = L.clickSide4 },
	{ btn = "Button4", mod = "Shift",    name = L.clickSide4Shift },
	{ btn = "Button5", mod = "",         name = L.clickSide5 },
	{ btn = "Button5", mod = "Shift",    name = L.clickSide5Shift },
}

local function buildClicksPage(page)
	currentOptPage = page
	local y = -6
	local title = mkText(page, "EVH_ClicksTitle", 430, 14, "LEFT")
	title:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	title:SetText(hexc(0.9, 0.8, 0.5) .. "● " .. L.bindTitle .. "|r")
	y = y - 22

	local bAuto = mkButton(page, "EVH_AutoBind", 130, 18, L.autoBind, function()
		EV.autoSuggestBinds()
		EV.refreshOptions()
	end)
	bAuto:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	local bClear = mkButton(page, "EVH_ClearBinds", 130, 18, L.clearBinds, function()
		EV.clearAllBinds()
		EV.refreshOptions()
	end)
	bClear:SetPoint("TOPLEFT", page, "TOPLEFT", 150, y)
	y = y - 26

	page.bindRows = {}
	for i, c in ipairs(CLICK_LABELS) do
		local lab = mkText(page, "EVH_CLab" .. i, 120, 16, "LEFT")
		lab:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
		lab:SetText(hexc(0.85, 0.85, 0.85) .. c.name .. "|r")
		local key = EV.clickKey(c.btn, c.mod)
		local b = mkButton(page, "EVH_CBind" .. i, 300, 16, "", function(a1)
			local btn = EV.resolveButton(a1, arg1)
			if btn == "RightButton" then
				EV.clearBind(key)
			else
				EV.cycleBind(key)
			end
			EV.refreshOptions()
		end)
		b:SetPoint("TOPLEFT", page, "TOPLEFT", 140, y)
		b.key = key
		page.bindRows[i] = b
		y = y - 18
	end
end

-- -------------------------------------------------------------
-- Tab 3: buff / debuff watch lists
-- -------------------------------------------------------------
local function listKeys(set)
	local out = {}
	if not set then return out end
	for k in pairs(set) do out[#out + 1] = k end
	table.sort(out)
	return out
end

local function buildWatchList(page, prefix, y, titleText, addText, clearFn, addFn, rows)
	local t = mkText(page, prefix .. "Title", 430, 14, "LEFT")
	t:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	t:SetText(hexc(0.9, 0.8, 0.5) .. titleText .. "|r")
	y = y - 20
	local bAdd = mkButton(page, prefix .. "Add", 200, 17, addText, function()
		addFn()
		EV.refreshOptions()
	end)
	bAdd:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	local bClear = mkButton(page, prefix .. "Clear", 90, 17, L.clearAll, function()
		clearFn()
		EV.refreshOptions()
	end)
	bClear:SetPoint("TOPLEFT", page, "TOPLEFT", 220, y)
	y = y - 22
	for i = 1, 8 do
		local lab = mkText(page, prefix .. "Item" .. i, 300, 15, "LEFT")
		lab:SetPoint("TOPLEFT", page, "TOPLEFT", 12, y)
		lab:SetText("")
		local del = mkButton(page, prefix .. "Del" .. i, 20, 15, "×", function()
			local key = del.key
			if key then
				if prefix == "EVH_Buff" then db.buffWatch[key] = nil else db.highDebuffs[key] = nil end
				EV.refreshOptions()
			end
		end)
		del:SetPoint("TOPLEFT", page, "TOPLEFT", 330, y - 1)
		rows[i] = { lab = lab, del = del, prefix = prefix }
		y = y - 17
	end
	return y
end

local function buildWatchPage(page)
	currentOptPage = page
	local y = -6
	local buffRows = {}
	y = buildWatchList(page, "EVH_Buff", y, "● " .. L.watchBuffT .. L.buffHint, L.addTargetBuf, function() EV.clearBuffWatch() end, function() EV.addBuffWatchFromTarget() end, buffRows)
	page.buffRows = buffRows
	y = y - 10

	local debRows = {}
	y = buildWatchList(page, "EVH_Deb", y, "● " .. L.watchDebT .. L.debHint, L.addTargetDeb, function() EV.clearHighDebuffs() end, function() EV.addDebuffFromTarget() end, debRows)
	page.debRows = debRows
	y = y - 8
	local bDist = mkButton(page, "EVH_RangeDist", 250, 17, "", function()
		db.opts.rangeDist = ((db.opts.rangeDist or 4) % 8) + 1
		EV.refreshOptions()
	end)
	bDist:SetPoint("TOPLEFT", page, "TOPLEFT", 10, y)
	bDist.getText = function() return L.rangeDist .. ": " .. (db.opts.rangeDist or 4) .. " (1-8)" end
	optLabels[#optLabels + 1] = bDist
end

-- -------------------------------------------------------------
-- Options frame
-- -------------------------------------------------------------
local function refreshWatchRows(rows, set)
	local keys = listKeys(set)
	for i = 1, 8 do
		local r = rows[i]
		if not r then break end
		local k = keys[i]
		if k then
			r.lab:SetText(hexc(0.8, 0.8, 0.8) .. k .. "|r")
			r.lab:Show()
			r.del.key = k
			r.del:Show()
		else
			r.lab:SetText("")
			r.lab:Hide()
			r.del.key = nil
			r.del:Hide()
		end
	end
end

function EV.refreshOptions()
	if not optFrame then return end
	for _, o in ipairs(optLabels) do
		if o.getText then setBtnText(o, o.getText()) end
	end
	for _, page in ipairs(optPages or {}) do
		if page.bindRows then
			for _, b in ipairs(page.bindRows) do
				local slot = db.clicks[b.key]
				if slot then
					setBtnText(b, L.slotColon .. slot .. ": " .. (EV.slotName(slot) or "?"), 0.5, 1, 0.5)
				else
					setBtnText(b, L.slotColon .. ": " .. L.empty, 0.55, 0.55, 0.55)
				end
			end
		end
		if page.buffRows then refreshWatchRows(page.buffRows, db.buffWatch) end
		if page.debRows then refreshWatchRows(page.debRows, db.highDebuffs) end
	end
end

function EV.showOptTab(n)
	for i = 1, 3 do
		if optPages and optPages[i] then
			if i == n then optPages[i]:Show() else optPages[i]:Hide() end
		end
		if optTabs and optTabs[i] and optTabs[i].evhBG then
			if i == n then optTabs[i].evhBG:SetTexture(0.45, 0.36, 0.14, 0.9)
			else optTabs[i].evhBG:SetTexture(0.16, 0.16, 0.16, 0.72) end
		end
	end
end

function EV.toggleOptions()
	if not optFrame then return end
	if optFrame:IsShown() then
		optFrame:Hide()
		syncSkin(optFrame)
	else
		optFrame:Show()
		syncSkin(optFrame)
		EV.showOptTab(1)
		EV.refreshOptions()
	end
end

function EV.showOptions(show)
	if not optFrame then return end
	if show then
		optFrame:Show()
		syncSkin(optFrame)
		EV.showOptTab(1)
		EV.refreshOptions()
	else
		optFrame:Hide()
		syncSkin(optFrame)
	end
end

local function buildOptionsFrame()
	if optFrame then return end
	optFrame = CreateFrame("Frame", "EVH_Options", UIParent)
	optFrame:SetWidth(470)
	optFrame:SetHeight(430)
	optFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	skinFrame(optFrame, "HIGH", 0.82, 0.45, 0.35, 0.15)
	optFrame:SetMovable(1)
	optFrame:EnableMouse(1)
	optFrame:RegisterForDrag("LeftButton")
	optFrame:SetScript("OnDragStart", function() optFrame:StartMoving() end)
	optFrame:SetScript("OnDragStop", function()
		optFrame:StopMovingOrSizing()
		EV.savePos(optFrame, "optpos")
	end)
	optFrame:SetFrameStrata("HIGH")
	local okLv, lv = pcall(optFrame.GetFrameLevel, optFrame)
	if okLv and lv and lv > 0 then
		local skin = _G["EVH_OptionsSkin"]
		if skin and skin.SetFrameLevel then skin:SetFrameLevel(lv - 1) end
	end

	local title = mkText(optFrame, "EVH_OptTitle", 300, 14, "LEFT")
	title:SetPoint("TOPLEFT", optFrame, "TOPLEFT", 10, -8)
	title:SetText("|cff4dd2ff" .. L.title .. "|r " .. L.options)
	local close = mkButton(optFrame, "EVH_OptClose", 20, 16, "X", function() EV.showOptions(false) end)
	close:SetPoint("TOPRIGHT", optFrame, "TOPRIGHT", -8, -6)

	optTabs = {}
	local tabs = { { L.tabDisplay, 1 }, { L.tabClicks, 2 }, { L.tabWatch, 3 } }
	local prev
	for _, t in ipairs(tabs) do
		local b = mkButton(optFrame, "EVH_OptTab" .. t[2], 70, 18, t[1], function() EV.showOptTab(t[2]) end)
		if prev then
			b:SetPoint("TOPLEFT", prev, "TOPRIGHT", 4, 0)
		else
			b:SetPoint("TOPLEFT", optFrame, "TOPLEFT", 10, -26)
		end
		prev = b
		optTabs[t[2]] = b
	end

	optPages = {}
	for i = 1, 3 do
		local p = CreateFrame("Frame", "EVH_OptPage" .. i, optFrame)
		p:SetWidth(456)
		p:SetHeight(384)
		p:SetPoint("TOPLEFT", optFrame, "TOPLEFT", 6, -50)
		p:Hide()
		optPages[i] = p
	end
	buildDisplayPage(optPages[1])
	buildClicksPage(optPages[2])
	buildWatchPage(optPages[3])
	optFrame:Hide()
	syncSkin(optFrame)
	EVH.optionsFrame = optFrame
end

-- -------------------------------------------------------------
-- Minimap button
-- -------------------------------------------------------------
local function buildMinimap()
	if EVH.minimapBtn then return end
	local mm = CreateFrame("Button", "EVH_Minimap", Minimap)
	mm:SetFrameStrata("MEDIUM")
	mm:SetFrameLevel(8)
	mm:SetWidth(31)
	mm:SetHeight(31)
	mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	pcall(mm.EnableMouse, mm, true)
	-- no self-drawn background square: the engine renders it as an opaque
	-- black box behind the glyph (EmberLoot's button ships no bg either).
	-- Highlight + golden tracking border only, glyph floats above the map.
	mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	local txt = mm:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	txt:SetText(L.mmGlyph)
	txt:SetTextColor(0.3, 0.85, 1)
	txt:SetPoint("CENTER", mm, "CENTER", 0, 0)
	local border = mm:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetWidth(54)
	border:SetHeight(54)
	border:SetPoint("TOPLEFT", mm, "TOPLEFT")

	-- orbit button: angle around the minimap, cursor-delta drag (scale-safe)
	local angle = db.mmAngle or 210
	local dragging = false
	local suppressClick = false
	local moved = false
	local lastCX, lastCY
	local baseCX, baseCY
	local vx = math.cos(math.rad(angle)) * 80
	local vy = math.sin(math.rad(angle)) * 80
	local atan2 = math.atan2 or function(y, x)
		if x > 0 then return math.atan(y / x) end
		if x < 0 then return math.atan(y / x) + math.pi end
		return (y >= 0) and (math.pi / 2) or -(math.pi / 2)
	end
	local function mmPlace()
		local mw = Minimap:GetWidth() or 160
		local mh = Minimap:GetHeight() or mw
		local R = mw / 2 + 5
		local a = math.rad(angle)
		mm:ClearAllPoints()
		mm:SetPoint("TOPLEFT", Minimap, "TOPLEFT",
			mw / 2 + math.cos(a) * R - 15,
			-mh / 2 + math.sin(a) * R + 15)
	end
	-- EmberLoot pattern: MouseDown/Up only track dragging; ALL button-name
	-- logic lives in OnClick (mouse scripts other than OnClick get no args).
	mm:SetScript("OnMouseDown", function()
		suppressClick = false
		dragging = true
		moved = false
		local cx, cy
		if GetCursorPosition then cx, cy = GetCursorPosition() end
		lastCX, lastCY = cx, cy
		baseCX, baseCY = cx, cy
	end)
	mm:SetScript("OnMouseUp", function()
		if not dragging then return end
		dragging = false
		lastCX, lastCY = nil, nil
		if moved then
			db.mmAngle = angle
			mmPlace()
			suppressClick = true
		end
	end)
	mm:SetScript("OnUpdate", function()
		if not dragging then return end
		if not GetCursorPosition then return end
		local cx, cy = GetCursorPosition()
		if not cx then return end
		if lastCX then
			vx = vx + (cx - lastCX)
			vy = vy + (cy - lastCY)
			if baseCX and math.abs(cx - baseCX) + math.abs(cy - baseCY) > 8 then
				moved = true
			end
		end
		lastCX, lastCY = cx, cy
		if (vx ~= 0 or vy ~= 0) and moved then
			local a2 = math.deg(atan2(vy, vx))
			if a2 < 0 then a2 = a2 + 360 end
			angle = a2
			mmPlace()
		end
	end)
	mm:SetScript("OnClick", function(a, b)
		if suppressClick then
			suppressClick = false
			return
		end
		local btn
		if a == "RightButton" or b == "RightButton" then btn = "RightButton"
		elseif a == "LeftButton" or b == "LeftButton" then btn = "LeftButton"
		elseif arg1 == "RightButton" then btn = "RightButton"
		else btn = "LeftButton" end
		if btn == "RightButton" then
			EV.toggleOptions()
			return
		end
		if IsShiftKeyDown and IsShiftKeyDown() then
			EV.toggleOptions()
			return
		end
		EV.toggleGrid()
	end)
	tip(mm, "ANCHOR_LEFT", function(T)
		T:SetText(L.title)
		T:AddLine(L.mmTip1, 0.8, 0.8, 0.8)
		T:AddLine(L.mmTip2, 0.8, 0.8, 0.8)
		T:AddLine(L.mmTip3, 0.5, 0.5, 0.5)
	end)
	mm.evhPlace = mmPlace
	EVH.minimapBtn = mm
	mmPlace()
end

-- -------------------------------------------------------------
-- Grid show / layout API used by Init
-- -------------------------------------------------------------
function EV.rebuildLayout()
	local g = EVH.grid
	if g then layoutGrid() end
end

function EV.showGrid(show)
	local g = EVH.grid
	if not g then return end
	if show then
		g.GridFrame:Show()
		syncSkin(g.GridFrame)
		layoutGrid()
	else
		g.GridFrame:Hide()
		syncSkin(g.GridFrame)
	end
end

function EV.gridShown()
	local g = EVH.grid
	return g and g.GridFrame and g.GridFrame:IsShown() or false
end

function EV.toggleGrid()
	if EV.rosterCount() == 0 then EV.buildRoster() end
	if EV.gridShown() then
		EV.db().shown = 0
		EV.showGrid(false)
	else
		EV.db().shown = 1
		EV.showGrid(true)
	end
end
EVH.toggleGrid = EV.toggleGrid

function EV.initFont()
	if GameFontNormalSmall and GameFontNormalSmall.GetFont then
		local p, sz = GameFontNormalSmall:GetFont()
		if p then FONT_PATH = p end
		if sz then FONT_SIZE = sz end
	end
	if not FONT_PATH then FONT_PATH = "Fonts\\ARKai_T.ttf" end
	if not FONT_SIZE then FONT_SIZE = 11 end
end

function EV.buildAll()
	EV.initFont()
	db = EV.db()
	buildGrid()
	buildOptionsFrame()
	buildMinimap()
	if db.pos then
		EVH.grid.GridFrame:ClearAllPoints()
		EVH.grid.GridFrame:SetPoint(db.pos.a or "CENTER", UIParent, db.pos.a or "CENTER", db.pos.x or 0, db.pos.y or 0)
	end
	if db.optpos then
		optFrame:ClearAllPoints()
		optFrame:SetPoint(db.optpos.a or "CENTER", UIParent, db.optpos.a or "CENTER", db.optpos.x or 0, db.optpos.y or 0)
	end
	if db.shown == 1 then
		EV.showGrid(true)
	else
		EV.showGrid(false)
	end
end

EVH.rebuildLayout = EV.rebuildLayout
EVH.showGrid = EV.showGrid
EVH.gridShown = EV.gridShown
EVH.buildAll = EV.buildAll
EVH.refreshOptions = EV.refreshOptions
EVH.toggleOptions = EV.toggleOptions
EVH.showOptions = EV.showOptions
