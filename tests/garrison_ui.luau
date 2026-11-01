--!nocheck
-- Garrisons and the fog of war in the interface (this fork, 2026-11-01): the station plan and its
-- radial items (Station / Reinforce / Disband), what Station and Disband send, an attack ordered near
-- a garrison previewed as launched from it, troop displays counting garrisons, and tile_owner under
-- the fog.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local GameState = require("../src/shared/Core/GameState")
local WorldMap = require("../src/shared/Core/WorldMap")
local Places = require("./world_places")
local UICtx = require("../src/client/UI/UICtx")
local UIInteract = require("../src/client/UI/UIInteract")

local fails = 0
local function expect(cond: any, what: string)
	if cond then
		print("  ok   " .. what)
	else
		fails += 1
		print("FAIL " .. what)
	end
end

local map = WorldMap.shared()
local W = Defs.W
local N = Defs.TILE_COUNT
local ME, ALLY, ENEMY = 239, 5, 9

local grid = buffer.create(N * 4)
local flags = buffer.create(N)
local function block(center: number, r: number, id: number)
	local cx, cy = center % W, center // W
	for dy = -r, r do
		for dx = -r, r do
			local t = (cy + dy) * W + (cx + dx) % W
			if map:is_contestable(t) then
				buffer.writei32(grid, t * 4, id)
			end
		end
	end
end
local home = Places.latlon_to_tile(54.0, 18.4)
local ally_home = home + 12 * W
block(home, 5, ME)
block(ally_home, 6, ALLY)
local enemy_home = home - 10 * W
block(enemy_home, 5, ENEMY)

local function snapshot(ally_troops: number, ally_cap: number)
	return {
		t = 1000,
		phase = Defs.PHASE_PLAYING,
		phase_left = 0,
		time_limit_ticks = 0,
		playing_since = 500,
		mirvs_launched = 0,
		winner = 0,
		over_reason = -1,
		owner = grid,
		flags = flags,
		built = {},
		owners = {
			{ ME, "Luke", 0x719bfaff, Defs.KIND_HUMAN, 0, true, 100, 1000000, 2000000, 3000000, 1000, 0, home },
			{
				ALLY,
				"United Kingdom",
				0xff4040ff,
				Defs.KIND_NATION,
				0,
				true,
				100,
				ally_troops,
				10000,
				ally_cap,
				1000,
				0,
				ally_home,
			},
			{ ENEMY, "France", 0x40c0ffff, Defs.KIND_NATION, 0, true, 100, 400000, 10000, 3000000, 1000, 0, enemy_home },
		},
		structs = {},
		roads = {},
		units = {},
		nukes = {},
		shells = {},
		sam_missiles = {},
		attacks = {},
		allies = { { ME, ALLY } },
		requests = {},
	}
end

local function setup(ally_troops: number, ally_cap: number)
	local gs = GameState.new(map)
	gs:load_snapshot(snapshot(ally_troops, ally_cap))
	gs.local_owner = ME
	local session = { mode = UICtx.MODE_SOLO, state = gs, lobby = {}, intents = {} }
	function session.send_intent(self: any, intent: any)
		table.insert(self.intents, intent)
	end
	local ctx = UICtx.new()
	ctx.session = session
	ctx.world = {}
	ctx.state = gs
	ctx.state_mode = UICtx.MODE_SOLO
	ctx.ratio = 0.35
	ctx.borders:bind(gs, ME)
	ctx.rules:recount()
	local inter = UIInteract.new(ctx)
	local floats = {}
	inter._float = function(_self: any, text: string, icon: string, _col: any, _pos: any)
		table.insert(floats, { text = text, icon = icon })
	end
	return ctx, session, inter, floats, gs
end


-- a tile of `a` whose 4-neighbour belongs to `b`
local function edge(gs: any, a: number, b: number): (number, number)
	for t = 0, N - 1 do
		if buffer.readi32(gs.owner, t * 4) == a then
			for _, n in { t - 1, t + 1, t - W, t + W } do
				if n >= 0 and n < N and buffer.readi32(gs.owner, n * 4) == b then
					return t, n
				end
			end
		end
	end
	return -1, -1
end

local function item(items: { any }, id: string): any
	for _, i in items do
		if i.id == id then
			return i
		end
	end
	return nil
end

print("garrisons in the interface")
do
	local ctx, session, inter, floats, gs = setup(100000, 3000000)
	local plan = ctx.rules:station_plan(home)
	expect(plan.ok and plan.troops == 350000 and plan.merge == nil, "station plan: 35% of a 1M reserve (" .. plan.troops .. ")")
	local items = ctx.rules:radial_items(home)
	local st = item(items, "station")
	expect(st ~= nil and st.ok and st.label == "Station" and st.troops == 350000, "radial: Station on own land")
	expect(item(items, "disband") == nil, "no Disband without a garrison")
	expect(inter:station_at(home, Vector2.zero), "station_at sends")
	local it = session.intents[#session.intents]
	expect(it and it.type == "station" and it.tile == home and math.abs(it.ratio - 0.35) < 1e-9, "a station intent at the tile, the order ratio")
	expect(string.find(floats[#floats].text, "Stationing", 1, true) ~= nil, "float: " .. floats[#floats].text)
	local plan2 = ctx.rules:station_plan(ally_home)
	expect(not plan2.ok and plan2.reason == "Station troops on your own land", "not on an ally's land")

	-- a garrison next to home: Reinforce / Disband, and the HUD counts it
	gs:_set_garrisons({ 41, ME, home, 200000, 50000, 0 }, true)
	items = ctx.rules:radial_items(home)
	st = item(items, "station")
	local db = item(items, "disband")
	expect(st ~= nil and st.label == "Reinforce", "radial: Reinforce next to a garrison")
	expect(db ~= nil and db.ok, "radial: Disband")
	inter.radial = inter.radial or { center = Vector2.zero } -- (headless: no radial menu was built)
	inter:on_radial("disband", home)
	it = session.intents[#session.intents]
	expect(it and it.type == "disband" and it.uid == 41, "Disband sends the garrison's id")
	expect(gs:army(ME) == 1000000 + 250000, "army = reserve + garrisons (" .. gs:army(ME) .. ")")

	-- an attack next to the garrison: previewed as launched from it
	local mine, theirs = edge(gs, ME, ENEMY)
	expect(theirs >= 0, "France borders the player")
	gs:_set_garrisons({ 42, ME, mine, 200000, 0, 0 }, true)
	ctx.rules:invalidate()
	local act = ctx.rules:primary(theirs)
	expect(act.type == "attack" and act.garrison == 42, "an attack near a garrison is launched from it")
	expect(math.abs(act.troops - 200000 * 0.35) < 1, "with the ratio's share of the garrison (" .. act.troops .. ")")
	expect(string.find(ctx.rules:confirm_text(act), "from your garrison", 1, true) ~= nil, "and says so: " .. ctx.rules:confirm_text(act))
	-- the cap: 5 garrisons, none near the tile
	local rows = {}
	for k = 1, 5 do
		for _, v in { 100 + k, ME, enemy_home + k * 40 * W, 1000, 0, 0 } do
			table.insert(rows, v)
		end
	end
	gs:_set_garrisons(rows, true)
	local plan3 = ctx.rules:station_plan(home)
	expect(not plan3.ok and string.find(plan3.reason, "disband", 1, true) ~= nil, "a sixth: " .. plan3.reason)
end

print("the fog of war in the interface")
do
	local ctx, _session, _inter, _floats, gs = setup(100000, 3000000)
	local _, theirs = edge(gs, ME, ENEMY)
	gs.fog = {
		active = true,
		visible = function(_self, t)
			return t ~= theirs
		end,
		owner_seen = function(_self, id)
			return id ~= ENEMY
		end,
	}
	expect(gs:tile_owner(theirs) == 0 and gs:true_owner(theirs) == ENEMY, "a tile out of sight reads as nobody's")
	expect(gs:tile_owner(home) == ME, "the player's own land as ever")
	gs.fog = nil
	expect(gs:tile_owner(theirs) == ENEMY, "without the fog, the real owner")
end

if fails > 0 then
	error(fails .. " failures")
end
print("garrison_ui: all passed")
