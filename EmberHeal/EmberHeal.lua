-- =============================================================
-- EmberHeal — HealBot-style healing frame for Emberveil
-- Client: Emberveil (1.12.1 client / Lua 5.1)
-- API notes (https://emberveil.org/wiki/lua):
--   * Emberveil does NOT protect casting functions ("No widget methods in
--     this client are protected"; only explicitly-flagged globals are). So we
--     cast by spell name: TargetUnit(unit) + CastSpellByName(name), resolved
--     from the bound action slot via GetActionInfo/GetSpellName. UseAction is
--     kept only as a fallback when a slot has no spell (item/macro/empty).
--   * UnitBuff(unit, index) / UnitDebuff(unit, index) are 1-BASED and
--     return (texture, stacks[, dispelType]) -> icons identified by
--     texture path basename.
--   * No UnitThreatSituation: aggro uses target-of-target + combat flag.
--   * Buttons have no *FontObject methods here: SetText + Button:SetFont().
-- =============================================================

-- =============================================================
-- Client-compat shim: GetDifficultyColor
--
-- The client's own Interface/FrameXML/TargetFrame.lua calls the global
-- GetDifficultyColor(), which this client never defines:
--
--   [string "Interface/FrameXML/TargetFrame.lua"]:130:
--   attempt to call global 'GetDifficultyColor' (a nil value)
--     TargetFrame_CheckLevel (TargetFrame.lua:130)
--     TargetFrame_Update     (TargetFrame.lua:41)
--     TargetFrame_OnLoad     (TargetFrame.lua:20)
--
-- That is not only noise. The target-change dispatch is synchronous, so
-- the error propagates straight back out of TargetUnit()/SetTarget() and
-- aborts whatever the caller was doing. Click-casting targets a unit
-- first, so it died inside TargetUnit() and never reached the spell.
--
-- The classic API hands back a colour TABLE of r/g/b floats (the shape
-- classic frames use: local color = GetDifficultyColor(level);
-- text:SetVertexColor(color.r, color.g, color.b)), so that is what is
-- returned here.
--
-- Installed two ways on purpose: the plain assignment covers the normal
-- case where addon code shares the client's global environment, and the
-- client's own setglobal() covers the case where it does not.
-- =============================================================
local function installDifficultyColor()
	local fn = function(level)
		local lv = (type(UnitLevel) == "function" and UnitLevel("player")) or 1
		local diff = (tonumber(level) or lv) - lv
		local green = 10
		if type(GetQuestGreenRange) == "function" then
			local okq, g = pcall(GetQuestGreenRange)
			if okq and type(g) == "number" and g > 0 then green = g end
		end
		local c
		if diff >= 5 then
			c = { r = 1.00, g = 0.10, b = 0.10 }     -- far above you
		elseif diff >= 3 then
			c = { r = 1.00, g = 0.50, b = 0.25 }     -- orange
		elseif diff >= -2 then
			c = { r = 1.00, g = 1.00, b = 0.00 }     -- yellow
		elseif diff >= -green then
			c = { r = 0.25, g = 0.75, b = 0.25 }     -- green
		else
			c = { r = 0.50, g = 0.50, b = 0.50 }     -- grey (no xp)
		end
		c.font = "QuestDifficulty_Standard"
		return c
	end
	GetDifficultyColor = fn
	if type(setglobal) == "function" then
		pcall(setglobal, "GetDifficultyColor", fn)
	end
	return fn
end
installDifficultyColor()

-- (1.0.22) The modal script-error box (the GetDifficultyColor popup at every
-- login/reload) is not gated by any CVar -- SetCVar("scriptErrors","0") is
-- accepted but the box still shows. Last lever: if the engine honors Lua's
-- seterrorhandler, take over error reporting and route it into the diag
-- trace instead of a modal dialog. This cannot stop the error itself (it
-- fires during FrameXML bootstrap, before addons load), but if the box is
-- displayed after the addon stage this handler intercepts it.
pcall(function()
	if type(seterrorhandler) == "function" then
		seterrorhandler(function(err)
			if EVH and EVH.diag then
				EVH.diag("err: " .. string.sub(tostring(err), 1, 160))
			end
		end)
	end
end)

EVH = EVH or {}

local _G = _G
local floor = math.floor
local GetTime = GetTime
local strfind = string.find
local strsub = string.sub
local strlower = string.lower
local strformat = string.format

EVH.VERSION = "1.0.22"

-- -------------------------------------------------------------
-- Localization (zhCN / enUS, picked by client locale)
-- -------------------------------------------------------------
local localeTag = "zh"
if GetLocale then
	local okL, l = pcall(GetLocale)
	if okL and type(l) == "string" and l ~= "" then localeTag = strlower(l) end
end
EVH.locale = localeTag
local isCN = (strsub(localeTag, 1, 2) == "zh")

local L_ZH = {
	title        = "EmberHeal",
	tabDisplay   = "显示",
	tabClicks    = "点击施法",
	tabWatch     = "监视",
	locked       = "锁定",
	unlocked     = "未锁定",
	on           = "开",
	off          = "关",
	scale        = "缩放",
	barSize      = "尺寸",
	barSmall     = "小",
	barMedium    = "中",
	barLarge     = "大",
	fontSize     = "字号",
	lowHp        = "低血阈值",
	colorScheme  = "颜色",
	colClass     = "职业色",
	colGradient  = "血量渐变",
	colWhite     = "纯白",
	showPct      = "显示百分比",
	showHealth   = "显示血量",
	showDebuffs  = "显示减益",
	showBuffW    = "增益监视",
	showRange    = "范围提示",
	showAggro    = "仇恨提示",
	rangeDist    = "范围判定",
	resetPos     = "重置位置",
	testMode     = "测试模式",
	close        = "关闭",
	bindTitle    = "点击施法绑定(点击切换槽位/右键清除)",
	slotColon    = "槽",
	autoBind     = "自动建议",
	clearBinds   = "清空全部",
	watchBuffT   = "增益监视",
	watchDebT    = "重要减益",
	addTargetBuf = "添加目标第1个增益",
	addTargetDeb = "添加目标第1个减益",
	clearAll     = "清空列表",
	empty        = "空",
	notUsable    = "技能不可用",
	outOfRange   = "超出范围",
	dead         = "目标已死亡",
	slotInvalid  = "绑定的动作条槽位已失效，请重新设置",
	noTarget     = "无法选中该目标",
	castOn       = "对",
	noGroup      = "未组队",
	help         = "/eh 开关面板 /eh opts 选项 /eh lock 锁定 /eh reset 重置 /eh test 测试",
	options      = "选项",
	mmGlyph      = "治",
	mmTip1       = "左键: 开关治疗框架",
	mmTip2       = "右键 / Shift+左键: 选项面板",
	mmTip3       = "拖动: 沿小地图移动",
	uDead        = "死亡",
	uOffline     = "离线",
	uOor         = "超出范围",
	uAggro       = "被攻击",
	uDebuff      = "减益: ",
	clickLeft    = "左键",
	clickLeftShift = "左键+Shift",
	clickLeftCtrl  = "左键+Ctrl",
	clickLeftAlt   = "左键+Alt",
	clickRight     = "右键",
	clickRightShift = "右键+Shift",
	clickRightCtrl  = "右键+Ctrl",
	clickRightAlt   = "右键+Alt",
	clickMiddle     = "中键",
	clickSide4      = "侧键4",
	clickSide4Shift = "侧键4+Shift",
	clickSide5      = "侧键5",
	clickSide5Shift = "侧键5+Shift",
	buffHint     = "(缺失显示黄点)",
	debHint      = "(整格红高亮)",
	lockPos      = "锁定位置",
	midCast      = "中键施法",
	clickDbg     = "点击调试",
	tipPct       = "在框体右下角显示血量百分比",
	tipHealth    = "在框体右下角显示当前血量数值(可与百分比同开)",
	tipDebuff    = "可驱散的减益在框体右上角显示彩色方块与类型(魔/疾/毒/咒)",
	tipBuffW     = "\"监视\"页列表中的增益缺失时,框体左上角显示黄点",
	tipRange     = "队友超出施法距离时,其框体整体变暗",
	tipAggro     = "队友正被怪物攻击时,其框体显示红色边框",
	tipLock      = "锁定后治疗框架不可拖动,防止战斗中误拖",
	tipClickDbg  = "排查鼠标键无反应:开启后点击治疗格子会在聊天框输出各环节参数(事件/按键名/绑定槽位),设置跨重载保存",
	tipMidCast   = "释放引擎占用的鼠标中键(原绑定会被记住,关闭时自动还原并保存),否则点击施法收不到中键",
	midNoApi     = "引擎缺少按键绑定 API,中键施法不可用",
	midFreed     = "已释放中键的引擎绑定(关闭本选项可还原)",
	midRestored  = "已还原中键绑定",
	gMagic       = "魔",
	gDisease     = "疾",
	gPoison      = "毒",
	gCurse       = "咒",
}

local L_EN = {
	title        = "EmberHeal",
	tabDisplay   = "Display",
	tabClicks    = "Click Cast",
	tabWatch     = "Watch",
	locked       = "Locked",
	unlocked     = "Unlocked",
	on           = "On",
	off          = "Off",
	scale        = "Scale",
	barSize      = "Size",
	barSmall     = "Small",
	barMedium    = "Medium",
	barLarge     = "Large",
	fontSize     = "Font",
	lowHp        = "Low HP",
	colorScheme  = "Color",
	colClass     = "Class",
	colGradient  = "HP gradient",
	colWhite     = "White",
	showPct      = "HP percent",
	showHealth   = "HP number",
	showDebuffs  = "Debuff icons",
	showBuffW    = "Buff watch",
	showRange    = "Range dim",
	showAggro    = "Aggro border",
	rangeDist    = "Range check",
	resetPos     = "Reset position",
	testMode     = "Test mode",
	close        = "Close",
	bindTitle    = "Click-cast binds (click to cycle slot / right-click to clear)",
	slotColon    = "Slot",
	autoBind     = "Auto assign",
	clearBinds   = "Clear all",
	watchBuffT   = "Buff watch",
	watchDebT    = "Key debuffs",
	addTargetBuf = "Add target's 1st buff",
	addTargetDeb = "Add target's 1st debuff",
	clearAll     = "Clear list",
	empty        = "empty",
	notUsable    = "Spell not usable",
	outOfRange   = "Out of range",
	dead         = "Target is dead",
	slotInvalid  = "The bound action slot is no longer valid, please rebind",
	noTarget     = "Cannot target that unit",
	castOn       = "Cast on ",
	noGroup      = "Not in a group",
	help         = "/eh toggle grid, /eh opts options, /eh lock lock, /eh reset reset, /eh test test",
	options      = "Options",
	mmGlyph      = "+",
	mmTip1       = "Left: toggle healing grid",
	mmTip2       = "Right / Shift+Left: options panel",
	mmTip3       = "Drag: orbit the minimap",
	uDead        = "Dead",
	uOffline     = "Offline",
	uOor         = "Out of range",
	uAggro       = "Aggro",
	uDebuff      = "Debuff: ",
	clickLeft    = "Left",
	clickLeftShift = "Left+Shift",
	clickLeftCtrl  = "Left+Ctrl",
	clickLeftAlt   = "Left+Alt",
	clickRight     = "Right",
	clickRightShift = "Right+Shift",
	clickRightCtrl  = "Right+Ctrl",
	clickRightAlt   = "Right+Alt",
	clickMiddle     = "Middle",
	clickSide4      = "Mouse 4",
	clickSide4Shift = "Mouse 4+Shift",
	clickSide5      = "Mouse 5",
	clickSide5Shift = "Mouse 5+Shift",
	buffHint     = " (missing = yellow dot)",
	debHint      = " (red highlight)",
	lockPos      = "Lock position",
	midCast      = "Middle-click cast",
	clickDbg     = "Click debug",
	tipPct       = "Show HP percent at the bottom-right of each cell",
	tipHealth    = "Show current HP at the bottom-right of each cell (can combine with percent)",
	tipDebuff    = "Dispellable debuffs show as colored squares with a type glyph at the top-right",
	tipBuffW     = "Yellow dot at the top-left when a buff from the Watch list is missing",
	tipRange     = "Dim the whole cell when the member is out of casting range",
	tipAggro     = "Red border on the cell of a member being attacked",
	tipLock      = "Lock the healing grid so it cannot be dragged by mistake",
	tipClickDbg  = "Diagnose dead mouse buttons: clicking a cell prints event/button/slot info to chat; persists across reloads",
	tipMidCast   = "Frees the engine's middle-button binding (remembered and restored when turned off); otherwise click-cast never sees the middle button",
	midNoApi     = "Engine lacks the binding API; middle-click cast unavailable",
	midFreed     = "Released engine binding on middle button (turn off to restore)",
	midRestored  = "Restored middle button binding",
	gMagic       = "M",
	gDisease     = "D",
	gPoison      = "P",
	gCurse       = "C",
}

local L = isCN and L_ZH or L_EN
-- fill gaps so a missing translation never renders as nil
for k, v in pairs(L_ZH) do
	if L[k] == nil then L[k] = v end
end
EVH.L = L

-- -------------------------------------------------------------
-- Class data
-- -------------------------------------------------------------
local CLASS_COLOR = {
	WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 },
	ROGUE   = { 1.00, 0.96, 0.41 }, PRIEST  = { 1.00, 1.00, 1.00 }, SHAMAN = { 0.00, 0.44, 0.87 },
	MAGE    = { 0.41, 0.80, 0.94 }, WARLOCK = { 0.58, 0.51, 0.79 }, DRUID  = { 1.00, 0.49, 0.04 },
}
local CLASS_FALLBACK
if isCN then
	CLASS_FALLBACK = {
		WARRIOR = "战", PALADIN = "骑", HUNTER = "猎", ROGUE = "盗",
		PRIEST = "牧", SHAMAN = "萨", MAGE = "法", WARLOCK = "术", DRUID = "德",
	}
else
	CLASS_FALLBACK = {
		WARRIOR = "W", PALADIN = "P", HUNTER = "H", ROGUE = "R",
		PRIEST = "Pr", SHAMAN = "Sh", MAGE = "M", WARLOCK = "L", DRUID = "D",
	}
end
local CLASS_LOCAL = {}

function EVH.classColor(token)
	local c = token and CLASS_COLOR[token]
	if c then return c[1], c[2], c[3] end
	return 0.8, 0.8, 0.8
end

function EVH.classLocal(token)
	if token and CLASS_LOCAL[token] then return CLASS_LOCAL[token] end
	if token and CLASS_FALLBACK[token] then return CLASS_FALLBACK[token] end
	return token or "?"
end

-- -------------------------------------------------------------
-- Dispel type colors (Magic/Disease/Poison/Curse)
-- -------------------------------------------------------------
local DISPEL_COLOR = {
	Magic   = { 0.85, 0.35, 0.95 },
	Disease = { 0.35, 0.85, 0.35 },
	Poison  = { 0.20, 0.55, 0.25 },
	Curse   = { 0.75, 0.55, 0.90 },
}
function EVH.dispelColor(tok)
	local c = tok and DISPEL_COLOR[tok]
	if c then return c[1], c[2], c[3] end
	return 0.55, 0.55, 0.55
end

-- -------------------------------------------------------------
-- Defaults
-- -------------------------------------------------------------
local DEFAULT_DB = {
	opts = {
		scale        = 1.0,
		barSize      = 2,     -- 1 small / 2 medium / 3 large
		fontSize     = 11,
		lowHp        = 35,    -- low health threshold %
		colorScheme  = 1,     -- 1 class / 2 gradient / 3 white
		showPct      = 1,
		showHealth   = 1,
		showDebuffs  = 1,
		showBuffW    = 1,
		showRange    = 1,
		showAggro    = 1,
		numDebuffs   = 4,
		rangeDist    = 4,     -- CheckInteractDistance bucket
		locked       = 0,
		showSolo     = 1,
		clickDebug   = 0,    -- 点击链路调试输出(选项面板"显示"页开关,跨重载保持)
		midFree      = 0,    -- 1 = 已释放引擎中键绑定,供点击施法使用
	},
	clicks  = {},    -- key(button+modifier) -> action slot
	buffWatch = {},  -- { tex basename, ... }
	highDebuffs  = {}, -- { tex basename, ... }
	pos  = nil,
	mmAngle = 210,   -- minimap button orbit angle (degrees)
	shown = 0,
}
EVH.DEFAULT_DB = DEFAULT_DB

local db
EVH.db = function() return db end

function EVH.loadDB()
	if not EmberHeal_DB then EmberHeal_DB = {} end
	db = EmberHeal_DB
	for k, v in pairs(DEFAULT_DB) do
		if db[k] == nil then
			if type(v) == "table" then db[k] = {} else db[k] = v end
		end
	end
	if type(db.opts) ~= "table" then db.opts = {} end
	for k, v in pairs(DEFAULT_DB.opts) do
		if db.opts[k] == nil then db.opts[k] = v end
	end
	if type(db.clicks) ~= "table" then db.clicks = {} end
	if type(db.buffWatch) ~= "table" then db.buffWatch = {} end
	if type(db.highDebuffs) ~= "table" then db.highDebuffs = {} end
	-- 中键在该客户端不会到达 UI,清掉历史遗留的中键绑定
	if db.clicks then
		local stale = {}
		for k in pairs(db.clicks) do
			if strfind(tostring(k), "MiddleButton", 1, true) then stale[#stale + 1] = k end
		end
		for _, k in ipairs(stale) do db.clicks[k] = nil end
	end
	-- 排查中键期间曾强制开一次调试(1.0.10);1.0.11 起自动恢复关闭,显示页可手动开
	if db.opts.clickDebugForced == 1 then
		db.opts.clickDebug = 0
		db.opts.clickDebugForced = 2
	end
	EVH.clickDebug = (db.opts.clickDebug == 1)
	EVH.diag("load v" .. tostring(EVH.VERSION) .. " api: " .. EVH.diagApiProbe())
end

-- -------------------------------------------------------------
-- Helpers
-- -------------------------------------------------------------
function EVH.echo(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff4dd2ffEmberHeal:|r " .. tostring(msg))
	end
end

-- debug output: chat + center-screen error frame (hard to miss)
function EVH.dbug(msg)
	EVH.echo(msg)
	if UIErrorsFrame and UIErrorsFrame.AddMessage then
		pcall(UIErrorsFrame.AddMessage, UIErrorsFrame, "|cffffcc00" .. tostring(msg) .. "|r", 1, 0.8, 0.2, 1, 4)
	end
end

-- -------------------------------------------------------------
-- Persistent diagnostic trace (1.0.17-local)
-- Appends to db.diag, which the client serialises into
-- SavedVariables/EmberHeal.lua at logout/reload, so the log can be read
-- from disk after the fact -- no chat transcription needed. Capped at
-- 400 lines; /eh diagclear wipes it. Consecutive duplicate lines are
-- collapsed.
-- -------------------------------------------------------------
local DIAG_APIS = {
	"GetActionInfo", "GetSpellName", "HasAction", "IsUsableAction",
	"IsActionInRange", "UseAction", "CastSpellByName", "CastSpell",
	"TargetUnit", "TargetByName", "ClearTarget", "UnitIsUnit",
	"UnitExists", "UnitName", "UnitIsDeadOrGhost", "GetActionCooldown",
}

function EVH.diag(msg)
	if not db then return end
	if type(db.diag) ~= "table" then db.diag = {} end
	local t = 0
	if type(GetTime) == "function" then t = GetTime() end
	local line = string.format("[%07.1f] %s", t, tostring(msg))
	local n = #db.diag
	if n == 0 or db.diag[n] ~= line then
		n = n + 1
		db.diag[n] = line
		if n > 400 then table.remove(db.diag, 1) end
	end
	if EVH.clickDebug then EVH.echo("|cffffcc00" .. line .. "|r") end
end

-- one line summarising which cast-path APIs this client actually provides
-- (F = function, - = missing, other prefixes for odd types)
function EVH.diagApiProbe()
	local parts = {}
	for i, n in ipairs(DIAG_APIS) do
		local v
		if type(getglobal) == "function" then v = getglobal(n) end
		if v == nil and _G then v = _G[n] end
		local t = type(v)
		parts[i] = n .. "=" .. (t == "function" and "F" or (t == "nil" and "-" or string.sub(t, 1, 2)))
	end
	return table.concat(parts, " ")
end

function EVH.basename(tex)
	if not tex then return nil end
	local b = tostring(tex)
	while strfind(b, "[\\/]") do
		b = strsub(b, strfind(b, "[\\/]") + 1)
	end
	return strlower(b)
end

-- -------------------------------------------------------------
-- Roster
-- -------------------------------------------------------------
EVH.roster = {}

function EVH.buildRoster()
	local out = {}
	local n = GetNumRaidMembers()
	if n > 0 then
		for i = 1, n do
			local name, rank, subgroup, level, clsLocal, clsFile, zone, online, isDead = GetRaidRosterInfo(i)
			if name then
				local unit = "raid" .. i
				if clsFile then CLASS_LOCAL[clsFile] = clsLocal end
				out[#out + 1] = {
					unit = unit, name = name, class = clsFile,
					subgroup = subgroup or 1, online = online, isDead = isDead,
				}
			end
		end
	else
		local me = UnitName("player")
		local clsLocal, myClass = UnitClass("player")
		if myClass then CLASS_LOCAL[myClass] = clsLocal end
		out[#out + 1] = { unit = "player", name = me, class = myClass, subgroup = 1 }
		local p = GetNumPartyMembers()
		for i = 1, p do
			local unit = "party" .. i
			local nm = UnitName(unit)
			local cLocal, c2 = UnitClass(unit)
			if nm then
				if c2 then CLASS_LOCAL[c2] = cLocal end
				out[#out + 1] = { unit = unit, name = nm, class = c2, subgroup = 1 }
			end
		end
	end
	table.sort(out, function(a, b)
		if a.subgroup ~= b.subgroup then return a.subgroup < b.subgroup end
		return a.name < b.name
	end)
	EVH.roster = out
end

function EVH.rosterCount() return #EVH.roster end

function EVH.maxSubgroup()
	local m = 1
	for _, r in ipairs(EVH.roster) do
		if r.subgroup and r.subgroup > m then m = r.subgroup end
	end
	return m
end

-- -------------------------------------------------------------
-- Unit snapshot (fills member table with display data)
-- -------------------------------------------------------------
function EVH.snapshot(m)
	local unit = m.unit
	local hp = UnitHealth(unit)
	local mx = UnitHealthMax(unit)
	m.hp = hp
	m.max = mx
	m.pct = (mx > 0) and (hp / mx * 100) or 0
	m.dead = not not UnitIsDeadOrGhost(unit)
	m.offline = (UnitIsConnected(unit) == false)
	m.inCombat = not not UnitAffectingCombat(unit)
	-- mana
	m.mana = UnitMana(unit)
	m.manaMax = UnitManaMax(unit)

	-- range
	m.oor = false
	if db.opts.showRange == 1 and not m.dead and not m.offline and unit ~= "player" then
		m.oor = not EVH.inRange(unit)
	end

	-- aggro (target-of-target)
	m.aggro = false
	if db.opts.showAggro == 1 and m.inCombat and UnitExists("target")
	   and not UnitIsFriend("player", "target")
	   and UnitIsUnit("targettarget", unit) then
		m.aggro = true
	end

	-- debuffs
	m.debuffs = {}
	if db.opts.showDebuffs == 1 then
		local list = {}
		local hl = nil
		for i = 1, 16 do
			local tex, stacks, dispel = UnitDebuff(unit, i)
			if not tex then break end
			local base = EVH.basename(tex)
			local e = { tex = tex, base = base, dispel = dispel }
			if #list < db.opts.numDebuffs then list[#list + 1] = e end
			if base and db.highDebuffs and db.highDebuffs[base] then hl = true end
		end
		m.debuffs = list
		m.highDebuff = hl
	else
		m.highDebuff = nil
	end

	-- buff watch
	m.missingBuffs = {}
	if db.opts.showBuffW == 1 and next(db.buffWatch) then
		local present = {}
		local i = 1
		while i <= 32 do
			local tex = UnitBuff(unit, i)
			if not tex then break end
			local base = EVH.basename(tex)
			if base then present[base] = true end
			i = i + 1
		end
		local missing = {}
		local seen = {}
		for base in pairs(db.buffWatch) do
			if not present[base] and not seen[base] then
				missing[#missing + 1] = base
				seen[base] = true
			end
		end
		m.missingBuffs = missing
	end
end

-- range check via CheckInteractDistance (classic-style), guarded
function EVH.inRange(unit)
	if not unit or unit == "player" then return true end
	if not UnitExists(unit) then return false end
	local ok, res = pcall(CheckInteractDistance, unit, db.opts.rangeDist or 4)
	if ok and res then return true end
	-- cannot determine range (API unavailable) -> assume in range
	return true
end

-- -------------------------------------------------------------
-- Click-casting
-- -------------------------------------------------------------
local BUTTON_KEYS = { "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5" }
local MOD_KEYS = { "", "Shift", "Ctrl", "Alt" }
EVH.BUTTON_KEYS = BUTTON_KEYS
EVH.MOD_KEYS = MOD_KEYS

function EVH.clickKey(btn, mod)
	return tostring(btn) .. tostring(mod or "")
end

function EVH.bindFor(btn, mod)
	return db.clicks[EVH.clickKey(btn, mod)]
end

function EVH.occupiedSlots()
	local out = {}
	for slot = 1, 119 do
		if HasAction(slot) then out[#out + 1] = slot end
	end
	return out
end

local actionTip
function EVH.slotName(slot)
	if not slot then return L.empty end
	if not actionTip then
		actionTip = CreateFrame("GameTooltip", "EVH_Tip", nil, "GameTooltipTemplate")
		actionTip:SetOwner(UIParent, "ANCHOR_NONE")
	end
	local name
	if actionTip:SetAction(slot) and actionTip:NumLines() > 0 then
		local fs = _G["EVH_TipTextLeft1"]
		if fs then name = fs:GetText() end
	end
	actionTip:Hide()
	return name
end

-- Resolve a bound action slot to its spell (name + id). Emberveil does NOT
-- protect casting functions (wiki: "No widget methods in this client are
-- protected"), so casting by name/id is the reliable path here. Returns nil
-- when the slot holds no spell (item/macro/empty) so callers can keep
-- UseAction.
function EVH.slotSpellInfo(slot, verbose)
	local okT, t, id = pcall(GetActionInfo, slot)
	if verbose then
		EVH.diag("slotInfo slot=" .. tostring(slot)
			.. " gai=" .. type(GetActionInfo)
			.. " type=" .. tostring(t) .. " id=" .. tostring(id)
			.. (okT and "" or (" gaiErr=" .. tostring(t))))
	end
	if not okT then return nil end
	if t ~= "spell" or not id then return nil end
	local okN, nm = pcall(GetSpellName, id, "spell")
	if not okN then nm = nil end
	if nm == "" then nm = nil end
	if verbose and not nm then
		EVH.diag("spellName empty: gsn=" .. type(GetSpellName) .. " id=" .. tostring(id))
	end
	return nm, id
end

function EVH.slotSpellName(slot)
	local nm = EVH.slotSpellInfo(slot)
	return nm
end

function EVH.setBind(key, slot)
	db.clicks[key] = slot
end

function EVH.clearBind(key)
	db.clicks[key] = nil
end

function EVH.clearAllBinds()
	db.clicks = {}
end

-- cycle a binding to the next occupied action slot
function EVH.cycleBind(key)
	local list = EVH.occupiedSlots()
	if #list == 0 then
		db.clicks[key] = nil
		return nil
	end
	local cur = db.clicks[key]
	local nextIdx = 1
	for i, s in ipairs(list) do
		if s == cur then nextIdx = i + 1 break end
	end
	if nextIdx > #list then
		db.clicks[key] = nil
		return nil
	end
	db.clicks[key] = list[nextIdx]
	return list[nextIdx]
end

-- Set the target without letting a client-side UI error abort the caller.
-- TargetUnit() dispatches the target change synchronously, and this client's
-- FrameXML/TargetFrame.lua throws inside that dispatch (it calls a global
-- the client does not define). That error used to propagate straight out of
-- TargetUnit() and kill the click before the spell was ever cast. The
-- target itself is already set when it happens, so an error is only fatal
-- when the target really did not change -- hence the UnitIsUnit() check.
-- Returns: ok, err
function EVH.setTargetSafe(unit)
	local ok, err = pcall(TargetUnit, unit)
	if ok then
		EVH.diag("setTarget " .. tostring(unit) .. " ok")
		return true, nil
	end
	local okU, same = pcall(UnitIsUnit, "target", unit)
	EVH.diag("setTarget " .. tostring(unit) .. " threw; same=" .. tostring(same)
		.. " err=" .. string.sub(tostring(err) or "?", 1, 100))
	if okU and same then return true, err end
	return false, err
end

-- cast a bound action slot on a unit (safe target juggling).
-- Primary path: cast by spell name via CastSpellByName (works in Emberveil,
-- which does not protect casting functions). Falls back to UseAction(slot)
-- when the slot cannot be resolved to a spell name (item/macro/empty).
function EVH.castUnit(unit, slot)
	EVH.diag("castUnit unit=" .. tostring(unit) .. " slot=" .. tostring(slot))
	if not slot then
		EVH.setTargetSafe(unit)
		return
	end
	-- every client API in here is probed first: a missing global must log a
	-- diag line and degrade gracefully, not abort the whole click
	local okE, ex = pcall(UnitExists, unit)
	if not okE then
		EVH.diag("UnitExists API err: " .. tostring(ex))
	elseif not ex then
		EVH.diag("abort: unit does not exist")
		return
	end
	local okH, ha = pcall(HasAction, slot)
	if not okH then EVH.diag("HasAction API err: " .. tostring(ha)) ha = true end
	if not ha then
		EVH.diag("abort: slot " .. tostring(slot) .. " has no action")
		EVH.echo(L.slotInvalid)
		return
	end
	local okD, dead = pcall(UnitIsDeadOrGhost, unit)
	if not okD then EVH.diag("UnitIsDeadOrGhost API err: " .. tostring(dead)) dead = false end
	if dead then
		EVH.diag("abort: unit dead")
		EVH.echo(L.dead)
		return
	end

	-- try to cast by resolved spell name/id (target-preserving).
	-- Three tiers so a single rejected API cannot kill click-casting:
	--   1) CastSpellByName(name)   2) CastSpell(id, "spell")   3) UseAction(slot)
	-- The target is set once, up front: re-targeting per tier would fire the
	-- client's target-change dispatch again for nothing.
	local castByName = function(targetUnit)
		local nm, id = EVH.slotSpellInfo(slot, true)
		if not nm and not id then
			-- GetActionInfo/GetSpellName path empty: fall back to naming the
			-- action through its tooltip, which still yields a castable name
			nm = EVH.slotName(slot)
			if nm then EVH.diag("slotInfo empty; tooltip name=" .. tostring(nm)) end
		end
		if not nm and not id then
			EVH.diag("castByName: no spell resolvable for slot " .. tostring(slot))
			return false
		end
		local okT, terr = EVH.setTargetSafe(targetUnit)
		if not okT then
			EVH.diag("abort: target not set: " .. string.sub(tostring(terr) or "?", 1, 100))
			if EVH.clickDebug then
				EVH.dbug("dbg target failed: " .. tostring(terr))
			end
			return false
		end
		local okC, cerr = pcall(function()
			if nm then
				CastSpellByName(nm)
			else
				CastSpell(id, "spell")
			end
		end)
		if okC then
			EVH.diag("cast1 ok spell=" .. tostring(nm or id) .. " on=" .. tostring(targetUnit))
			if EVH.clickDebug then
				EVH.dbug("dbg cast: slot=" .. tostring(slot) .. " spell=" .. tostring(nm or id) .. " on=" .. tostring(targetUnit))
			end
			return true
		end
		EVH.diag("cast1 FAILED spell=" .. tostring(nm or id)
			.. " err=" .. string.sub(tostring(cerr) or "?", 1, 120))
		-- tier 2: cast by spell id (the name lookup can come back empty)
		if id then
			okC, cerr = pcall(function() CastSpell(id, "spell") end)
			if okC then
				EVH.diag("cast2(id) ok id=" .. tostring(id) .. " on=" .. tostring(targetUnit))
				if EVH.clickDebug then
					EVH.dbug("dbg cast(id): slot=" .. tostring(slot) .. " id=" .. tostring(id) .. " on=" .. tostring(targetUnit))
				end
				return true
			end
			EVH.diag("cast2(id) FAILED err=" .. string.sub(tostring(cerr) or "?", 1, 120))
		end
		if EVH.clickDebug then
			EVH.dbug("dbg cast failed slot=" .. tostring(slot) .. " spell=" .. tostring(nm or id) .. " err=" .. tostring(cerr))
		end
		return false
	end

	-- restore the previous target; the target-change dispatch can throw here
	-- too, and a failed restore must not mask a cast that already happened
	local restore = function(prevName)
		EVH.diag("restore prev=" .. tostring(prevName)
			.. " tbn=" .. type(TargetByName) .. " ct=" .. type(ClearTarget))
		pcall(function()
			if prevName then TargetByName(prevName) else ClearTarget() end
		end)
	end

	if unit == "player" then
		local prevName = UnitExists("target") and UnitName("target") or nil
		if not castByName("player") then
			EVH.diag("self cast by name failed; UseAction fallback")
			local okUs, usable = pcall(IsUsableAction, slot)
			if not okUs then EVH.diag("IsUsableAction API err: " .. tostring(usable)) usable = true end
			if usable then
				local okA, aerr = pcall(UseAction, slot, nil, 1)
				EVH.diag("useAction(self) ok=" .. tostring(okA)
					.. (okA and "" or (" err=" .. string.sub(tostring(aerr) or "?", 1, 100))))
			else
				EVH.diag("abort: self cast not usable")
				EVH.echo(L.notUsable)
			end
		end
		restore(prevName)
		return
	end

	local prevName = UnitExists("target") and UnitName("target") or nil
	if not castByName(unit) then
		EVH.diag("castByName failed; UseAction fallback")
		local okT = EVH.setTargetSafe(unit)
		local okU, same = pcall(UnitIsUnit, "target", unit)
		if not okT or not okU or not same then
			EVH.diag("abort: target not set in fallback (ok=" .. tostring(okT)
				.. " same=" .. tostring(same) .. ")")
			EVH.echo(L.noTarget)
			restore(prevName)
			return
		end
		local okR, inRange = pcall(IsActionInRange, slot)
		if not okR then EVH.diag("IsActionInRange API err: " .. tostring(inRange)) inRange = nil end
		if inRange == 0 then
			EVH.diag("abort: out of range")
			EVH.echo(L.outOfRange .. " [" .. (UnitName(unit) or "?") .. "]")
			restore(prevName)
			return
		end
		local okUs, usable = pcall(IsUsableAction, slot)
		if not okUs then EVH.diag("IsUsableAction API err: " .. tostring(usable)) usable = true end
		if not usable then
			EVH.diag("abort: not usable")
			EVH.echo(L.notUsable .. " [" .. (UnitName(unit) or "?") .. "]")
			restore(prevName)
			return
		end
		local okA, aerr = pcall(UseAction, slot)
		EVH.diag("useAction ok=" .. tostring(okA)
			.. (okA and "" or (" err=" .. string.sub(tostring(aerr) or "?", 1, 100))))
	end
	restore(prevName)
end

-- button name resolution for OnClick handlers
local BUTTON_ALIASES = {
	MiddleMouse = "MiddleButton",
	Mouse3      = "MiddleButton",
	Button3     = "MiddleButton",
	Mouse4      = "Button4",
	XButton1    = "Button4",
	Mouse5      = "Button5",
	XButton2    = "Button5",
}
function EVH.resolveButton(a1, arg1)
	local v = a1
	if type(v) ~= "string" then v = arg1 end
	if type(v) == "string" then
		for _, b in ipairs(BUTTON_KEYS) do
			if v == b then return v end
		end
		if BUTTON_ALIASES[v] then return BUTTON_ALIASES[v] end
	end
	return "LeftButton"
end

local function modDown(name)
	local f = _G[name]
	if type(f) ~= "function" then return false end
	local ok, r = pcall(f)
	return ok and not not r or false
end

function EVH.currentMods()
	local mod = ""
	if modDown("IsShiftKeyDown") then mod = mod .. "Shift" end
	if modDown("IsControlKeyDown") then mod = mod .. "Ctrl" end
	if modDown("IsAltKeyDown") then mod = mod .. "Alt" end
	return mod
end

-- -------------------------------------------------------------
-- Middle-click casting: the engine hands BUTTON3 to whatever command
-- is bound to it (e.g. MOVEFORWARD) BEFORE the UI ever sees it, so
-- a bound middle button never reaches unit buttons. Per the wiki,
-- SetBinding("BUTTON3") may unbind it and SaveBindings persists it;
-- only RunBinding is protected. Remember the old command so turning
-- the option off restores it.
-- -------------------------------------------------------------
function EVH.setMiddleCast(enable)
	if not SetBinding or not GetBindingAction then
		EVH.echo(L.midNoApi)
		return false
	end
	local okA, act = pcall(GetBindingAction, "BUTTON3")
	if not okA then return false end
	if enable then
		if act and act ~= "" then
			db.opts.midPrevCmd = act
			pcall(SetBinding, "BUTTON3")
			EVH.echo(L.midFreed .. ": " .. tostring(act))
		end
	else
		local prev = db.opts.midPrevCmd
		if prev and prev ~= "" and (not act or act == "") then
			pcall(SetBinding, "BUTTON3", prev)
			EVH.echo(L.midRestored .. ": " .. tostring(prev))
		end
		db.opts.midPrevCmd = nil
	end
	db.opts.midFree = enable and 1 or 0
	if SaveBindings and GetCurrentBindingSet then
		local okS, set = pcall(GetCurrentBindingSet)
		if okS and (set == 1 or set == 2) then pcall(SaveBindings, set) end
	end
	if EVH.clickDebug then
		EVH.dbug("dbg middlecast=" .. (enable and "on" or "off") .. " (BUTTON3=" .. tostring(act) .. ")")
	end
	return true
end

function EVH.applyMiddleCast()
	if db.opts.midFree == 1 then EVH.setMiddleCast(true) end
end

-- main click handler used by unit buttons
local function handleUnitClickImpl(button, a1, arg1)
	local unit = button.evhMember and button.evhMember.unit
	if not unit then
		EVH.diag("click with no evhMember unit")
		return
	end
	local btn = EVH.resolveButton(a1, arg1)
	local key = EVH.clickKey(btn, EVH.currentMods())
	local slot = db.clicks[key]
	EVH.diag("dispatch unit=" .. tostring(unit)
		.. " name=" .. tostring(button.evhMember.name)
		.. " btn=" .. tostring(btn) .. " key=" .. tostring(key)
		.. " slot=" .. tostring(slot))
	if EVH.clickDebug then
		EVH.dbug("dbg cast: unit=" .. tostring(unit) .. " btn=" .. tostring(btn) .. " slot=" .. tostring(slot) .. " spell=" .. tostring(EVH.slotSpellName(slot)))
	end
	if slot then
		EVH.castUnit(unit, slot)
	else
		EVH.diag("no bind for key=" .. tostring(key) .. "; targeting only")
		TargetUnit(unit)
	end
end

-- any error in the cast chain must surface in chat, never vanish silently
function EVH.handleUnitClick(button, a1, arg1)
	local ok, err = pcall(handleUnitClickImpl, button, a1, arg1)
	if not ok then
		EVH.diag("dispatch ERROR: " .. string.sub(tostring(err) or "?", 1, 160))
		EVH.echo("|cffff5050EmberHeal: " .. tostring(err) .. "|r")
	end
end

-- -------------------------------------------------------------
-- Buff / debuff watch lists
-- -------------------------------------------------------------
function EVH.listHas(list, base)
	if not list or not base then return false end
	return not not list[base]
end

function EVH.toggleListMember(list, base)
	if not list or not base then return end
	if list[base] then list[base] = nil else list[base] = true end
end

function EVH.addBuffWatchFromTarget()
	local tex = UnitBuff("target", 1)
	if not tex then tex = UnitBuff("player", 1) end
	if tex then
		EVH.toggleListMember(db.buffWatch, EVH.basename(tex))
		return EVH.basename(tex)
	end
	return nil
end

function EVH.addDebuffFromTarget()
	local tex = UnitDebuff("target", 1)
	if tex then
		EVH.toggleListMember(db.highDebuffs, EVH.basename(tex))
		return EVH.basename(tex)
	end
	return nil
end

function EVH.clearBuffWatch()
	db.buffWatch = {}
end

function EVH.clearHighDebuffs()
	db.highDebuffs = {}
end

-- -------------------------------------------------------------
-- Test mode / positions
-- -------------------------------------------------------------
EVH.testMode = false
function EVH.setTestMode(on)
	EVH.testMode = not not on
end

function EVH.savePos(frame, key)
	if not frame then return end
	local a, _, _, x, y = frame:GetPoint()
	db[key] = { a = a, x = x, y = y }
end

function EVH.resetPositions()
	db.pos = nil
	db.mmAngle = 210
	if EVH.minimapBtn and EVH.minimapBtn.evhPlace then EVH.minimapBtn.evhPlace() end
	if EVH.grid and EVH.grid.GridFrame then
		EVH.grid.GridFrame:ClearAllPoints()
		EVH.grid.GridFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	if EVH.optionsFrame then
		EVH.optionsFrame:ClearAllPoints()
		EVH.optionsFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
	if EVH.minimapBtn then
		EVH.minimapBtn:ClearAllPoints()
		EVH.minimapBtn:SetPoint("TOPLEFT", Minimap, "TOPLEFT", -4, 4)
	end
end

-- auto-bind free mouse combos (middle button never reaches the UI here,
-- side buttons are keybinding-only chords too -> stick to left/right + mods)
function EVH.autoSuggestBinds()
	local list = EVH.occupiedSlots()
	local order = {
		{ "LeftButton", "" }, { "RightButton", "" },
		{ "LeftButton", "Shift" }, { "RightButton", "Shift" },
		{ "LeftButton", "Ctrl" }, { "RightButton", "Ctrl" },
		{ "LeftButton", "Alt" }, { "RightButton", "Alt" },
	}
	local idx = 1
	for _, o in ipairs(order) do
		local slot = list[idx]
		if slot then
			db.clicks[EVH.clickKey(o[1], o[2])] = slot
			idx = idx + 1
		end
	end
	return idx - 1
end
