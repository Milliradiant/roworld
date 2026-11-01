--!nocheck
-- Garrisons (Core/SimGarrisons, this fork 2026-11-01): troops stationed at a spot instead of spread
-- over all of a nation's land. Stationing and reinforcing, arrival, the cap, disbanding, growth counting
-- them, guarded tiles holding out better (and the rest falling faster), overrun, a nuke's blast,
-- attacks launched from a garrison, elimination, the clients' copy, and the intents on the wire.
require("./prelude")
local Defs = require("../src/shared/Core/Defs")
local Ev = require("../src/shared/Core/Ev")
local Rules = require("../src/shared/Core/Rules")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local Protocol = require("../src/shared/Net/Protocol")

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

local function neighbours(sim: any, t: number): { number }
	local out = {}
	local x = t % sim.W
	if x > 0 then
		table.insert(out, t - 1)
	end
	if x < sim.W - 1 then
		table.insert(out, t + 1)
	end
	if t >= sim.W then
		table.insert(out, t - sim.W)
	end
	if t < sim.N - sim.W then
		table.insert(out, t + sim.W)
	end
	return out
end

-- a tile of `b` next to land of `a` (-1 if they don't touch)
local function front(sim: any, a: number, b: number): number
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == b then
			for _, n in neighbours(sim, t) do
				if readi32(sim.owner, n * 4) == a then
					return t
				end
			end
		end
	end
	return -1
end

-- a tile of `a` next to land of `b`
local function own_front(sim: any, a: number, b: number): number
	local t = front(sim, b, a)
	return t
end

local function contestable_from(k0: number): number
	for k = k0, map.land_count - 1, 7 do
		local t = map:land_tile(k)
		if map:is_contestable(t) then
			return t
		end
	end
	return -1
end

local function away(sim: any, t: number, d: number): number
	for e = d, d + 40 do
		for _, c in { t + e, t - e, t + e * sim.W, t - e * sim.W } do
			if c >= 0 and c < sim.N and map:is_contestable(c) and readi32(sim.owner, c * 4) == 0 then
				return c
			end
		end
	end
	return -1
end

local function msgs_to(d: any, id: number, out: { string })
	for _, e in d.ev or {} do
		if e[1] == Ev.MSG and e[2] == id then
			table.insert(out, e[4])
		end
	end
end

local function has(list: { string }, needle: string): boolean
	for _, m in list do
		if string.find(m, needle, 1, true) ~= nil then
			return true
		end
	end
	return false
end

-- the tile of `id`'s land farthest from tile `from` (by the map's metric)
local function farthest_own(sim: any, id: number, from: number): number
	local best, bd = -1, -1
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == id then
			local d = sim.range_d2(t, from)
			if d > bd then
				best, bd = t, d
			end
		end
	end
	return best
end

-- the tile of `id`'s land farthest from every tile of `other`'s border (sampled: other's border tiles)
local function farthest_from(sim: any, id: number, other: number): number
	local edge = {}
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == other and buffer.readu8(sim.in_border, t) == 1 then
			table.insert(edge, t)
		end
	end
	local best, bd = -1, -1
	for t = 0, sim.N - 1 do
		if readi32(sim.owner, t * 4) == id then
			local m = math.huge
			for _, e in edge do
				m = math.min(m, sim.range_d2(t, e))
			end
			if m > bd then
				best, bd = t, m
			end
		end
	end
	return best
end

-- Two players who start close; both expand (land only) until they touch, and keep growing a while.
local function neighbours_match(seed: number, grow: number?): (any, number, number)
	local sim =
		Sim.new(map, { seed = seed, difficulty = 1, tribes = 0, nations = false, max_humans = 8, spawn_ticks = 20 })
	local a = sim:add_human("u1", "A")
	local b = sim:add_human("u2", "B")
	local ta = contestable_from(map.land_count // 2)
	sim:submit(a, { type = "spawn", tile = ta })
	sim:submit(b, { type = "spawn", tile = away(sim, ta, math.ceil(sim.R.SPAWN_RADIUS * 2.5)) })
	while sim.phase ~= Defs.PHASE_PLAYING do
		sim:step()
	end
	sim:step()
	local extra = grow or 0
	local touched_at = -1
	for i = 1, 400 do
		if touched_at < 0 and front(sim, a, b) >= 0 then
			touched_at = i
		end
		if touched_at >= 0 and i - touched_at >= extra then
			break
		end
		if sim:attack_between(a, 0) == nil or sim:attack_between(b, 0) == nil then
			for _, id in { a, b } do
				if sim:attack_between(id, 0) == nil then
					for t = 0, sim.N - 1 do
						if readi32(sim.owner, t * 4) == 0 and buffer.readu8(sim.land, t) == 1 then
							local hit = false
							for _, n in neighbours(sim, t) do
								if readi32(sim.owner, n * 4) == id then
									sim:intent_attack(id, t, 0.3)
									hit = true
									break
								end
							end
							if hit then
								break
							end
						end
					end
				end
			end
		end
		sim:step()
	end
	sim.o_shield_until[a] = 0
	sim.o_shield_until[b] = 0
	return sim, a, b
end

local function run(sim: any, n: number): { any }
	local evs = {}
	for _ = 1, n do
		local d = sim:step()
		for _, e in d.ev or {} do
			table.insert(evs, e)
		end
	end
	return evs
end

local function last_garrison_event(evs: { any }): any
	local found = nil
	for _, e in evs do
		if e[1] == Ev.GARRISONS then
			found = e
		end
	end
	return found
end

-- stationing: the reserve pays, the troops arrive after GARRISON_FORM_TICKS, the clients hear of it
do
	local sim, a, _b = neighbours_match(31)
	sim:end_attacks_of(a)
	sim.o_troops[a] = 100000
	local t = sim.o_spawn_tile[a]
	expect(readi32(sim.owner, t * 4) == a, "A's start is A's land")
	expect(sim:station(a, t, 0.4), "a station order goes through")
	local evs = run(sim, 1)
	expect(sim:garrison_count(a) == 1, "it makes a garrison")
	local g = sim.gar_of[a][1]
	expect(readi32(sim.owner, g.tile * 4) == a and sim.range_d2(g.tile, t) <= (sim.R.garrison_range() * Rules.GARRISON_SNAP) ^ 2,
		"standing on A's land near where it was ordered")
	expect(g.troops == 0 and g.pending == 40000, "the troops are on their way")
	expect(last_garrison_event(evs) ~= nil, "the clients hear of the new garrison at once")
	expect(sim:garrison_total(a) == 40000, "garrison_total counts troops on their way")
	evs = run(sim, Rules.GARRISON_FORM_TICKS + Rules.GARRISON_UPDATE_TICKS)
	expect(g.troops == 40000 and g.pending == 0, "they arrive after " .. Rules.GARRISON_FORM_TICKS .. " ticks")
	local e = last_garrison_event(evs)
	expect(e ~= nil and e[2][1] == g.gid and e[2][2] == a and e[2][3] == g.tile and e[2][4] == 40000, "the clients hear the arrival")

	-- a second order nearby reinforces the same garrison
	local near = -1
	for _, n in neighbours(sim, t) do
		if readi32(sim.owner, n * 4) == a then
			near = n
			break
		end
	end
	sim:submit(a, { type = "station", tile = near, ratio = 0.5 })
	run(sim, 1)
	expect(sim:garrison_count(a) == 1 and g.pending > 0, "an order next to it reinforces it instead of making another")

	-- not on someone else's land, not with an empty reserve, not more than GARRISON_MAX
	local msgs = {}
	sim:submit(a, { type = "station", tile = sim.o_spawn_tile[_b], ratio = 0.5 })
	msgs_to(sim:step(), a, msgs)
	expect(sim:garrison_count(a) == 1 and has(msgs, "own land"), "an order on someone else's land is refused")
	local saved = sim.o_troops[a]
	sim.o_troops[a] = 0
	msgs = {}
	expect(not sim:station(a, t, 0.5), "an empty reserve stations nothing")
	msgs_to(sim:step(), a, msgs)
	expect(has(msgs, "No troops"), "and says so")
	sim.o_troops[a] = saved

	-- disbanding: everything comes home at once
	local before = sim.o_troops[a]
	local total = g.troops + g.pending
	sim:submit(a, { type = "disband", uid = g.gid })
	evs = run(sim, 1)
	expect(sim:garrison_count(a) == 0 and g.dead, "disband removes the garrison")
	expect(sim.o_troops[a] >= before + total - 1, "and its troops (arrived or not) rejoin the reserve")
	local ge = last_garrison_event(evs)
	expect(ge ~= nil and #ge[2] == 0, "the clients hear it is gone")
	-- someone else's garrison can't be disbanded
	sim:submit(a, { type = "station", tile = t, ratio = 0.2 })
	run(sim, 1)
	local g2 = sim.gar_of[a][1]
	expect(not sim:disband(_b, g2.gid), "B can't disband A's garrison")
end

-- the cap: GARRISON_MAX garrisons, far enough apart not to merge
do
	local sim, a, _b = neighbours_match(32, 80)
	sim.o_troops[a] = 500000
	local tiles = sim:owned_tiles(a)
	local placed = 0
	local merge = sim.R.garrison_range() * Rules.GARRISON_MERGE
	for _, t in tiles do
		if sim:garrison_near(a, t, merge + 1) == nil then
			if sim:station(a, t, 0.05) then
				placed += 1
			end
			if placed > Rules.GARRISON_MAX then
				break
			end
		end
	end
	expect(
		sim:garrison_count(a) == math.min(placed, Rules.GARRISON_MAX),
		"never more than " .. Rules.GARRISON_MAX .. " garrisons (" .. sim:garrison_count(a) .. ")"
	)
end

-- growth: garrisons count towards the cap, and the reserve never goes negative
do
	local sim, a, _b = neighbours_match(33)
	sim:end_attacks_of(a)
	local cap = sim.o_cap[a]
	sim.o_troops[a] = cap * 0.5
	sim:station(a, sim.o_spawn_tile[a], 1.0)
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local g = sim.gar_of[a][1]
	-- push the garrison over the cap: the reserve shrinks to 0 and stays there
	g.troops = cap * 1.2
	run(sim, 30)
	expect(sim.o_troops[a] >= 0 and sim.o_troops[a] < 1, "over the cap the reserve doesn't grow (" .. sim.o_troops[a] .. ")")
	expect(g.troops < cap * 1.2 and g.troops >= sim.o_cap[a] - 1, "and the garrison shrinks back to the cap (" .. math.floor(g.troops) .. ")")
	g.troops = cap * 0.2
	local r0 = sim.o_troops[a]
	run(sim, 30)
	expect(sim.o_troops[a] > r0, "under the cap the reserve grows again")
	expect(sim.o_troops[a] + sim:garrison_total(a) <= sim.o_cap[a] + 1, "reserve + garrisons stay under the cap")
end

-- defence: the same attack on the same front, with B's troops spread, stationed there, or stationed away
do
	local function trial(mode: string): (number, number, any)
		local sim, a, b = neighbours_match(34, 120)
		sim:end_attacks_of(a)
		sim:end_attacks_of(b)
		local ft = own_front(sim, b, a)
		sim.o_troops[b] = 60000
		if mode == "guard" or mode == "away" then
			local spot = if mode == "guard" then ft else farthest_from(sim, b, a)
			sim:station(b, spot, 0.7)
		end
		run(sim, Rules.GARRISON_FORM_TICKS + 1)
		-- the same armies at the same moment: 60,000 each, B's spread or 42,000 of it stationed
		sim.o_troops[a] = 60000
		sim.o_troops[b] = if mode == "spread" then 60000 else 18000
		for _, g in sim.gar_of[b] or {} do
			g.troops = 42000
			-- (the test map's nations are small: count the garrison as concentrated)
			g.conc = 1.0
		end
		local tiles0 = sim.o_tiles[b]
		if mode == "away" then
			local g = sim.gar_of[b][1]
			local covers_front = false
			for t = 0, sim.N - 1 do
				if readi32(sim.owner, t * 4) == b and sim:garrison_covering(t, b) == g then
					for _, n in neighbours(sim, t) do
						covers_front = covers_front or readi32(sim.owner, n * 4) == a
					end
				end
			end
			expect(not covers_front, "away: the garrison guards none of the front")
		end
		local saved = Rules.GARRISON_COVER_TICKS
		Rules.GARRISON_COVER_TICKS = 1000000
		expect(sim:intent_attack(a, front(sim, a, b), 0.4), mode .. ": the attack goes out")
		for _ = 1, 40 do
			sim:step()
		end
		Rules.GARRISON_COVER_TICKS = saved
		local g = if sim.gar_of[b] ~= nil then sim.gar_of[b][1] else nil
		return tiles0 - sim.o_tiles[b], sim.o_troops[a], g
	end
	local lost_spread = trial("spread")
	local lost_guard, _, g = trial("guard")
	local lost_away = trial("away")
	print(string.format("    B lost %d tiles spread, %d guarded, %d with the garrison away", lost_spread, lost_guard, lost_away))
	expect(lost_guard < lost_spread, "a garrison on the front holds it better than troops spread out")
	expect(lost_away > lost_spread, "a garrison elsewhere leaves the front weaker than troops spread out")
	expect(g ~= nil and g.troops < 0.7 * 60000, "defending costs the garrison troops")
end

-- overrun: taking the garrison's tile sends a share of it home
do
	local sim, a, b = neighbours_match(35, 30)
	sim.o_troops[b] = 40000
	local ft = own_front(sim, b, a)
	sim:station(b, ft, 0.5)
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local g = sim.gar_of[b][1]
	local held = g.troops
	local reserve = sim.o_troops[b]
	sim:end_attacks_of(b)
	reserve = sim.o_troops[b]
	local msgs_a, msgs_b = {}, {}
	expect(sim:garrison_holds(g.tile), "a garrison's tile holds while it stands")
	sim:set_owner(g.tile, a)
	local d = sim:step()
	msgs_to(d, a, msgs_a)
	msgs_to(d, b, msgs_b)
	expect(g.dead and sim:garrison_count(b) == 0, "a garrison whose tile falls anyway is gone")
	expect(
		sim.o_troops[b] >= reserve + math.floor(held * Rules.GARRISON_OVERRUN_KEEP) - 1,
		"half of it falls back to the reserve"
	)
	expect(has(msgs_b, "overran your garrison") and has(msgs_a, "You overran"), "both sides are told")
end

-- a garrison stands inland, and holds against a boat landing on it
do
	local sim, a, b = neighbours_match(40, 60)
	sim:end_attacks_of(a)
	sim.o_troops[a] = 100000
	-- order it on A's coast if A has one, else at its start
	local spot = sim.o_spawn_tile[a]
	for _, t in sim:owned_tiles(a) do
		if map:is_coastal(t) then
			spot = t
			break
		end
	end
	expect(sim:station(a, spot, 0.5), "a station order on the coast goes through")
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local g = sim.gar_of[a][1]
	expect(not map:is_coastal(g.tile) or #sim:owned_tiles(a) < 30, "the garrison stands back from the shore")
	expect(not sim:_landable(b, g.tile), "a boat can't land on a garrison's tile while it holds")
	-- strikes and warheads reach garrisons even with nothing in reserve
	sim.o_troops[a] = 0
	local before = g.troops
	sim:_nuke_troops(a, Defs.N_WARHEAD, 40, sim.o_tiles[a])
	expect(g.troops < before, "warheads kill garrison troops with an empty reserve (" .. math.floor(before) .. " -> " .. math.floor(g.troops) .. ")")
end

-- an order near a garrison with nothing of the target's land in its reach goes from the reserve
do
	local sim, a, b = neighbours_match(41, 30)
	sim:end_attacks_of(a)
	sim.o_troops[a] = 50000
	sim:station(a, sim.o_spawn_tile[a], 0.5)
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local g = sim.gar_of[a][1]
	local held = g.troops
	-- water within reach: the garrison has nothing to launch into there
	local water = -1
	for _, t in sim:disk_tiles(g.tile, sim.R.garrison_range() * Rules.GARRISON_REACH, false) do
		if buffer.readu8(sim.land, t) == 0 then
			water = t
			break
		end
	end
	if water >= 0 then
		expect(not sim:garrison_attack(a, water, 0.5) and g.troops == held, "no launch into water: the garrison keeps its troops")
	else
		expect(true, "(no water near this garrison: skipped)")
	end
end

-- a nuke's blast wipes out the garrisons inside it
do
	local sim, a, b = neighbours_match(36, 30)
	sim.o_troops[b] = 40000
	sim:station(b, sim.o_spawn_tile[b], 0.5)
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local reserve = sim.o_troops[b]
	sim:_garrisons_blast(sim.o_spawn_tile[b], 5, a)
	expect(sim:garrison_count(b) == 0, "a blast over a garrison wipes it out")
	expect(sim.o_troops[b] <= reserve, "and none of it falls back")
end

-- attacks launched from a garrison
do
	local sim, a, b = neighbours_match(37, 30)
	sim.o_troops[a] = 50000
	sim.o_troops[b] = 2000
	local ft = own_front(sim, a, b)
	sim:station(a, ft, 0.6)
	run(sim, Rules.GARRISON_FORM_TICKS + 1)
	local g = sim.gar_of[a][1]
	local held = g.troops
	local reserve = sim.o_troops[a]
	local target = front(sim, a, b)
	sim:submit(a, { type = "attack", tile = target, ratio = 0.5 })
	sim:step()
	local atk = sim:attack_between(a, b)
	expect(atk ~= nil, "an attack ordered next to a garrison goes out")
	expect(math.abs(g.troops - held * 0.5) <= 1, "with half of the garrison (" .. math.floor(g.troops) .. " of " .. held .. " left)")
	expect(sim.o_troops[a] >= reserve - 1, "and not a troop of the reserve")
	-- far from every garrison: the reserve sends it
	sim:_clear_garrisons(a)
	sim.o_troops[a] = 50000
	local r0 = sim.o_troops[a]
	sim:submit(a, { type = "attack", tile = target, ratio = 0.2 })
	sim:step()
	expect(sim.o_troops[a] < r0, "with no garrison near, the reserve attacks as before")
end

-- elimination takes the garrisons along
do
	local sim, a, b = neighbours_match(38)
	sim.o_troops[b] = 30000
	sim:station(b, sim.o_spawn_tile[b], 0.5)
	run(sim, 1)
	expect(sim:garrison_count(b) == 1, "B has a garrison")
	sim:end_attacks_of(b)
	for _, t in sim:owned_tiles(b) do
		sim:set_owner(t, a)
	end
	run(sim, 3)
	expect(sim.o_alive[b] == 0 and sim:garrison_count(b) == 0, "a nation that is out has no garrisons left")
end

-- the clients' copy: deltas and snapshots
do
	local sim, a, _b = neighbours_match(39)
	sim:end_attacks_of(a)
	local st = GameState.new(map)
	st:load_snapshot(sim:snapshot())
	local changed = 0
	st.garrisons_changed:Connect(function()
		changed += 1
	end)
	sim.o_troops[a] = 80000
	expect(sim:station(a, sim.o_spawn_tile[a], 0.25), "A stations a quarter")
	for _ = 1, Rules.GARRISON_FORM_TICKS + 6 do
		st:apply_delta(sim:step())
	end
	local mine = nil
	for _, gi in st.garrisons do
		mine = gi
	end
	expect(changed >= 2 and mine ~= nil, "the mirror hears of the garrison (" .. changed .. " updates)")
	expect(mine ~= nil and mine.owner == a and mine.tile == sim.gar_of[a][1].tile and mine.troops == 20000, "with its owner, tile and troops")
	expect(st:garrison_total(a) == 20000, "GameState.garrison_total")
	expect(st:army(a) == st.owners[a].troops + 20000, "GameState.army = reserve + garrisons")
	local st2 = GameState.new(map)
	st2:load_snapshot(Protocol.decode_snapshot(Protocol.encode_snapshot(sim:snapshot())))
	expect(st2:garrison_total(a) == 20000, "a late joiner's snapshot carries the garrisons")
end

-- the garrison list on the wire (a delta's event, empty or not)
do
	local d = {
		t = 7,
		tiles = {},
		flags = {},
		ev = { { Ev.GARRISONS, { 3, 2, 123456, 40000, 1500, 99 } }, { Ev.GARRISONS, {} } },
	}
	local back = Protocol.decode_delta(Protocol.encode_delta(d, d.ev, 1000))
	local e1, e2 = back.ev[1], back.ev[2]
	expect(e1 ~= nil and e1[1] == Ev.GARRISONS and e1[2][3] == 123456 and e1[2][5] == 1500, "a garrison list travels in a delta")
	expect(e2 ~= nil and e2[1] == Ev.GARRISONS and type(e2[2]) == "table" and #e2[2] == 0, "and an empty one")
	local st = GameState.new(map)
	st:_apply_event(e1)
	expect(st.garrisons[3] ~= nil and st.garrisons[3].ready_tick == 99, "the mirror reads it")
	st:_apply_event(e2)
	expect(next(st.garrisons) == nil, "and the empty one clears it")
end

-- the intents on the wire
do
	local s = Protocol.decode_intent(Protocol.encode_intent({ type = "station", tile = 1234, ratio = 0.35 }))
	expect(s ~= nil and s.type == "station" and s.tile == 1234 and math.abs(s.ratio - 0.35) < 1e-9, "station travels")
	local d = Protocol.decode_intent(Protocol.encode_intent({ type = "disband", uid = 7 }))
	expect(d ~= nil and d.type == "disband" and d.uid == 7, "disband travels")
end

if fails > 0 then
	error(fails .. " failures")
end
print("garrisons: all passed")
