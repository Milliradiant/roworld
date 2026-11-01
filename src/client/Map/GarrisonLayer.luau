--!native
-- Garrisons on the 2D map (Core/SimGarrisons; this fork, 2026-11-01):
--   * a badge per garrison at its tile: a pill in its owner's colour with its troops (render_troops),
--     "+N" after them while troops are on their way, a dimmed pill while none has arrived yet;
--   * the local player's own garrisons also show a ring: the land they guard (Rules.garrison_range);
--   * under the fog of war (state.fog, Map/FogOfWar) another owner's garrison shows only where the
--     local player can see.
-- Pooled per garrison id; a plate is written only what changed.
-- (Lune tests load it with the shared modules from the repo)
local IS_ROBLOX = (game :: any) ~= nil
local NumberFormat: any = if IS_ROBLOX
	then require(game:GetService("ReplicatedStorage"):WaitForChild("Airfront"):WaitForChild("Core"):WaitForChild("NumberFormat")) :: any
	else (require :: any)("../../shared/Core/NumberFormat")

local GarrisonLayer = {}
GarrisonLayer.__index = GarrisonLayer

GarrisonLayer.Z = 12
GarrisonLayer.TEXT_PX = 13
GarrisonLayer.FONT = Font.fromId(12187365977, Enum.FontWeight.Bold)
--- the ring (own garrisons): stroke px and transparencies
GarrisonLayer.RING_PX = 2
GarrisonLayer.RING_ALPHA = 0.35
GarrisonLayer.FILL_ALPHA = 0.9
--- a ring smaller than this (px across) isn't drawn: far zoomed out it would only clutter
GarrisonLayer.RING_MIN_PX = 14

type Plate = {
	badge: Frame,
	text: TextLabel,
	stroke: UIStroke,
	ring: Frame,
	ring_stroke: UIStroke,
	vis: boolean,
	ring_vis: boolean,
	label: string,
	color: Color3?,
	forming: boolean?,
	x: number,
	y: number,
	d: number,
}

function GarrisonLayer.new(parent: Instance, view: any)
	local self = setmetatable({}, GarrisonLayer) :: any
	local root = Instance.new("Frame")
	root.Name = "Garrisons"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.ZIndex = GarrisonLayer.Z
	root.Parent = parent
	self.root = root
	self.view = view
	self._state = nil :: any
	self._plates = {} :: { [number]: Plate }
	return self
end

function GarrisonLayer.bind(self: any, state: any)
	self._state = state
end

function GarrisonLayer.unbind(self: any)
	self._state = nil
	for gid, p in self._plates do
		p.badge:Destroy()
		p.ring:Destroy()
		self._plates[gid] = nil
	end
end

function GarrisonLayer.destroy(self: any)
	self:unbind()
	self.root:Destroy()
end

local function new_plate(self: any): Plate
	local ring = Instance.new("Frame")
	ring.Name = "GarrisonRing"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.BackgroundTransparency = GarrisonLayer.FILL_ALPHA
	ring.BorderSizePixel = 0
	ring.ZIndex = GarrisonLayer.Z
	ring.Visible = false
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(1, 0)
	rc.Parent = ring
	local rs = Instance.new("UIStroke")
	rs.Thickness = GarrisonLayer.RING_PX
	rs.Transparency = GarrisonLayer.RING_ALPHA
	rs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	rs.Parent = ring
	ring.Parent = self.root

	local badge = Instance.new("Frame")
	badge.Name = "Garrison"
	badge.AnchorPoint = Vector2.new(0.5, 0.5)
	badge.AutomaticSize = Enum.AutomaticSize.XY
	badge.Size = UDim2.fromOffset(0, 0)
	badge.BorderSizePixel = 0
	badge.ZIndex = GarrisonLayer.Z + 1
	badge.Visible = false
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(1, 0)
	bc.Parent = badge
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 2)
	pad.Parent = badge
	local bs = Instance.new("UIStroke")
	bs.Thickness = 1.5
	bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bs.Parent = badge
	local text = Instance.new("TextLabel")
	text.Name = "Troops"
	text.BackgroundTransparency = 1
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.Size = UDim2.fromOffset(0, 0)
	text.FontFace = GarrisonLayer.FONT
	text.TextSize = GarrisonLayer.TEXT_PX
	text.TextColor3 = Color3.new(1, 1, 1)
	text.ZIndex = GarrisonLayer.Z + 2
	text.Parent = badge
	badge.Parent = self.root
	return {
		badge = badge,
		text = text,
		stroke = bs,
		ring = ring,
		ring_stroke = rs,
		vis = false,
		ring_vis = false,
		label = "",
		color = nil,
		forming = nil,
		x = math.huge,
		y = math.huge,
		d = -1,
	}
end

local function hide(p: Plate)
	if p.vis then
		p.vis = false
		p.badge.Visible = false
	end
	if p.ring_vis then
		p.ring_vis = false
		p.ring.Visible = false
	end
end

function GarrisonLayer.tick(self: any, _dt: number)
	local st = self._state
	local plates = self._plates
	if st == nil or st.garrisons == nil then
		return
	end
	local cam = self.view.rig
	local scale = cam.scale
	local me = st.local_owner
	local fog = st.fog
	local range = st.rules.garrison_range()
	local ring_d = 2.0 * range * scale
	-- garrisons gone since the last frame
	for gid, p in plates do
		if st.garrisons[gid] == nil then
			p.badge:Destroy()
			p.ring:Destroy()
			plates[gid] = nil
		end
	end
	for gid, g in st.garrisons do
		local p = plates[gid]
		local mine = g.owner == me and me ~= 0
		local seen = mine or fog == nil or fog:visible(g.tile)
		local x, y = cam:tile_to_screen(g.tile)
		if not seen or not cam:on_screen(x, y, (if mine then ring_d * 0.5 else 0) + 40) then
			if p ~= nil then
				hide(p)
			end
			continue
		end
		if p == nil then
			p = new_plate(self)
			plates[gid] = p
		end
		local pp = p :: Plate
		local o = st.owners[g.owner]
		local col: Color3 = if o ~= nil and o.color ~= nil then o.color else Color3.new(0.6, 0.6, 0.6)
		local forming = g.troops < 1
		if pp.color ~= col or pp.forming ~= forming then
			pp.color = col
			pp.forming = forming
			local h, sat, v = col:ToHSV()
			pp.badge.BackgroundColor3 = Color3.fromHSV(h, sat, v * 0.55)
			pp.badge.BackgroundTransparency = if forming then 0.45 else 0.05
			pp.stroke.Color = Color3.fromHSV(h, sat * 0.6, math.min(1, v * 1.25))
			pp.stroke.Transparency = if forming then 0.5 else 0.0
			pp.ring.BackgroundColor3 = col
			pp.ring_stroke.Color = col
		end
		local label = if forming then "" else NumberFormat.render_troops(g.troops)
		if g.pending >= 1 then
			label = (if label == "" then "" else label .. " ") .. "+" .. NumberFormat.render_troops(g.pending)
		end
		if pp.label ~= label then
			pp.label = label
			pp.text.Text = label
		end
		if not pp.vis then
			pp.vis = true
			pp.badge.Visible = true
		end
		if pp.x ~= x or pp.y ~= y then
			pp.x, pp.y = x, y
			pp.badge.Position = UDim2.fromOffset(x, y)
			pp.ring.Position = UDim2.fromOffset(x, y)
		end
		local want_ring = mine and ring_d >= GarrisonLayer.RING_MIN_PX
		if want_ring then
			if pp.d ~= ring_d then
				pp.d = ring_d
				pp.ring.Size = UDim2.fromOffset(ring_d, ring_d)
			end
			if not pp.ring_vis then
				pp.ring_vis = true
				pp.ring.Visible = true
			end
		elseif pp.ring_vis then
			pp.ring_vis = false
			pp.ring.Visible = false
		end
	end
end

return GarrisonLayer
