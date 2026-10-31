# Terra (working name)

A real-world conquest game for Roblox: claim land, expand, ally and betray, build an economy, nuke your
neighbours, hold 80% of the world to win.

This is a modified version of [RoWorld](https://github.com/lukechatton/roworld) by Snick Co., which is
itself a modified version of [OpenFront](https://github.com/openfrontio/OpenFrontIO).
© OpenFront and Contributors. RoWorld's changes © 2026 Snick Co. Not affiliated with or endorsed by
OpenFront or Snick Co.

## What's different from RoWorld

- **Everything is free.** Every Arsenal item, skin, flag and shop flag is owned by every player, and the
  takeover is always available. No Robux purchases, no crates for sale, no General subscription.
  (`Purchases.FREE_FOR_ALL` in `src/server/Purchases.luau`; `tests/free_for_all.luau` checks it.)
- **No outside servers.** RoWorld's own lobby service is switched off; matchmaking runs on Roblox's
  MemoryStore, which works in any experience.
- **Placeholder branding.** The name lives in one file, `src/shared/Data/Brand.luau`: change `NAME` and
  `WORDMARK` there and the title screen, credits and prompts follow.

## Build it

The game is a [Rojo](https://rojo.space) project.

```
rojo build release.project.json -o build/Terra.rbxl
```

Open `build/Terra.rbxl` in Roblox Studio and press Play to test it solo.

## Put it on Roblox

1. In Studio: **File → Publish to Roblox As… → Create new experience.**
2. **Game Settings → Security:** turn on **Enable Studio Access to API Services** (so saves and lobbies
   also work when testing in Studio) and **Allow Mesh / Image APIs** (the map is drawn with EditableImage). Roblox only allows the second
   one for an account that is 13+ and ID-verified.
3. Publish again after changing settings, then make the experience public (or keep it private and add
   friends) on the Creator Dashboard.

Things that won't carry over from RoWorld:

- **Music and sound effects are silent.** Roblox locks audio to the experiences of whoever uploaded it.
  Upload your own and replace the ids in `src/shared/Assets/Soundtrack.luau`, `Audio.luau`,
  `AudioExtra.luau` and `AudioUI.luau`.
- **Images** (icons, flags, skins) are RoWorld's uploads, referenced by id. Public images normally load in
  any experience, but they stay theirs: re-upload them under your own account if you want them independent of theirs.

## Licence

GNU Affero General Public License v3 with the additional terms at the end of `LICENSE`. In short, any
public version must:

- keep "© OpenFront and Contributors" visible (the title screen footer and the Help → Credits card do);
- not be called OpenFront or claim to be endorsed by it;
- let players get the source: the Help card's Source line shows `Brand.SOURCE_REPO`, so keep that
  pointing at a public repository with the code that is actually running.
