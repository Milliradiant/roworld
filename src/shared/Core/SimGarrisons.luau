--!native
-- Garrisons (this fork, 2026-11-01): troops stationed at a spot of their nation's land instead of
-- spread evenly over all of it, as in Risk. A mixin of the flattened Sim class, after SimArsenal.
--
-- A nation's troops are its RESERVE (o_troops: grows, sends attacks and boats, defends every tile
-- thinly as before) plus its garrisons (at most Rules.GARRISON_MAX). Troop growth and the cap count
-- both (garrison_total).
--
--   station(id, tile, ratio)   moves `ratio` of the reserve to a garrison at `tile` (own land); within
--                              GARRISON_MERGE x range of one of its garrisons it reinforces that one.
--                              The troops arrive GARRISON_FORM_TICKS later (`pending` until then).
--   disband(id, gid)           a garrison's troops (arrived or not) go back to the reserve at once.
--   garrison_attack(id, tile, ratio)
--                              an attack ordered within GARRISON_REACH x range of a ready garrison is
--                              launched from it: `ratio` of the garrison's troops, a spearhead that
--                              starts from the garrison's stretch of the border nearest the tile
--                              (start_attack's beachhead). Its troops come home to the reserve.
--   Defence (SimAttacks._process_attack): a tile within range of a ready garrison of its owner is
--   defended by the reserve AND the garrison (the attack's troop ratio counts both). The garrison
--   also works like a defense post scaled by how much it outnumbers the attack and how concentrated
--   it is (`conc`: 0 when it guards its nation's whole border, 1 at a quarter of it or less): the
--   attacker's loss per tile x up to GARRISON_MAG, the time per tile x up to GARRISON_COST. Each
--   full-size tile taken costs the garrison 1 / GARRISON_TRADE of the attacker's loss.
--   Its own tile holds while it has troops and touches its nation's land (garrison_holds); a garrison
--   whose tile changes hands anyway (encircled, worn down to nothing while forming, annexed, given up)
--   falls back to the reserve with GARRISON_OVERRUN_KEEP of its troops. A nuke's blast wipes the garrisons inside it; strikes and
--   nukes elsewhere kill the same share of garrisons as of the reserve.
--
-- Clients see every garrison through Ev.GARRISONS (the full list, flat: gid, owner, tile, troops,
-- pending, ready_tick per garrison), sent when one is added or removed and otherwise at most every
-- GARRISON_UPDATE_TICKS while troops change; the snapshot carries the same list (`garrisons`).
-- The AI doesn't station troops.
local Defs = require("./Defs")
local Ev = require("./Ev")
local Rules = require("./Rules")
local NumberFormat = require("./NumberFormat")
local SimState = require("./SimState")

local readi32 = buffer.readi32
local readu8 = buffer.readu8

local touches = SimState.touches

local SimGarrisons = {}

--- Garrison record (plain table).
export type Garrison = {
	gid: number,
	owner: number,
	tile: number,
	--- troops that have arrived (they defend and attack)
	troops: number,
	--- troops on their way, arriving at pending_at
	pending: number,
	pending_at: number,
	--- the owner's border tiles within range, last counted (Rules.GARRISON_COVER_TICKS)
	cover_border: number,
	--- concentration bonus 0..1 (see header)
	conc: number,
	dead: boolean,
}

local function troops_text(n: number): string
	return NumberFormat.render_troops(n)
end

function SimGarrisons.install(C: any)
	function C._init_garrisons(self: any)
		--- Every garrison still standing, in creation order.
		self.garrisons = {} :: { Garrison }
		self.gar_by_id = {} :: { [number]: Garrison }
		--- tile -> the garrison standing on it
		self.gar_at = {} :: { [number]: Garrison }
		--- owner -> its garrisons (creation order)
		self.gar_of = {} :: { [number]: { Garrison } }
		self.next_gid = 1
		--- 0 nothing to tell clients, 1 troops changed, 2 a garrison came or went (send now)
		self._gar_dirty = 0
	end

	--- Troops in `id`'s garrisons, arrived and on their way.
	function C.garrison_total(self: any, id: number): number
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil then
			return 0.0
		end
		local n = 0.0
		for _, g in list do
			n += g.troops + g.pending
		end
		return n
	end

	function C.garrison_count(self: any, id: number): number
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		return if list == nil then 0 else #list
	end

	--- `id`'s garrison nearest `t` within `range` tiles (euclidean), or nil.
	function C.garrison_near(self: any, id: number, t: number, range: number): Garrison?
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil or #list == 0 then
			return nil
		end
		local range_d2 = self.range_d2
		local best: Garrison? = nil
		local best_d = range * range
		for _, g in list do
			local d = range_d2(g.tile, t)
			if d <= best_d then
				best = g
				best_d = d
			end
		end
		return best
	end

	--- The strongest ready garrison of `id` guarding tile `t` (nil: none).
	function C.garrison_covering(self: any, t: number, id: number): Garrison?
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil or #list == 0 then
			return nil
		end
		local range_d2 = self.range_d2
		local r = self.R.garrison_range()
		local r2 = r * r
		local best: Garrison? = nil
		for _, g in list do
			if g.troops >= 1.0 and range_d2(g.tile, t) <= r2 and (best == nil or g.troops > best.troops) then
				best = g
			end
		end
		return best
	end

	--- The tile a garrison stands on can't be taken while it holds: it has troops and still touches
	--- its owner's land (an encircled garrison falls with its tile). Attacks grind it down through the
	--- tiles around it instead (SimAttacks._process_attack skips the tile).
	function C.garrison_holds(self: any, t: number): boolean
		local g = if self.gar_at ~= nil then self.gar_at[t] else nil
		if g == nil or g.dead or g.troops < 1.0 then
			return false
		end
		return touches(self, t, g.owner)
	end

	--- Recounts the border `g` guards and its concentration bonus.
	function C._garrison_cover(self: any, g: Garrison)
		local id = g.owner
		local owner = self.owner
		local in_border = self.in_border
		local n = 0
		for _, t in self:disk_tiles(g.tile, self.R.garrison_range(), true) do
			if readi32(owner, t * 4) == id and readu8(in_border, t) == 1 then
				n += 1
			end
		end
		g.cover_border = n
		local total = self.bcount[id] or 0
		local m = if n > 0 then total / n else 1.0
		g.conc = math.clamp((m - 1.0) / (Rules.GARRISON_CONC_FULL - 1.0), 0.0, 1.0)
	end

	--- Where a garrison ordered at `t` stands: the own tile within `snap` tiles of it that lies deepest
	--- inside `id`'s land (no foreign or free land within GARRISON_SITE_DEPTH tiles, or as few as can
	--- be), nearest `t` among those. A garrison on the very edge would be encircled at once.
	function C._garrison_site(self: any, id: number, t: number, snap: number): number
		local owner = self.owner
		local land = self.land
		local W = self.W
		local H = self.H
		local function clear_within(c: number, k: number): boolean
			local cx = c % W
			local cy = c // W
			for dy = -k, k do
				local y = cy + dy
				if y < 0 or y >= H then
					continue
				end
				for dx = -k, k do
					local x = cx + dx
					if x < 0 or x >= W then
						continue
					end
					local n = y * W + x
					if readu8(land, n) == 1 and readi32(owner, n * 4) ~= id then
						return false
					end
				end
			end
			return true
		end
		local cands = {}
		for _, c in self:disk_tiles(t, snap, true) do
			if readi32(owner, c * 4) == id and self.gar_at[c] == nil then
				table.insert(cands, c)
			end
		end
		local range_d2 = self.range_d2
		for k = Rules.GARRISON_SITE_DEPTH, 1, -1 do
			local best, bd = -1, math.huge
			for _, c in cands do
				local d = range_d2(c, t)
				if d < bd and clear_within(c, k) then
					best, bd = c, d
				end
			end
			if best >= 0 then
				return best
			end
		end
		return t
	end

	--- Moves `ratio` of `id`'s reserve to a garrison at `t` (or into its garrison nearby). True when
	--- troops were sent.
	function C.station(self: any, id: number, t: number, ratio: number): boolean
		if self.gar_of == nil or not Defs.is_finite(ratio) or t < 0 or t >= self.N or readu8(self.land, t) == 0 then
			return false
		end
		if readi32(self.owner, t * 4) ~= id then
			self:msg(id, Defs.MSG_INFO, "Station troops on your own land")
			return false
		end
		local troops = math.floor(self.o_troops[id] * math.clamp(ratio, 0.01, 1.0))
		if troops < 1.0 then
			self:msg(id, Defs.MSG_INFO, "No troops in reserve to station")
			return false
		end
		local range = self.R.garrison_range()
		local g = self:garrison_near(id, t, range * Rules.GARRISON_MERGE)
		if g == nil then
			if self:garrison_count(id) >= Rules.GARRISON_MAX then
				self:msg(
					id,
					Defs.MSG_INFO,
					string.format("You have %d garrisons already: disband one first", Rules.GARRISON_MAX)
				)
				return false
			end
			t = self:_garrison_site(id, t, range * Rules.GARRISON_SNAP)
			if self.gar_at[t] ~= nil then
				return false
			end
			local ng: Garrison = {
				gid = self.next_gid,
				owner = id,
				tile = t,
				troops = 0.0,
				pending = 0.0,
				pending_at = 0,
				cover_border = 0,
				conc = 0.0,
				dead = false,
			}
			self.next_gid += 1
			table.insert(self.garrisons, ng)
			self.gar_by_id[ng.gid] = ng
			self.gar_at[t] = ng
			local list = if self.gar_of ~= nil then self.gar_of[id] else nil
			if list == nil then
				list = {}
				self.gar_of[id] = list
			end
			table.insert(list, ng)
			self:_garrison_cover(ng)
			g = ng
		end
		local gg = g :: Garrison
		self.o_troops[id] -= troops
		gg.pending += troops
		gg.pending_at = self.tick + Rules.GARRISON_FORM_TICKS
		self._gar_dirty = 2
		return true
	end

	--- Sends garrison `gid` of `id` back to the reserve. True when it was theirs.
	function C.disband(self: any, id: number, gid: number): boolean
		local g = self.gar_by_id[gid]
		if g == nil or g.dead or g.owner ~= id then
			return false
		end
		self.o_troops[id] += math.floor(g.troops + g.pending)
		self:_remove_garrison(g)
		return true
	end

	function C._remove_garrison(self: any, g: Garrison)
		if g.dead then
			return
		end
		g.dead = true
		g.troops = 0.0
		g.pending = 0.0
		self.gar_by_id[g.gid] = nil
		if self.gar_at[g.tile] == g then
			self.gar_at[g.tile] = nil
		end
		local list = self.gar_of[g.owner]
		if list ~= nil then
			local i = table.find(list, g)
			if i ~= nil then
				table.remove(list, i)
			end
		end
		local all = self.garrisons
		local j = table.find(all, g)
		if j ~= nil then
			table.remove(all, j)
		end
		self._gar_dirty = 2
	end

	--- SimState.set_owner: the tile a garrison stands on changed hands.
	function C._garrison_tile_changed(self: any, t: number, old: number, nw: number)
		local g = if self.gar_at ~= nil then self.gar_at[t] else nil
		if g == nil or g.dead or g.owner ~= old or nw == old then
			return
		end
		local back = math.floor((g.troops + g.pending) * Rules.GARRISON_OVERRUN_KEEP)
		self:_remove_garrison(g)
		if self.o_alive[old] == 1 then
			self.o_troops[old] += back
			if nw ~= 0 then
				self:msg(
					old,
					Defs.MSG_BAD,
					string.format(
						"%s overran your garrison: %s troops fell back",
						self.o_name[nw],
						troops_text(back)
					)
				)
			else
				self:msg(old, Defs.MSG_BAD, string.format("Your garrison lost its ground: %s troops fell back", troops_text(back)))
			end
		end
		if nw ~= 0 and self:is_human(nw) then
			self:msg(nw, Defs.MSG_GOOD, string.format("You overran %s's garrison", self.o_name[old]))
		end
	end

	--- Every garrison of `id` is gone (elimination): its troops with it.
	function C._clear_garrisons(self: any, id: number)
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil then
			return
		end
		for _, g in table.clone(list) do
			self:_remove_garrison(g)
		end
	end

	--- `id` lost this share of its troops (a strike or a nuke): its garrisons lose it too.
	function C._scale_garrisons(self: any, id: number, keep: number)
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil or #list == 0 then
			return
		end
		local k = math.clamp(keep, 0.0, 1.0)
		for _, g in list do
			g.troops *= k
			g.pending *= k
		end
		self._gar_dirty = math.max(self._gar_dirty, 1)
	end

	--- A blast at `center` of `radius` tiles wipes out every garrison inside it (before its tiles
	--- turn to fallout, which would otherwise let them fall back).
	function C._garrisons_blast(self: any, center: number, radius: number, by: number)
		if self.garrisons == nil or #self.garrisons == 0 then
			return
		end
		local range_d2 = self.range_d2
		local r2 = radius * radius
		for _, g in table.clone(self.garrisons) do
			if not g.dead and range_d2(center, g.tile) <= r2 then
				local o = g.owner
				local lost = g.troops + g.pending
				self:_remove_garrison(g)
				if o ~= by then
					self:msg(
						o,
						Defs.MSG_BAD,
						string.format("%s wiped out your garrison of %s troops", self.o_name[by], troops_text(lost))
					)
				end
			end
		end
	end

	--- An attack at `t` launched from `id`'s garrison near it (see header). False when no garrison of
	--- theirs can launch it (the caller sends an ordinary attack instead).
	function C.garrison_attack(self: any, id: number, t: number, ratio: number): boolean
		local list = if self.gar_of ~= nil then self.gar_of[id] else nil
		if list == nil or #list == 0 or not Defs.is_finite(ratio) then
			return false
		end
		if t < 0 or t >= self.N or readu8(self.land, t) == 0 then
			return false
		end
		local tg = readi32(self.owner, t * 4)
		if tg == id then
			return false
		end
		if tg ~= 0 and (self:allied(id, tg) or self.o_alive[tg] == 0 or self:shielded(tg)) then
			return false -- (the ordinary attack says why)
		end
		local range = self.R.garrison_range()
		local range_d2 = self.range_d2
		-- the nearest ready garrison within reach
		local reach2 = (range * Rules.GARRISON_REACH) ^ 2
		local g: Garrison? = nil
		local gd = math.huge
		for _, c in list do
			if c.troops >= 1.0 then
				local d = range_d2(c.tile, t)
				if d <= reach2 and d < gd then
					g = c
					gd = d
				end
			end
		end
		if g == nil then
			return false
		end
		local gg = g :: Garrison
		-- the launch tile: own land within the garrison's range touching the target, nearest `t`
		local owner = self.owner
		local launch = -1
		local ld = math.huge
		for _, s in self:disk_tiles(gg.tile, range, true) do
			if readi32(owner, s * 4) == id and touches(self, s, tg) then
				local d = range_d2(s, t)
				if d < ld then
					launch = s
					ld = d
				end
			end
		end
		if launch < 0 then
			return false
		end
		local troops = math.floor(gg.troops * math.clamp(ratio, 0.01, 1.0))
		if troops < 1.0 then
			return false
		end
		gg.troops -= troops
		self._gar_dirty = math.max(self._gar_dirty, 1)
		self.dbg_flow[id * 5] += troops
		local a = self:start_attack(id, tg, troops, launch)
		if a == nil then
			-- (start_attack refunded the reserve, or the troops went into cancelling a counter-attack)
			return true
		end
		return true
	end

	--- Arrivals, deaths, cover counts, and the clients' copy.
	function C.garrisons_tick(self: any)
		local all = self.garrisons
		if all == nil then
			return
		end
		if #all == 0 then
			if self._gar_dirty == 2 then
				self:ev({ Ev.GARRISONS, {} })
				self._gar_dirty = 0
			end
			return
		end
		local tick = self.tick
		local every = Rules.GARRISON_COVER_TICKS
		for _, g in table.clone(all) do
			if g.dead then
				continue
			end
			if g.pending > 0.0 and tick >= g.pending_at then
				g.troops += math.floor(g.pending)
				g.pending = 0.0
				self._gar_dirty = math.max(self._gar_dirty, 1)
			end
			if g.troops < 1.0 and g.pending < 1.0 then
				local o = g.owner
				self:_remove_garrison(g)
				if self.o_alive[o] == 1 then
					self:msg(o, Defs.MSG_BAD, "One of your garrisons was wiped out")
				end
				continue
			end
			if (tick + g.gid) % every == 0 then
				self:_garrison_cover(g)
			end
		end
		local dirty = self._gar_dirty
		if dirty == 2 or (dirty == 1 and tick % Rules.GARRISON_UPDATE_TICKS == 0) then
			self:ev({ Ev.GARRISONS, self:garrison_rows() })
			self._gar_dirty = 0
		end
	end

	--- Flat list: gid, owner, tile, troops, pending, ready_tick for every garrison.
	function C.garrison_rows(self: any): { number }
		local out = {}
		if self.garrisons == nil then
			return out
		end
		local n = 0
		local trunc = Defs.trunc
		for _, g in self.garrisons do
			if g.dead then
				continue
			end
			out[n + 1] = g.gid
			out[n + 2] = g.owner
			out[n + 3] = g.tile
			out[n + 4] = trunc(g.troops)
			out[n + 5] = trunc(g.pending)
			out[n + 6] = if g.pending > 0.0 then g.pending_at else 0
			n += 6
		end
		return out
	end
end

return SimGarrisons
