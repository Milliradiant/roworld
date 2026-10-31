# Terra (fork of RoWorld)

A fork of lukechatton/roworld (itself an OpenFront port), for Roblox. See README.md.

- Name and source link: `src/shared/Data/Brand.luau` only. The internal `Airfront` instance names
  (ReplicatedStorage.Airfront, AirfrontServer, AirfrontClient) are code paths, not branding: leave them.
- Everything is free: `Purchases.FREE_FOR_ALL` (server), every product id forced to 0
  (`Data/Products`), no subscription (`Data/Subscription.ID = ""`). Tests that exercise the paid paths
  set `FREE_FOR_ALL = false` themselves.
- No outside services: `LobbyHttp.ENABLED = false`, lobbies on MemoryStore.
- Licence (AGPL v3 + LICENSE additional terms): keep "© OpenFront and Contributors" visible, keep the
  Help card's credits and Source line, never title it OpenFront.
- Build: `rojo build release.project.json -o build/Terra.rbxl`. Tests: `lune run tests/<name>.luau`
  (many sim tests need generated data that isn't in the repo and fail to load; compare against a clean
  checkout rather than expecting all green).
- Git: commits are authored as Unproblematical with the GitHub noreply address, with no Claude
  attribution of any kind.
