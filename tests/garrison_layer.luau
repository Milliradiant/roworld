--!nocheck
-- Map/GarrisonLayer (this fork): a badge per garrison, a ring for the local player's own, nothing for
-- another's out of sight (Core/FogOfWar), plates gone with their garrisons.
local roblox = require("./prelude");
(getfenv() :: any).Instance = (roblox :: any).Instance;
(getfenv() :: any).Enum = (roblox :: any).Enum;
-- (Lune's Font.fromId takes 32-bit ids: the game's font is the Rubik family asset, past that)
(getfenv() :: any).Font = {
	fromId = function(_id, weight)
		return (roblox :: any).Font.new("rbxasset://fonts/families/GothamSSm.json", weight)
	end,
};
local WorldMap = require("../src/shared/Core/WorldMap")
local GameState = require("../src/shared/Core/GameState")
local Rules = require("../src/shared/Core/Rules")
local GarrisonLayer = require("../src/client/Map/GarrisonLayer")

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
local st = GameState.new(map)
st.loaded = true
st.local_owner = 1
st.owners[1] = { id = 1, color = Color3.new(0.2, 0.6, 1), troops = 0 }
st.owners[2] = { id = 2, color = Color3.new(1, 0.3, 0.2), troops = 0 }
local W = st.W
local rig = {
	scale = 4.0,
	tile_to_screen = function(_self, t)
		return (t % W) * 4.0 - 1000, (t // W) * 4.0 - 1000
	end,
	on_screen = function(_self, x, y, m)
		return x >= -m and y >= -m and x <= 1600 + m and y <= 900 + m
	end,
}
local parent = Instance.new("Frame")
local layer = GarrisonLayer.new(parent, { rig = rig })
layer:bind(st)
local t1 = 300 * W + 400
local t2 = 320 * W + 420
local hidden = { [t2] = true }
st.fog = {
	active = true,
	visible = function(_self, t)
		return not hidden[t]
	end,
}
st:_set_garrisons({ 1, 1, t1, 50000, 0, 0, 2, 2, t2, 30000, 1000, 77 }, true)
layer:tick(0.016)
local p1, p2 = layer._plates[1], layer._plates[2]
expect(p1 ~= nil and p1.vis and p1.badge.Visible, "the player's garrison has a badge")
expect(p1 ~= nil and p1.text.Text == "5.00K", "showing its troops (" .. tostring(p1 and p1.text.Text) .. ")")
local ring_d = 2 * st.rules.garrison_range() * rig.scale
expect(p1 ~= nil and p1.ring_vis and p1.ring.Size.X.Offset == ring_d, "and a ring as wide as the land it guards")
expect(p2 == nil or not p2.vis, "another's garrison out of sight shows nothing")
hidden[t2] = nil
layer:tick(0.016)
p2 = layer._plates[2]
expect(p2 ~= nil and p2.vis and string.find(p2.text.Text, "+", 1, true) ~= nil, "in sight it shows, with the troops on their way (" .. tostring(p2 and p2.text.Text) .. ")")
expect(p2 ~= nil and not p2.ring_vis, "no ring for someone else's")
st:_set_garrisons({ 2, 2, t2, 30000, 0, 0 }, true)
layer:tick(0.016)
expect(layer._plates[1] == nil, "a garrison gone takes its plate along")
layer:unbind()
expect(next(layer._plates) == nil, "unbind clears every plate")

if fails > 0 then
	error(fails .. " failures")
end
print("garrison_layer: all passed")
