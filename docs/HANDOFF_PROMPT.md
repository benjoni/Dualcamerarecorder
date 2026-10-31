# Prompt pre Claude na Macu (Claude Desktop → Code, lokálny priečinok)

Skopíruj celý text pod čiarou do nového Claude Code sedenia na Macu.

---

Pracujeme na mojej macOS aplikácii **DualCamRecorder**. Komunikuj so mnou po slovensky, ale celé UI aplikácie musí zostať v angličtine.

## Repozitár
- GitHub: `https://github.com/benjoni/Dualcamerarecorder`, vetva `main`.
- Ak projekt na Macu ešte nie je, naklonuj ho do `~/Documents/Dualcamerarecorder`. Ak už existuje, sprav `git pull`.
- Commituj a pushuj do `main` v tomto repozitári. **Nikdy nepushuj do repozitára `benjoni/hafanana`.**

## Čo je to za aplikáciu
Natívna macOS 14+ aplikácia (Swift / SwiftUI, Apple Silicon) pre Mac mini, ku ktorému sú cez Thunderbolt pripojené dve Blackmagic UltraStudio Recorder 3G (SDI z DJI Ronin 4D, HD). Aplikácia:
- súčasne nahráva dve kamery do ProRes 422 `.mov` so SDI zvukom a zarovnaným štartom A/B podľa hardvérových časových pečiatok,
- vedie projekty (priečinok + `PROJECT.JSON`), klapku (scene / shot / take, shooting day, DoP, …), IN/OUT, cam clip ID, zálohu na druhý disk, PDF report, živý náhľad na telefóny,
- prehráva dvojice záberov synchronizovane (dva AVPlayery),
- vie dočasne vypnúť jednu kameru (nadpis „Camera A / B“ nad obrazom je ON/OFF tlačidlo, ⌥1 / ⌥2).

Podrobný popis všetkých funkcií je v `README.md`, plán v `docs/PLAN.md` a makety obrazoviek v `docs/preview/` (sú to iba makety).

Štruktúra:
- `DualCamRecorder/Bridge/DLCapture.h/.mm` – Objective-C++ most na DeckLink SDK (`__has_include`, bez SDK len simulovaný vstup)
- `DualCamRecorder/Capture`, `Recording`, `Preview`, `Playback`, `Views`, `App`
- `DualCamRecorder.xcodeproj` sa generuje cez `python3 tools/gen_xcodeproj.py`. Spusti ho po pridaní alebo odobratí zdrojového súboru.

## Dôležité: kód ešte NIKDY nebol skompilovaný
Vznikol v cloude bez Macu. Objective-C++ prešiel cez `clang -fsyntax-only` proti macOS SDK a DeckLink hlavičkám, Swift iba syntaktickou kontrolou. Pri prvom builde preto očakávaj chyby typov, chýbajúce importy, nesúlad API a podobne.

## Úloha, postupne

1. **Skontroluj prostredie:** `xcodebuild -version`, `swift --version`, či je nainštalovaný Blackmagic Desktop Video (`/Library/Frameworks/DeckLinkAPI.framework`) a či existuje `DeckLinkSDK/Mac/include/DeckLinkAPI.h`. Povedz mi, čo chýba.

2. **Build bez SDK (simulovaný vstup):**
   ```
   xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder -configuration Debug -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
   ```
   Opravuj chyby, kým nepríde `BUILD SUCCEEDED`. Opravy rob minimálne a nemeň správanie ani vzhľad. Ak nejakú funkciu nejde rozumne opraviť, opýtaj sa ma.

3. **Spusti aplikáciu** (`open build/Build/Products/Debug/DualCamRecorder.app`) so simulovaným vstupom. Skontroluj spustenie, úvodnú stránku s projektmi, vytvorenie projektu, Record (REC/STOP, vzniknú súbory `A001_…MOV`), Playback a export PDF. Ak môžeš, urob screenshoty a pozri sa na ne. Nájdené chyby oprav.

4. **Commitni a pushni** opravy do `main` s jasnými správami.

5. **DeckLink SDK:** keď ti poviem, že mám stiahnutý Desktop Video SDK, pomôž mi skopírovať obsah `Blackmagic DeckLink SDK xx.y/` do `./DeckLinkSDK` (musí existovať `DeckLinkSDK/Mac/include/DeckLinkAPI.h`, priečinok je v `.gitignore`). Potom sprav build znova a oprav chyby v `DLCapture.mm`. Pri SDK ≥ 14.3 sa používajú legacy rozhrania `*_v14_2_1`.

6. **Test so skutočnými kamerami:** s pripojenými UltraStudio a zapnutými kamerami over detekciu zariadení, automatické rozpoznanie formátu, náhľady, nahrávanie oboch kamier, počítadlo vynechaných snímok a offset B−A.

## Pravidlá
- Pred väčšou zmenou alebo zmenou vzhľadu sa ma opýtaj.
- Nikdy netvrď, že niečo funguje, ak si to neoveril buildom alebo spustením.
- README je po slovensky. Pri zmene funkcií ho aktualizuj.
- Do commitov ani do kódu nedávaj názov modelu.
