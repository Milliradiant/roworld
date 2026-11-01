--!native
-- Fog of war (this fork, 2026-11-01; Rules.FOG_OF_WAR): what the local player can see of the match.
-- Client side only: the Sim and the server know everything and every client is sent the whole match;
-- this hides what its player can't see (the map surface draws bare, darkened terrain there, and the
-- map's layers and the interface skip what lies in it).
--
-- Sight: within FOG_SIGHT_FULL full-size tiles of the land of the local player, their allies and their
-- teammates (the viewer's side), and FOG_SHIP_SIGHT_FULL of the side's warships and transports at sea. Kept on a
-- grid of coarse cells (CELL x CELL tiles): a cell is in sight when its chamfer distance (3 per step
-- across, 4 diagonally: about 3 x euclidean) to a cell holding the side's land is within the sight,
-- or to a cell with one of its ships within the ship's sight.
--   * the side's land per cell is counted once (a scan sliced over frames, again after an alliance
--     changed the side) and then kept up to date from GameState.tiles_changed;
--   * sight is worked out again when a cell gained or lost the side's land, and every SHIP_POLL_S
--     while the side has ships out;
--   * `changed` fires with the cells whose sight flipped (nil: all of them).
-- Off (everything in sight) for spectators (local_owner 0), before play starts (every start shows in
-- the spawn phase) and once the match is over.
--
--   FogOfWar.new(state)             attach to a GameState (state.fog = it)
--   fog:visible(tile) -> boolean    in sight (always true while off)
--   fog:update(dt)                  once a frame: scanning, recomputing sight, firing `changed`
--   fog:owner_seen(id) -> boolean   any of `id`'s land in sight (cached, refreshed every SEEN_S)
--   fog:destroy()
local Defs = require("./Defs")
local Rules = require("./Rules")
local Signal = require("./Signal")

local readi32 = buffer.readi32
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local readu16 = buffer.readu16
local writeu16 = buffer.writeu16
local readi32c = readi32
local writei32 = buffer.writei32

local FogOfWar = {}
FogOfWar.__index = FogOfWar

--- Tiles per cell side.
FogOfWar.CELL = 8
--- Owner-grid tiles a scan reads per update (a World map is 2,000,000: about 8 frames).
FogOfWar.SCAN_TILES = 262144
--- Sight is worked out again this often while the side has ships out (s).
FogOfWar.SHIP_POLL_S = 0.5
--- owner_seen's cache lasts this long (s).
FogOfWar.SEEN_S = 1.0
--- Sight is worked out at most this often (s): an expanding nation enters new cells many times a second.
FogOfWar.MIN_RECOMPUTE_S = 0.25

local INF = 65535

function FogOfWar.new(state: any): any
	local self = setmetatable({}, FogOfWar) :: any
	self.state = state
	self.changed = Signal.new()
	--- +1 whenever sight changed (layers redraw when it isn't what they drew with)
	self.version = 0
	self._conns = {}
	self.active = false
	self.viewer = 0
	self:_size()
	table.insert(
		self._conns,
		state.tiles_changed:Connect(function(changed: { number }, olds: { number })
			self:_on_tiles(changed, olds)
		end)
	)
	table.insert(
		self._conns,
		state.snapshot_loaded:Connect(function()
			-- (a resync keeps the sight it had until the new count is in: no flash of the whole map)
			if state.W ~= self.W or state.H ~= self.H then
				self:_size()
			end
			self:_start_scan()
		end)
	)
	table.insert(
		self._conns,
		state.alliance_changed:Connect(function(a: number, b: number)
			local v = self.viewer
			if v ~= 0 and (a == v or b == v) then
				self:_start_scan()
			end
		end)
	)
	table.insert(
		self._conns,
		state.owner_added:Connect(function(id: number)
			-- (a teammate who arrived after the count: count again with them on the side)
			local v = state.local_owner
			if v ~= 0 and id ~= v and #state.team_names > 0 and state:are_allies(v, id) then
				self:_start_scan()
			end
		end)
	)
	state.fog = self
	return self
end

function FogOfWar.destroy(self: any)
	for _, c in self._conns do
		c:Disconnect()
	end
	table.clear(self._conns)
	if self.state.fog == self then
		self.state.fog = nil
	end
end

--- (Re)makes the grids for the state's map.
function FogOfWar._size(self: any)
	local st = self.state
	local C = FogOfWar.CELL
	self.W = st.W
	self.H = st.H
	self.C = C
	self.CW = math.ceil(st.W / C)
	self.CH = math.ceil(st.H / C)
	self.NC = self.CW * self.CH
	--- the side's land tiles per cell (i32)
	self.land = buffer.create(self.NC * 4)
	--- 1 = in sight (u8 per cell)
	self.vis = buffer.create(self.NC)
	--- chamfer distances (u16 per cell)
	self._dist = buffer.create(self.NC * 2)
	--- the side the counts were made for: owner -> true
	self.side = {} :: { [number]: boolean }
	self._scan = nil :: any
	self._dirty = true
	self._ship_t = 0.0
	self._had_ships = false
	self._seen = {} :: { [number]: boolean }
	self._seen_t = -math.huge
	self._clock = 0.0
	self._all_visible = true
	self.viewer = 0
end

--- The viewer, their allies and (in a team game) their teammates.
function FogOfWar._side_of(self: any, viewer: number): { [number]: boolean }
	local side = {}
	if viewer ~= 0 then
		side[viewer] = true
		local st = self.state
		for id in st.owners do
			if st:are_allies(viewer, id) then
				side[id] = true
			end
		end
	end
	return side
end

--- Starts counting the side's land again (sliced over updates); the old counts stay in use meanwhile.
function FogOfWar._start_scan(self: any)
	self._scan = {
		i = 0,
		viewer = self.state.local_owner,
		side = self:_side_of(self.state.local_owner),
		land = buffer.create(self.NC * 4),
	}
end

--- Cell index of tile `t`.
function FogOfWar.cell_of(self: any, t: number): number
	local W = self.W
	local x = t % W
	local C = self.C
	return ((t - x) // W // C) * self.CW + x // C
end

function FogOfWar.visible(self: any, t: number): boolean
	if not self.active then
		return true
	end
	if t < 0 or t >= self.W * self.H then
		return false
	end
	return readu8(self.vis, self:cell_of(t)) == 1
end

--- GameState.tiles_changed: keeps the side's land counts (and a running scan's) current.
function FogOfWar._on_tiles(self: any, changed: { number }, olds: { number }?)
	local side = self.side
	local land = self.land
	local scan = self._scan
	for k, packed in changed do
		local t = packed // 1024
		local nw = packed % 1024
		local old = if olds ~= nil then olds[k] else -1
		local c = self:cell_of(t)
		if old ~= nw then
			if side[old] then
				local n = readi32c(land, c * 4) - 1
				writei32(land, c * 4, n)
				if n == 0 then
					self._dirty = true
				end
			end
			if side[nw] then
				local n = readi32c(land, c * 4) + 1
				writei32(land, c * 4, n)
				if n == 1 then
					self._dirty = true
				end
			end
			if scan ~= nil and t < scan.i then
				local sl = scan.land
				if scan.side[old] then
					writei32(sl, c * 4, readi32c(sl, c * 4) - 1)
				end
				if scan.side[nw] then
					writei32(sl, c * 4, readi32c(sl, c * 4) + 1)
				end
			end
		end
	end
end

local function step_scan(self: any)
	local scan = self._scan
	local st = self.state
	local own = st.owner
	local N = self.W * self.H
	local i0 = scan.i
	local i1 = math.min(N, i0 + FogOfWar.SCAN_TILES)
	local side = scan.side
	local sl = scan.land
	local W, C, CW = self.W, self.C, self.CW
	for i = i0, i1 - 1 do
		local o = readi32(own, i * 4)
		if o > 0 and side[o] then
			local x = i % W
			local c = ((i - x) // W // C) * CW + x // C
			writei32(sl, c * 4, readi32c(sl, c * 4) + 1)
		end
	end
	scan.i = i1
	if i1 >= N then
		self.land = sl
		self.side = side
		self.viewer = scan.viewer
		self._scan = nil
		self._dirty = true
	end
end

--- Whether the fog is on now (Rules.FOG_OF_WAR, a player, playing).
--- Whether the fog is on now: Rules.FOG_OF_WAR, playing, and a player in the match (a nation alive that
--- has landed). A player still choosing where to land (a late joiner) and one knocked out who keeps
--- watching see everything, like a spectator.
function FogOfWar.wanted(self: any): boolean
	local st = self.state
	if Rules.FOG_OF_WAR ~= true or st.local_owner == 0 or st.phase ~= Defs.PHASE_PLAYING or st.loaded == false then
		return false
	end
	local o = st.owners[st.local_owner]
	return o ~= nil and o.alive == true and o.spawned == true
end

--- The side's ships at sea: { cell index }.
local function ship_cells(self: any): { number }
	local st = self.state
	local out = {}
	local W, H = self.W, self.H
	local tick = st.render_tick or st.tick
	for _, u in st.units do
		if (u.kind == Defs.U_WARSHIP or u.kind == Defs.U_TRANSPORT) and self.side[u.owner] then
			local px, py = st:unit_pose_xyz(u, tick)
			local x = math.clamp(math.floor(px), 0, W - 1)
			local y = math.clamp(math.floor(py), 0, H - 1)
			table.insert(out, (y // self.C) * self.CW + x // self.C)
		end
	end
	return out
end

--- Works out which cells are in sight; returns the cells that flipped.
function FogOfWar._recompute(self: any): { number }
	local NC, CW, CH = self.NC, self.CW, self.CH
	local dist = self._dist
	local land = self.land
	local R = self.state.rules
	local k_lin = R.K_LIN or 1
	local sight = math.max(1, math.floor(Rules.FOG_SIGHT_FULL / k_lin / self.C * 3 + 0.5))
	local ship = math.max(1, math.floor(Rules.FOG_SHIP_SIGHT_FULL / k_lin / self.C * 3 + 0.5))
	for c = 0, NC - 1 do
		writeu16(dist, c * 2, if readi32c(land, c * 4) > 0 then 0 else INF)
	end
	local ships = ship_cells(self)
	self._had_ships = #ships > 0
	for _, c in ships do
		-- (a ship sees less far: it starts as far from sight's edge as land would at sight - ship)
		local start = math.max(0, sight - ship)
		if readu16(dist, c * 2) > start then
			writeu16(dist, c * 2, start)
		end
	end
	-- chamfer 3-4: forward pass (from the west, north-west, north, north-east), then backward
	for y = 0, CH - 1 do
		local row = y * CW
		for x = 0, CW - 1 do
			local c = row + x
			local d = readu16(dist, c * 2)
			if d == 0 then
				continue
			end
			if x > 0 then
				d = math.min(d, readu16(dist, (c - 1) * 2) + 3)
			end
			if y > 0 then
				local up = c - CW
				d = math.min(d, readu16(dist, up * 2) + 3)
				if x > 0 then
					d = math.min(d, readu16(dist, (up - 1) * 2) + 4)
				end
				if x < CW - 1 then
					d = math.min(d, readu16(dist, (up + 1) * 2) + 4)
				end
			end
			writeu16(dist, c * 2, math.min(d, INF))
		end
	end
	for y = CH - 1, 0, -1 do
		local row = y * CW
		for x = CW - 1, 0, -1 do
			local c = row + x
			local d = readu16(dist, c * 2)
			if d == 0 then
				continue
			end
			if x < CW - 1 then
				d = math.min(d, readu16(dist, (c + 1) * 2) + 3)
			end
			if y < CH - 1 then
				local dn = c + CW
				d = math.min(d, readu16(dist, dn * 2) + 3)
				if x < CW - 1 then
					d = math.min(d, readu16(dist, (dn + 1) * 2) + 4)
				end
				if x > 0 then
					d = math.min(d, readu16(dist, (dn - 1) * 2) + 4)
				end
			end
			writeu16(dist, c * 2, math.min(d, INF))
		end
	end
	local vis = self.vis
	local flipped = {}
	for c = 0, NC - 1 do
		local v = if readu16(dist, c * 2) <= sight then 1 else 0
		if readu8(vis, c) ~= v then
			writeu8(vis, c, v)
			table.insert(flipped, c)
		end
	end
	return flipped
end

function FogOfWar.update(self: any, dt: number)
	local st = self.state
	self._clock += dt
	if st.W ~= self.W or st.H ~= self.H then
		self:_size()
		self:_start_scan()
	end
	if st.local_owner ~= self.viewer and (self._scan == nil or self._scan.viewer ~= st.local_owner) then
		self:_start_scan()
	end
	if self._scan ~= nil then
		step_scan(self)
	end
	-- (an alliance's re-count keeps the old counts in use until it is done; a new viewer's first count
	-- shows nothing in sight until it is done: never the whole map for a few frames)
	local want = self:wanted()
	local counted = self.viewer == st.local_owner
	if want ~= self.active then
		self.active = want
		if want and counted then
			self:_recompute()
		elseif want then
			buffer.fill(self.vis, 0, 0)
			self._dirty = true
		end
		if not (want and not counted) then
			self._dirty = false
		end
		self._ship_t = 0.0
		self._seen_t = -math.huge
		self.version += 1
		self.changed:Fire(nil)
		return
	end
	if not counted then
		return -- (the new viewer's count goes on: sight stays as it is)
	end
	if not self.active then
		return
	end
	self._ship_t -= dt
	if self._clock - (self._last_recompute or -math.huge) < FogOfWar.MIN_RECOMPUTE_S then
		return
	end
	if self._dirty or (self._had_ships and self._ship_t <= 0) or (not self._had_ships and self._ship_t <= -2.0) then
		self._last_recompute = self._clock
		self._dirty = false
		self._ship_t = FogOfWar.SHIP_POLL_S
		local flipped = self:_recompute()
		if #flipped > 0 then
			self._seen_t = -math.huge
			self.version += 1
			self.changed:Fire(flipped)
		end
	end
end

--- True when any of owner `id`'s land is in sight (the side's own always is).
function FogOfWar.owner_seen(self: any, id: number): boolean
	if not self.active or self.side[id] then
		return true
	end
	if self._clock - self._seen_t >= FogOfWar.SEEN_S then
		self._seen_t = self._clock
		local seen = self._seen
		table.clear(seen)
		local st = self.state
		local own = st.owner
		local vis = self.vis
		local land = self.land
		local W, H, C, CW = self.W, self.H, self.C, self.CW
		local full = C * C
		for c = 0, self.NC - 1 do
			-- (a cell all of the side's own land holds nobody else)
			if readu8(vis, c) == 1 and readi32c(land, c * 4) < full then
				local cx = (c % CW) * C
				local cy = (c // CW) * C
				for y = cy, math.min(cy + C, H) - 1 do
					local row = y * W
					for x = cx, math.min(cx + C, W) - 1 do
						local o = readi32(own, (row + x) * 4)
						if o > 0 then
							seen[o] = true
						end
					end
				end
			end
		end
	end
	return self._seen[id] == true
end

return FogOfWar
