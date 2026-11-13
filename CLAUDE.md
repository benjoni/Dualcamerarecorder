# DualCamRecorder – pokyny pre Claude

Natívna macOS appka (Swift / SwiftUI + Obj-C++ most na Blackmagic DeckLink SDK): nahrávanie dvoch SDI
kamier, prehrávanie, strih, reporty, živý náhľad na telefónoch. Podrobný popis funkcií je v `README.md`.

## Pravidlá

- **Komunikácia po slovensky, UI appky po anglicky.**
- **Do commitov ani do kódu nedávaj názov modelu.** Žiadny riadok `Co-Authored-By` s modelom ani
  `Claude-Session`, autor commitu je používateľ (git config na Macu).
- **Push len na pokyn „Push“** a len do `main` v `benjoni/Dualcamerarecorder`.
  Nikdy nie do `benjoni/hafanana` (nesúvisiaci pokusný repozitár).
- Commit len na požiadanie. Pred `git pull` s lokálnymi zmenami: zálohovať (`git stash`), potom vrátiť
  a vyriešiť konflikty tak, aby zostali obe strany.
- Nehovor, že niečo funguje, kým to nie je overené (build, test, záber). Čo sa overiť nedalo, povedz.

## Kde to beží

- Jediná pracovná kópia: `~/Documents/projekty/dualrecorder` na **Mac mini** (Apple Silicon, Xcode 26).
  Z iného počítača sa pracuje cez SSH session v aplikácii Claude (`peterbencsik@mac-mini-uvatea-peter`, Tailscale).
- `~/Documents` je v **iCloud Drive** – súbory dostávajú rozšírené atribúty, preto podpis v tomto priečinku zlyhá
  (viď Build).
- Hardvér: Blackmagic UltraStudio (Thunderbolt), ovládač Desktop Video. Kým ho Mac nevidí
  (`system_profiler SPThunderboltDataType`), testuje sa so simulovaným vstupom.
- Cloudové sessiony (claude.ai/code) bežia na Linuxe – **appku nezostavia**. Ich zmeny treba pred
  pushom zostaviť na Macu.

## Build

```bash
# Debug (vývoj, testovacie prepínače nižšie)
xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder -configuration Debug \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build

# Release (skutočné nahrávanie – Debug je na to pomalý)
xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder -configuration Release \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

- Vždy s `CODE_SIGNING_ALLOWED=NO`. Bez neho build v iCloud priečinku spadne na podpise
  („resource fork, Finder information, or similar detritus not allowed“) – to nie je chyba kódu.
- Výsledok: `build/Build/Products/<Debug|Release>/DualCamRecorder.app`.
- DeckLink SDK je v `DeckLinkSDK/` (nie je v gite). Bez neho build prejde, ale len so simulovaným vstupom.
- **Nový alebo zmazaný zdrojový súbor:** `python3 tools/gen_xcodeproj.py` (zachová verziu aj číslo buildu).
- **Vydanie** (podpis Developer ID, Hardened Runtime, notarizácia, zip do `dist/`): `tools/release.sh`.
  Podpisuje v dočasnom priečinku mimo iCloudu. Notarizácia potrebuje odomknutý Mac (keychain profil
  `DualCamNotary`). Pred vydaním zvýš `CURRENT_PROJECT_VERSION` v `project.pbxproj`.

## Testovanie

- **Nezasahuj do appky, ktorú má používateľ otvorenú.** Pred ukončením over, že nenahráva
  (`lsof -p <pid> | grep -i '\.mov'`), a radšej testuj samostatnou inštanciou Debug buildu.
- Na testy používaj dočasný projekt mimo jeho projektov:
  `-projectsRootPath <dočasný priečinok>` s `PROJECT.JSON` (simulované vstupy: `"deviceA": "simulated"`).
  Nastavenia projektu meň v `PROJECT.JSON`, keď appka nebeží.
- Keď je Mac zamknutý, appka neotvorí okno – testy čakajú donekonečna.
  Stav: `ioreg -n Root -d1 -a | grep CGSSessionScreenIsLocked`.
- Prepínače len v **Debug** builde (spúšťať priamo binárku `.../Contents/MacOS/DualCamRecorder` s
  `-ApplePersistenceIgnoreState YES`):
  - `-snapshotDir <priečinok> -snapshotProject <názov>` – uloží obrázky okien (record, playback, edit, help,
    mask, live view …); video je v nich čierne. `-snapshotWindowSize WxH`.
  - `-triggerTestProject <názov> -triggerTestDir <priečinok> -simCameraRec <s>` – simulovaná kamera sama
    spustí a zastaví záber, potom ručný záber; výsledok v `result.txt`. `-triggerTestDetection flag|recRun`.
  - `-diskTestProject … -diskTestDir …` – nahráva, kým sa projektový disk neodpojí (test s .dmg).
  - `-editExportTestProject … -editExportTestDir …`, `-playbackEndTestProject … -playbackEndTestDir …`.
  - Simulácia: `-simCameraRec <s>`, `-simNoRecFlag YES`, `-simStreamRestart <s>`, `-debugWriteDelay <s>`.
- Obsah nahratých súborov kontroluj cez `ffprobe` / `ffmpeg` (snímka do PNG).
