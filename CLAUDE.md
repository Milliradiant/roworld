# Terra (fork of RoWorld)

A fork of lukechatton/roworld (itself an OpenFront port), for Roblox. See README.md.

- Name and source link: `src/shared/Data/Brand.luau` only. The internal `Airfront` instance names
  (ReplicatedStorage.Airfront, AirfrontServer, AirfrontClient) are code paths, not branding: leave them.
- Everything is free: `Purchases.FREE_FOR_ALL` (server), every product id forced to 0
  (`Data/Products`), no subscription (`Data/Subscription.ID = ""`). Tests that exercise the paid paths
  set `FREE_FOR_ALL = false` themselves.
- No outside services: `LobbyHttp.ENABLED = false`, lobbies on MemoryStore.
- Garrisons (Core/SimGarrisons): `o_troops` is the RESERVE only; garrison troops live in the garrison
  records (`garrison_total(id)`), and growth / the cap count both. Clients mirror them through
  Ev.GARRISONS (full list) and GameState.garrisons; `GameState:army(id)` = reserve + garrisons. Any new
  code that kills or moves an owner's troops must think about garrisons too (`_scale_garrisons`).
- Fog of war (Core/FogOfWar, client only, `Rules.FOG_OF_WAR`): `state.fog`. `GameState:tile_owner`
  returns 0 for a tile out of sight (UI code gets the fog for free); `true_owner` is the real owner.
  Map layers skip what `fog:visible(tile)` says is hidden and redraw when `fog.version` changes.
- Licence (AGPL v3 + LICENSE additional terms): keep "© OpenFront and Contributors" visible, keep the
  Help card's credits and Source line, never title it OpenFront.
- Build: `rojo build release.project.json -o build/Terra.rbxl`. Tests: `lune run tests/<name>.luau`
  with Lune 0.10 or newer (the maps need its zstd; 0.8 fails to load every sim test). Compare against
  a clean checkout rather than expecting all green.
- Git: commits are authored as Milliradiant <323546726+Milliradiant@users.noreply.github.com> (the
  account was Unproblematical before 2026-11-01), unsigned or signed with the user's own key, never
  Claude's, and with no Claude attribution of any kind.
