--!nocheck
-- This fork sells nothing (server/Purchases.FREE_FOR_ALL, Data/Products): a brand-new player owns every
-- Arsenal item and every cosmetic they may own, someone else's exclusive stays theirs, the takeover is
-- always there, and no product exists to be offered.
require("./prelude")
local Products = require("../src/shared/Data/Products")
local Purchases = require("../src/server/Purchases")
local Arsenal = require("../src/shared/Data/Arsenal")
local Cosmetics = require("../src/shared/Data/Cosmetics")
local Subscription = require("../src/shared/Data/Subscription")

local fails = 0
local function expect(c: any, w: string)
	if c then
		print("  ok   " .. w)
	else
		fails += 1
		print("FAIL " .. w)
	end
end

local rows = {}
local store = {}
function store:UpdateAsync(k, fn)
	local new = fn(rows[k])
	if new ~= nil then
		rows[k] = new
	end
	return new
end
function store:GetAsync(k)
	return rows[k]
end
Purchases.configure({ datastore = store })

expect(Purchases.FREE_FOR_ALL == true, "everything is free")
local any_id = false
for _, p in Products do
	any_id = any_id or p.id ~= 0
end
expect(not any_id, "no Robux product exists")
expect(Subscription.id() == "", "no subscription is offered")

local P = { UserId = 123456, Name = "Newcomer" }
Purchases.load(P)
local inv = Purchases.inventory(P)
local owned = {}
for _, id in inv.owned do
	owned[id] = true
end

local all_unlocked = true
for _, it in Arsenal.ITEMS do
	all_unlocked = all_unlocked and Purchases.has_unlock(P, it.key)
end
expect(all_unlocked, "every Arsenal item is unlocked")
local all = {}
for _, it in Arsenal.ITEMS do
	all[it.key] = true
end
expect(Purchases.unlock_mask(P) == Arsenal.mask(all), "the match sees all of them")

local function owns_all(list: any): boolean
	for _, it in list do
		if not owned[it.id] then
			return false
		end
	end
	return true
end
expect(#Cosmetics.all() > 0 and owns_all(Cosmetics.all()), "every crate item is owned")
expect(owns_all(Cosmetics.shop_items()), "every shop flag is owned")
expect(owns_all(Cosmetics.generals()), "every General skin is owned")

local someone_elses = false
for _, it in Cosmetics.exclusives() do
	if owned[it.id] and not Cosmetics.may_own(it.id, P.UserId) then
		someone_elses = true
	end
end
expect(not someone_elses, "someone else's exclusive is not theirs")

expect((Purchases.credits(P).takeover or 0) >= 1, "a takeover is ready")
local ok = Purchases.use(P, "takeover")
expect(ok, "... and spent")
Purchases.release(P)
Purchases.load(P)
expect(Purchases.credits(P).takeover == Purchases.FREE_CREDITS, "... and back the next time they join")

expect(Purchases.equip(P, "skin", Cosmetics.all()[1].id), "any skin can be put on")

if fails > 0 then
	error(fails .. " failures")
end
print("free_for_all: all passed")
