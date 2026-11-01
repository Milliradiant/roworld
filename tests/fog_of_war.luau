--!nocheck
-- Fog of war (Core/FogOfWar, this fork 2026-11-01): a player sees their own land, their allies', and
-- Rules.FOG_SIGHT_FULL tiles around it; nothing else. Off for spectators and before play; counts follow
-- the land as it changes hands; an alliance shares sight; ships see around them.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local FogOfWar = require("../src/shared/Core/FogOfWar")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local map = WorldMap.get("pangaea")
local readi32 = buffer.readi32

local function contestable_from(k0: number): number
	for k = k0, map.land_count - 1, 7 do
		local t = map:land_tile(k)
		if map:is_contestable(t) then
			return t
		end
	end
	return -1
end

-- the farthest contestable free tile from `t` (a sample of the land)
local function far_from(sim: any, t: number): number
	local best, bd = -1, -1
	for k = 0, map.land_count - 1, 13 do
		local c = map:land_tile(k)
		if map:is_contestable(c) and readi32(sim.owner, c * 4) == 0 then
			local d = sim.range_d2(c, t)
			if d > bd then
				best, bd = c, d
			end
		end
	end
	return best
end

local sim = Sim.new(map, { seed = 51, difficulty = 1, tribes = 0, nations = false, max_humans = 8, spawn_ticks = 20 })
local a = sim:add_human("u1", "A")
local b = sim:add_human("u2", "B")
local ta = contestable_from(map.land_count // 3)
local tb = far_from(sim, ta)
sim:submit(a, { type = "spawn", tile = ta })
sim:submit(b, { type = "spawn", tile = tb })

local st = GameState.new(map)
st:load_snapshot(sim:snapshot())
st.local_owner = a
local fog = FogOfWar.new(st)
local flips = 0
fog.changed:Connect(function()
	flips += 1
end)
local function tick(n: number)
	for _ = 1, n do
		st:apply_delta(sim:step())
		fog:update(0.1)
	end
end

-- the spawn phase: everything shows
tick(2)
expect(st.phase == Defs.PHASE_SPAWN and not fog.active, "no fog while players pick their start")
expect(fog:visible(tb), "B's start shows in the spawn phase")
while sim.phase ~= Defs.PHASE_PLAYING do
	tick(1)
end
tick(12)
expect(fog.active, "the fog is on once play starts")
expect(flips >= 1, "and says so (" .. flips .. ")")
expect(fog:visible(sim.o_spawn_tile[a]), "A sees its own land")
expect(not fog:visible(sim.o_spawn_tile[b]), "A doesn't see B's land far away")
expect(not fog:owner_seen(b), "B counts as unseen")
expect(fog:owner_seen(a), "A always sees itself")

-- sight reaches FOG_SIGHT_FULL past the land (give or take a cell)
local function nearest_free_at(dist: number): number
	local W = sim.W
	local x0, y0 = sim.o_spawn_tile[a] % W, sim.o_spawn_tile[a] // W
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		for e = dist, dist + 6 do
			local x, y = x0 + d[1] * e, y0 + d[2] * e
			if x >= 0 and x < W and y >= 0 and y < sim.H then
				local t = y * W + x
				if readi32(sim.owner, t * 4) == 0 then
					-- distance from A's land
					local m = math.huge
					for _, o in sim:owned_tiles(a) do
						m = math.min(m, math.sqrt(sim.range_d2(o, t)))
					end
					return t, m
				end
			end
		end
	end
	return -1, 0
end
local near, nd = nearest_free_at(8)
expect(near >= 0 and fog:visible(near), string.format("land %.0f tiles past A's border is in sight", nd))
local far2, fd = nearest_free_at(math.floor(Rules.FOG_SIGHT_FULL) + 3 * FogOfWar.CELL + 12)
expect(far2 < 0 or not fog:visible(far2), string.format("land %.0f tiles past it is not", fd))

-- land changing hands keeps the counts right: hand A a far tile and it sees around it
local spot = far_from(sim, sim.o_spawn_tile[a])
local before = flips
sim:set_owner(spot, a)
tick(4)
expect(fog:visible(spot), "a tile A takes far away comes into sight (within FogOfWar.MIN_RECOMPUTE_S)")
expect(flips > before, "the cells around it flipped")
sim:set_owner(spot, 0)
tick(4)
expect(not fog:visible(spot), "and out of sight again when A loses it")

-- an alliance shares sight
sim:ally_request(a, b)
sim:ally_reply(b, a, true)
tick(1)
expect(st:are_allies(a, b), "A and B are allied")
for _ = 1, 30 do
	tick(1)
	if fog:visible(sim.o_spawn_tile[b]) then
		break
	end
end
expect(fog:visible(sim.o_spawn_tile[b]), "an ally's land is in sight")
expect(fog:owner_seen(b), "and the ally counts as seen")

-- a fresh fog (a resync, a takeover) never shows the whole map while it counts
do
	local st2 = GameState.new(map)
	st2:load_snapshot(sim:snapshot())
	st2.local_owner = a
	local fog2 = FogOfWar.new(st2)
	fog2:_start_scan()
	fog2:update(0.016)
	expect(fog2.active and not fog2:visible(sim.o_spawn_tile[b]), "while the first count runs, nothing far away shows")
	for _ = 1, 20 do
		fog2:update(0.1)
	end
	expect(fog2:visible(sim.o_spawn_tile[a]), "once counted, the player's land shows")
	-- a player knocked out who keeps watching sees everything
	st2.owners[a].alive = false
	fog2:update(0.1)
	expect(not fog2.active and fog2:visible(sim.o_spawn_tile[b]), "a player who is out watches without fog")
	fog2:destroy()
end

-- spectators see everything
st.local_owner = 0
tick(2)
expect(not fog.active and fog:visible(sim.o_spawn_tile[b]), "a spectator sees everything")

if fails > 0 then
	error(fails .. " failures")
end
print("fog_of_war: all passed")
