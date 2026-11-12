# Tested games

Android games known to run with Lepton x86_64. Compatibility varies from game
to game, and a game that works in one version may break in an update of the
game or of Lepton.

**Bundle** says what the game needs:
- **Base:** works with the release bundles from
  [GitHub Releases](https://github.com/pjohno/lepton-x86_64/releases).
- **NDK:** needs ARM64 translation, in a bundle you make yourself
  ([CUSTOMIZING.md](CUSTOMIZING.md), [GAPPS.md](GAPPS.md)).
- **GApps:** needs Google Play services, in a bundle you make yourself.

**Added as** says how the game gets into Steam:
- **Non-Steam game:** you download the `.apk` or `.apkm` and add it to Steam
  ([INSTALL-STEAM-DECK.md](INSTALL-STEAM-DECK.md)).
- **Steam (Android build):** a Steam game with an Android version. Select
  Lepton as its compatibility tool, and Steam downloads the Android build and
  Lepton runs it.

## Working

| Game | Source | Added as | Bundle | Last tested |
| --- | --- | --- | --- | --- |
| 2048 | [F-Droid](https://f-droid.org/repo/org.andstatus.game2048_47.apk) | Non-Steam game | Base | v0.2.0-alpha |
| AAAAXY | [F-Droid](https://f-droid.org/repo/io.github.divverent.aaaaxy_108300344.apk) | Non-Steam game | NDK | v0.2.0-alpha |
| Crossy Road | [APKMirror](https://www.apkmirror.com/apk/hipster-whale/crossy-road/crossy-road-7-14-3-release/crossy-road-7-14-3-android-apk-download/) (7.14.3) | Non-Steam game | GApps | v0.2.0-alpha |
| KingPong | [F-Droid](https://f-droid.org/repo/com.kingalex.kingpong_8.apk) | Non-Steam game | Base | v0.2.0-alpha |
| Mind Gazing Demo | [Steam](https://store.steampowered.com/app/4708770/Mind_Gazing/) | Steam (Android build) | NDK | v0.2.0-alpha |
| RetroArch | [F-Droid](https://f-droid.org/repo/com.retroarch_1597175267.apk) | Non-Steam game | Base | v0.2.0-alpha |
| Roblox | [APKMirror](https://www.apkmirror.com/apk/roblox-corporation/roblox/) | Non-Steam game | Base | v0.2.0-alpha |
| Sun Piano | [F-Droid](https://f-droid.org/repo/code.alimiracle.sunpiano_2.apk) | Non-Steam game | Base | v0.2.0-alpha |

Notes:
- **Mind Gazing** is a Flutter game built for ARM64 only. It needs the GL
  extension filter added in v0.2.0-alpha to get past its splash screen.

## Not working

None recorded yet.

## Adding a game

Open an [issue](https://github.com/pjohno/lepton-x86_64/issues) or a pull
request with:
- the game's name and where you got it (link and version);
- whether it works, partly works (say what doesn't) or doesn't start;
- the Lepton version, and whether your bundle has NDK or GApps;
- the computer (Steam Deck, or desktop with its GPU and desktop environment)
  and, on a Steam Deck, Gaming Mode or Desktop Mode.

Only list games from sources you may download them from. Don't link to copies
of paid games.
