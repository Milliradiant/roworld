--!nocheck
-- Map/MapSurface under the fog of war (Core/FogOfWar): a tile out of the player's sight is drawn as
-- bare, darkened terrain whoever owns it; in sight, as before. Whatever the fog's changes repaint, the
-- picture is the one a full redraw gives.
local roblox = require("./prelude");
(getfenv() :: any).Instance = (roblox :: any).Instance;
(getfenv() :: any).Enum = (roblox :: any).Enum;
(getfenv() :: any).task = require("@lune/task");
(getfenv() :: any).warn = function() end -- (no EditableImage here: the surface says so)
local Defs = require("../src/shared/Core/Defs")
local WorldMap = require("../src/shared/Core/WorldMap")
local Sim = require("../src/shared/Core/Sim")
local GameState = require("../src/shared/Core/GameState")
local FogOfWar = require("../src/shared/Core/FogOfWar")
local MapSurface = require("../src/client/Map/MapSurface")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local map = WorldMap.get("world")
local readi32 = buffer.readi32
local readu32 = buffer.readu32

local function drain(surface: any)
	local guard = 0
	while (surface:repaint_pending() > 0 or surface._rebuild_active) and guard < 20000 do
		surface:step()
		guard += 1
	end
end

--- Tiles where the picture now and a full redraw disagree about the fog (one of the two is the fogged
--- terrain and the other isn't). (The surface's incremental repaints and a full redraw may differ
--- elsewhere for reasons of their own; this is about what the fog adds.)
local function fog_differs(surface: any): number
	drain(surface)
	local now = buffer.fromstring(buffer.tostring(surface.comp))
	surface:rebuild_all()
	drain(surface)
	local full = surface.comp
	local n = 0
	for i = 0, surface.N - 1 do
		local a, b = readu32(now, i * 4), readu32(full, i * 4)
		if a ~= b then
			local fp = MapSurface.fog_pixel(readu32(surface.terrain, i * 4))
			if a == fp or b == fp then
				n += 1
			end
		end
	end
	return n
end

local sim = Sim.new(map, { seed = 9, difficulty = 1, max_humans = 64, time_limit_s = 0, spawn_ticks = 60 })
local me = sim:add_human("u1", "Me")
sim:add_bot_players(20)

local state = GameState.new()
state:load_snapshot(sim:snapshot())
state.local_owner = me
local surface = MapSurface.new(nil)
surface:set_map(map)
local fog = FogOfWar.new(state)
surface:set_fog(fog)
fog.changed:Connect(function(cells)
	surface:on_fog_changed(cells)
end)
surface:bind(state)
drain(surface)
state.tiles_changed:Connect(function(ch, olds)
	surface:on_tiles_changed(ch, olds)
end)
state.flags_changed:Connect(function(ch)
	surface:on_flags_changed(ch)
end)
state.owner_added:Connect(function(id)
	surface:refresh_palette()
	surface:repaint_owner(id)
end)

-- pick a start, play two minutes
local start = -1
for k = map.land_count // 2, map.land_count - 1, 11 do
	local t = map:land_tile(k)
	if map:is_contestable(t) then
		start = t
		break
	end
end
sim:submit(me, { type = "spawn", tile = start })
for i = 1, 1300 do
	state:apply_delta(sim:step())
	fog:update(0.1)
	if i % 3 == 0 then
		surface:step()
	end
end
expect(fog.active, "the fog is on in play")
expect(state.phase == Defs.PHASE_PLAYING, "playing")

-- in sight: drawn as before; out of sight: the darkened terrain
drain(surface)
local own_tile = sim.o_spawn_tile[me]
expect(readi32(state.owner, own_tile * 4) == me and fog:visible(own_tile), "the player's start is theirs and in sight")
local terrain_own = readu32(surface.terrain, own_tile * 4)
expect(readu32(surface.comp, own_tile * 4) ~= MapSurface.fog_pixel(terrain_own), "the player's land isn't fogged")
local fogged_owned, checked = 0, 0
for t = 0, state.N - 1, 97 do
	local o = readi32(state.owner, t * 4)
	if o > 0 and o ~= me and not fog:visible(t) then
		checked += 1
		if readu32(surface.comp, t * 4) == MapSurface.fog_pixel(readu32(surface.terrain, t * 4)) then
			fogged_owned += 1
		end
	end
end
expect(checked > 100 and fogged_owned == checked, string.format("others' land out of sight is bare terrain (%d of %d)", fogged_owned, checked))
expect(state:tile_owner(own_tile) == me, "tile_owner: the player's own land")
local any_hidden = -1
for t = 0, state.N - 1, 97 do
	local o = readi32(state.owner, t * 4)
	if o > 0 and o ~= me and not fog:visible(t) then
		any_hidden = t
		break
	end
end
expect(any_hidden >= 0 and state:tile_owner(any_hidden) == 0 and state:true_owner(any_hidden) > 0,
	"tile_owner reads nobody's out of sight; true_owner knows")

local n = fog_differs(surface)
expect(n == 0, "the fog's repaints leave what a full redraw draws (" .. n .. " tiles disagree about the fog)")

-- the fog off (a spectator): everything as before, nothing darkened that someone owns
state.local_owner = 0
fog:update(0.1)
drain(surface)
expect(not fog.active, "a spectator has no fog")
local lit, owned = 0, 0
for t = 0, state.N - 1, 97 do
	local o = readi32(state.owner, t * 4)
	if o > 0 then
		owned += 1
		if readu32(surface.comp, t * 4) ~= MapSurface.fog_pixel(readu32(surface.terrain, t * 4)) then
			lit += 1
		end
	end
end
expect(owned > 0 and lit == owned, string.format("every owned tile is drawn again once the fog is off (%d of %d)", lit, owned))

if fails > 0 then
	error(fails .. " failures")
end
print("fog_surface: all passed")
