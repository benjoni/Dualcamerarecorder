# DualCamRecorder

Natívna macOS aplikácia (Swift / SwiftUI + Objective-C++ most na Blackmagic DeckLink SDK) na
**súčasné nahrávanie dvoch SDI kamier** cez dve Blackmagic UltraStudio Recorder 3G do ProRes 422
`.mov` a **synchronizované prehrávanie** dvojice záberov (nahrávanie a prehrávanie sa striedajú, nebežia naraz).

Cieľový hardvér: Mac mini M4 Pro, 2× UltraStudio Recorder 3G (Thunderbolt), 2× DJI Ronin 4D so SDI
výstupom nastaveným na HD (1080p, 3G-SDI).

Plán a architektúra: [`docs/PLAN.md`](docs/PLAN.md).

---

## Funkcie

Rozhranie aplikácie je **v angličtine** (Record / Playback / Slate …); tento README zostáva po slovensky.

### Úvodná stránka – projekty
- Po spustení sa zobrazí zoznam projektov (posledný otvorený hore) s počtom klipov, shooting day,
  réžiou, DoP a poznámkou.
- **New project…** (⌘N): názov + voliteľne réžia, DoP, poznámka. V *Projects location*
  (nastaviteľné) sa vytvorí **priečinok s rovnakým názvom** a doň sa nahráva. Znaky `/` a `:`
  sa v názve priečinka nahradia `-`.
- **Edit…**: zmena názvu (premenuje aj priečinok), réžie, DoP, poznámky.
- **Open** (alebo dvojklik): projekt sa otvorí v Record/Playback; na klapke sa vyplní
  Production / Director / DoP. Každý projekt si pamätá vlastnú klapku (shooting day, scéna,
  záber, pokus …) v `PROJECT.JSON` vo svojom priečinku.
- **Open folder as project…** pridá existujúci priečinok; **⋯ → Remove from list** projekt len
  skryje (súbory ostanú); 🔍 ho ukáže vo Finderi.
- Tlačidlo **Projects** v lište sa vráti na úvod (nie počas nahrávania).

### Malé okno
- Keď je okno nižšie ako 1050 bodov, záložka Record sa zhustí: menšie REC / IN / OUT s časomierou v jednom
  riadku, menšia klapka a polia slate (nápoveda len ako tooltip), počítadlá v jednom riadku. Počítadlá a
  nastavenia kamery sa už nezalamujú pod úzkym obrazom – obraz je v malom okne zhruba 2× väčší.
- Čo najväčší obraz: ⌘F (Screens only) alebo skryť Camera Settings.

### Obraz bez signálu
- Kamera bez vstupu (Unassigned) alebo bez signálu (No signal) ukazuje namiesto čierneho / zamrznutého
  obrazu logo BENJONI (kreslené vektorovo, `BenjoniLogo` v `Components.swift`).

### Strážca nahrávacieho disku
- Ak sa disk, na ktorý sa nahráva, počas záberu odpojí (vytiahnutý kábel, Eject), záber sa **okamžite
  zastaví** a cez celé okno sa ukáže veľké červené **Recording disk disconnected** (so zvukom).
  Súbory sa zapisujú po 2 s fragmentoch – čo sa dostalo na disk, sa dá prehrať. Slate a IN/OUT sa
  uložia do `~/Movies/DualCamRecorder Rescue/<projekt>/` (treba ich prekopírovať k súborom).
- Keď disk nestíha (snímky čakajú na zápis alebo sa zahadzujú), pod obrazmi sa ukáže oranžové
  **Disk too slow – CamA lost N frames**; po STOP ostane ako „Last take: …“ do ďalšieho REC (✕ ho skryje).
- Overené na obraze disku (`hdiutil detach -force` počas záberu) a s umelo spomaleným zápisom
  (Debug `-debugWriteDelay <µs>`); s reálnym USB/Thunderbolt diskom zatiaľ nie.

### Záloha na druhý disk (Project settings → Backup copy)
- Zapni **Copy clips to a second disk after every take** a vyber disk/priečinok – vytvorí sa v ňom
  priečinok s **názvom projektu**.
- Po každom STOP sa skopírujú nové / zmenené súbory: `.MOV` oboch kamier, `C###_SLATE.JSON`,
  `C###_MARKS.JSON`, `CLIPLOG.CSV`, `PROJECT.JSON`. Práve nahrávaný záber sa nekopíruje, kým sa
  nedokončí.
- Kopíruje sa do dočasného súboru, kontroluje sa veľkosť a až potom sa premenuje → v zálohe nikdy
  nie je polovičný súbor pod správnym menom.
- **Back up now** dokopíruje všetko chýbajúce (napr. keď disk nebol pripojený). Stav je
  v nastaveniach aj v Record pri voľnom mieste („Backup ✓ up to date“, „copying…“, červené
  „Backup disk not connected“).
- Nastavenie je súčasťou projektu (`PROJECT.JSON`).

### Číslo klipu v kamere (Cam clip)
- Pri každej kamere v Record je textové pole **Cam clip** (+ šípky) – názov/ID klipu, pod ktorým
  kamera nahráva interne, ľubovoľnej dĺžky (napr. `A001C0023`, `DJI_20261031_0023`).
- Po každom zábere sa **posledné číslo v texte zvýši o 1** s rovnakým počtom núl
  (`A001C0023` → `A001C0024`, `…_0099` → `…_0100`); len pri kamere, ktorá nahrávala.
  Dá sa kedykoľvek prepísať, šípky robia ±1, počas nahrávania je zamknuté.
- Ukladá sa ku klipu:
  - `C007_SLATE.JSON` → `cameraClipA`, `cameraClipB` (prázdne = kamera nenahrávala),
  - metadáta každého `.MOV`: vlastný kľúč `sk.dualcam.camera-clip` (celé ID),
    `com.apple.quicktime.information` = `Camera clip A001C0023` a riadok v popise,
  - **`CLIPLOG.CSV`** v priečinku projektu – riadok na každý súbor:
    `clip,camera,camera_name,file,camera_clip,shooting_day,scene,shot,take,good,mos,int_ext,day_night,recorded_at,production,note,camera_setup`.
    Prepíše sa po každom zábere, po úprave klapky a pri otvorení projektu.
- Čítanie skriptom, napr. `exiftool -Keys:All A007_S12_SH3B_T04.MOV` alebo priamo CSV.
- V Playback → **Edit slate…** sa dajú hodnoty dodatočne opraviť.

### Nastavenia kamery (Record → Camera Settings)
- Jedno tlačidlo **Camera Settings** v riadku **Slate** zapne/vypne pod oboma obrazmi polia
  **Lens, Stop, Distance, Height, Tilt, Filter, ISO, Shutter, WB** (voľný text, jednotky podľa štábu).
- Holé číslo dostane po opustení poľa jednotku: Lens `32` → `32mm`, Stop `2.8` → `T2.8`, Distance/Height `3.2` → `3.2 m`,
  Tilt/Shutter `180` → `180°`, WB `5600` → `5600K`. Text s vlastnou jednotkou (`AWB`, `1/50`, `10 ft`) ostane, ISO a Filter bez zmeny.
- Hodnoty ostávajú pre ďalšie zábery, kým ich nezmeníš (**Clear** vymaže); počas nahrávania sú zamknuté.
- Ukladajú sa ku klipu: `C007_SLATE.JSON` → `setupA`, `setupB` (kamera, ktorá nenahrávala, ostane prázdna),
  metadáta `.MOV` (kľúč `sk.dualcam.camera-setup` + riadok v popise), stĺpec `camera_setup` v `CLIPLOG.CSV`.
- V Playback sa zobrazia pod názvom súboru kamery, opraviť ich ide cez **Edit slate…**; vyhľadávanie ich prehľadáva.
- V PDF reporte je pod každým klipom riadok na kameru (prepínač **Camera settings** v exporte);
  vtedy je na strane o klip menej (5 na šírku / 7 na výšku).

### Výstup na monitor (Project settings → Monitor output, tlačidlo Monitor v hornej lište)
- Na SDI/HDMI výstup **UltraStudio Monitor 3G** sa pripojí Blackmagic monitor. V Project settings sa výstup len zapne
  („Send the picture to a Blackmagic monitor“) – použije sa prvé nájdené zariadenie s video výstupom
  (UltraStudio Recorder 3G výstup nemá). Kým nie je pripojené, prepínač sa nedá zapnúť; keď je zapnutý, zariadenie
  sa použije hneď, ako sa objaví.
- Čo ide na monitor, sa vyberá tlačidlom **Monitor** v hornej lište (vedľa Waveform, je tam len pri zapnutom výstupe):
  kamera A, kamera B alebo obe vedľa seba (**A | B**, každá na polovicu, čierne pruhy hore a dole).
- Na záložke Record ide živý obraz kamier, na Playback prehrávaný klip (pri pauze ostane posledná snímka),
  na **Edit strih** – vždy jeden obraz na celú plochu (voľba A / B / A | B sa tam nepoužije), bez popisu klipu.
- Na monitor ide len čistý obraz – žiadne ovládacie prvky, waveform ani texty appky.
- Formát výstupu = formát kamier (napr. 1080p25, 8-bit 4:2:2); keď ho zariadenie nevie, ukáže chybu (menu Monitor a nastavenia).
- Ukladá sa s projektom (`monitorEnabled`, `monitorSource` v `PROJECT.JSON`).
- Neotestované so skutočným UltraStudio Monitor – obraz (A, B, A | B, 10-bit vstup, Playback, strih z Edit) overený len testom bez hardvéru.

### Otočená kamera – Flip / Flop (Record, tlačidlá nad obrazom)
- **Flip** – obraz hore nohami (kamera namontovaná naopak), **Flop** – zrkadlovo zľava doprava
  (záber cez zrkadlo); oboje = otočenie o 180°.
- Otáča sa **originál hneď pri vstupe**: obraz v appke, Blackmagic monitor, telefóny aj **nahratý súbor**
  (ProRes ostáva 10-bit, farebné značky sa zachovajú). Hardvérové otočenie (VideoToolbox), ~2–3 ms na snímku 1080p.
- Na obraze je žlté **FLIP / FLOP**. Nastavenie je pre každý vstup a ukladá sa do projektu (PROJECT.JSON);
  počas nahrávania sa nedá meniť.

### Maska formátu – 1.85 / 2:1 / 2.35 / Custom (Record aj Playback, tlačidlo Mask nad obrazom)
- Čierne pruhy cez 16:9 obraz, ktoré ukážu výrez širšieho formátu (hore / dole), alebo užšieho (Custom
  napr. 1.33 – pruhy vľavo / vpravo). Custom pomer 1.00–3.00, rýchle voľby 1.33 / 1.66 / 2.39.
- **Opacity** 0–100 % (posuvník, rýchle voľby 25 / 50 / 75 / 100 %); tenká čiara ukazuje okraj výrezu.
- Pre každú kameru zvlášť, rovnaká v Record aj Playback, ukladá sa do projektu (PROJECT.JSON). Dá sa meniť
  aj počas nahrávania.
- Len na obrazovke appky – nahratý súbor, Blackmagic monitor ani telefóny masku nemajú.

### Timecode a REC kamery zo SDI (Project settings → Camera timecode and REC)
- **Timecode** z SDI signálu kamery (RP188 ATC/LTC, inak VITC) je vpravo dole na obraze v Record.
- Zapisuje sa do nahratého MOV ako **timecode stopa** (od timecodu prvej snímky, súvisle ďalej) –
  Resolve / Premiere / Avid / FCP nájdu zdrojový timecode. Overené `ffprobe` (stopa `tmcd`, tag timecode).
- **TC IN – TC OUT** každého súboru je v slate (C###_SLATE.JSON), v CLIPLOG.CSV (`tc_in`, `tc_out`), v PDF reporte
  a v Playback (timecode na aktuálnej pozícii aj v rohu obrazu ako v Record; keď ho slate nemá, číta sa
  z timecode stopy súboru). Drop-frame (29.97 / 59.94) sa počíta správne.
- Pod časomierou: **TC A / B in sync** alebo „B 3 frames behind A“ (porovnanie v rovnakom okamihu, ±1 snímka je bežná).
- **CAM REC / CAM STBY** vpravo hore = nahráva kamera sama. Zisťuje sa z príznaku nahrávania v SDI
  (RP188 record trigger), z **user bits timecodu pri kamerách Blackmagic** (Pyxis, URSA, Pocket: bit 0x08 = REC –
  voľba „Blackmagic (REC in timecode user bits)“; kameru Blackmagic appka spozná aj sama podľa tally paketu
  DID 51 / SDID 52 v signáli a vtedy číta user bits pri každej voľbe okrem Off; overené s Blackmagic Pyxis), alebo (voľba „Flag or Rec Run timecode“) z bežiaceho timecodu – kamera musí mať
  nastavený **Rec Run** timecode (pri Free Run beží stále, napr. Pyxis – vtedy Rec Run nepoužívať).
- Oranžové upozornenie: „Camera is NOT recording“ (appka nahráva, kamera nie) / „Camera is recording – the app is not“.
- **Record with the camera** (Off / A / B / Any camera): REC kamery spustí nahrávanie v appke, STOP ho zastaví
  (pri Any keď už žiadna nenahráva – kamera bez signálu / bez informácie o REC take nedrží). Appka začne cca 0,3 s po kamere (rozpoznanie + spoločný štart A/B) – presný
  posun ukáže timecode.
- **SDI data log** (Start / Stop pri každej kamere): do priečinka projektu zapíše `SDI_LOG_<kamera>_<čas>.TXT` –
  timecode, user bits, príznak REC a všetky ancillary (VANC) pakety, len keď sa zmenia. Na kamere stlačiť
  REC / STOP niekoľkokrát → v logu je vidieť, ktorý paket nesie stav nahrávania (Sony, ARRI … majú vlastné).
- Testované len so simulovaným vstupom (`-simCameraRec <s>`, `-simNoRecFlag YES`, test `-triggerTestProject`);
  so skutočnou kamerou a UltraStudio zatiaľ nie.

### Zvuk zo zvukového rozhrania – Focusrite Scarlett a pod. (Project settings → Audio interface)
- Zvuk od zvukára (výstup mixu) ide cez USB audio rozhranie, napr. **Focusrite Scarlett 3rd Gen**.
  Rozhranie sa zapojí do USB-C (aj cez hub), na macOS netreba ovládač.
- **Sound in the files:**
  - *Cameras only (SDI)* – ako doteraz, len zvuk z kamier.
  - *Audio interface only* – oba súbory (A aj B) dostanú zvuk z rozhrania, zvuk z kamier sa nezapisuje.
  - *Audio interface + cameras (SDI)* – zvuk z rozhrania je prvá (prehrávaná) stopa, zvuk z kamier druhá
    stopa (vypnutá pri prehrávaní, v strižni ostáva k dispozícii).
- **Device:** výber rozhrania, počet kanálov podľa zariadenia (Solo / 2i2: 2, 4i4: 4 …, max. 8).
  Zapisuje sa 48 kHz / 24 bit, aj keď rozhranie beží na 44,1 kHz (prevod robí macOS).
- Zvuk je zarovnaný s obrazom podľa spoločných hodín počítača; pri dlhých záberoch sa rozdiel hodín
  rozhrania a kamier priebežne dorovnáva (najviac 20 ms).
- **Sound delay (ms):** posun zvuku voči obrazu – kladná hodnota zvuk oneskorí (zvuk predbieha obraz,
  tlesknutie počuť skôr, ako ho vidno), záporná ho posunie skôr. 1 snímka = 40 ms pri 25p. Platí od ďalšieho záberu.
- Pri *Audio interface only* je pod obrazom každej kamery namiesto meradla zvuku zo SDI meradlo kanálov
  rozhrania (1, 2 …) – to, čo sa naozaj zapisuje do súboru.
- Pri *Audio interface + cameras* je meradlo rozhrania v riadku pod názvami súborov; keď rozhranie chýba, svieti červené *Audio interface not connected*
  (záber sa nahrá len so zvukom z kamier). Po odpojení a pripojení sa rozhranie samo znova spustí.
- Pri prvom použití sa macOS opýta na prístup k mikrofónu (audio vstupom) – treba povoliť.

### Dočasné vypnutie jednej kamery (Record, ⌥1 / ⌥2)
- V projekte s dvoma kamerami je nadpis **Camera A / Camera B** nad obrazom tlačidlo so značkou **ON / OFF**. Vypnutá kamera
  zmizne, druhá sa roztiahne na celú šírku a **nahráva sa len ona** (aj Cam clip sa zvýši len jej).
  Tlačidlo vypnutej kamery (**Camera B OFF**) ostane v nadpise vedľa zapnutej, kliknutím ju znova zapneš.
- Aspoň jedna kamera ostáva zapnutá; počas nahrávania sa prepínať nedá. Vypnutá kamera beží ďalej
  na pozadí, takže sa zapne okamžite. Platí aj v Screens only a pre živý náhľad na telefóny.
- Je to len dočasné – nastavenie projektu sa nemení a pri otvorení projektu sú obe kamery zapnuté.
- Playback ukáže len kameru, ktorá v zábere nahrávala (pri zábere len z B sa zapne zvuk B).

### Project settings (⚙ v lište projektu, ⌥⌘,)
- **1 camera / 2 cameras** – pri jednej kamere sa zobrazuje a nahráva len kamera A (cez celú
  šírku), kamera B sa vôbec nespúšťa; Playback ukáže B len pri záberoch, ktoré ju majú.
- Zariadenie a názov každej kamery, kodek (ProRes 422 / HQ / LT alebo **H.265 (HEVC)** – 8-bit Main, dátový tok
  5 (predvolene) / 10 / 20 / 45 Mbit/s pre 1080p (väčší obraz úmerne viac; overené na zábere: 5 → 5,1,
  45 → 45,3 Mbit/s), kľúčová snímka každú sekundu, hardvérový kodér; pri výbere sa kodér vopred zahreje, aby prvý take
  nestratil snímky), audio kanály, vynútenie 8-bit.
- Všetko sa ukladá do `PROJECT.JSON` projektu a obnoví sa pri jeho otvorení; nový projekt
  prevezme nastavenia z naposledy otvoreného. Počas nahrávania sa meniť nedajú.
- Globálne nastavenia (⌘,) obsahujú umiestnenie projektov, živý náhľad na telefóny a informácie o DeckLink.
- **Record / Playback / Edit** sa prepína veľkým prepínačom pod lištou alebo klávesmi **R** / **P** / **E** (nie počas písania do poľa).
- **Help** (tlačidlo v lište projektu, menu Help alebo ⌘?) otvorí okno so všetkými klávesovými skratkami,
  vysvetlivkami značiek (REC, LATEST, ★, vlajočka IN/OUT, MOS …), čísel a názvov súborov.

### Záložka NAHRÁVANIE
- Automatické zistenie DeckLink zariadení (`IDeckLinkDiscovery`, aj hot-plug); priradenie
  *zariadenie → Kamera A / Kamera B* cez výber nad náhľadom (pri prvom spustení 1. → A, 2. → B).
  Dve rovnaké zariadenia sa rozlišujú podľa `BMDDeckLinkPersistentID`, priradenie sa pamätá.
- Dva živé náhľady vedľa seba + **automaticky detegovaný formát** (`bmdVideoInputEnableFormatDetection`):
  rozlíšenie, snímková frekvencia, p/i, YUV/RGB, bitová hĺbka.
- Vstup je vynútene prepnutý na **SDI** (UltraStudio Recorder 3G má aj HDMI).
- Jedno tlačidlo **REC / STOP** (⌘R) ovláda obe kamery naraz.
- Každá kamera do vlastného súboru **ProRes 422** (voliteľne 422 HQ / LT) cez `AVAssetWriter`,
  so **SDI embedded audiom** (48 kHz, 2/8/16 kanálov, uložené ako 24-bit LPCM).
- Názvy súborov veľkými písmenami, na začiatku **názov kamery** a číslo klipu, potom skratky
  z klapky: `A007_S12_SH3B_T04.MOV` / `B007_S12_SH3B_T04.MOV`.
  - **A / B** = názov kamery – vyberá sa nad náhľadom zo **zoznamu kamier projektu** (Project settings →
    **Camera list**: názov + model, napr. `A` Venice, `B` Venice, `C` Ronin 4D; v menu „C · Ronin 4D“).
    Kameru, ktorú práve používa druhý vstup, menu neponúka. Premenovanie kamery v zozname premenuje aj vstup,
    ktorý ju používa. Viacpísmenový názov (napr. `RONIN1` → `RONIN1_007_S12_SH3B_T04.MOV`) dostane pred číslo `_`.
    Meno sa ukazuje aj v nadpise kamery (napr. „Camera C“), v Playbacku, v PDF reporte a v `CLIPLOG.CSV`
    (stĺpec `camera_name`). Staršie súbory nahraté pod predchádzajúcim menom (napr. `B007_…` po premenovaní
    B → C) appka naďalej nájde – použité mená si pamätá v `PROJECT.JSON`.
  - **007** = priebežné číslo klipu, rovnaké pre A aj B toho istého záberu, nikdy sa nepoužije znova.
  - **S** = scene (obraz), **SH** = shot (záber), **T** = take (pokus, 2 číslice).
  - Obraz/záber sa prevedú na veľké písmená bez diakritiky (iné znaky → `-`), prázdne pole sa vynechá.
  - Pri REC je vidno presné názvy ďalších súborov. Spoločné súbory záberu: `C007_SLATE.JSON`,
    `C007_MARKS.JSON`.
  - Staršie názvy (`C007_…_CAMA.MOV`, `TAKE_007_…_CAMA.MOV`, `Take_001_CamA.mov`) sa stále načítajú.
  - Po zmene názvu kamery sa súbory s pôvodným názvom v zozname nezobrazia, kým sa názov nevráti.
- **Synchronizovaný štart/stop** podľa hardvérových časových značiek (viď nižšie); po zábere sa
  zobrazí nameraný posun štartu B−A v ms.
- Počítadlá: zachytené / zapísané / **vynechané snímky (vstup)** / **vynechané (zápis)**,
  audio meter, odznak „Bez signálu“.
- **Voľné miesto** na cieľovom disku + odhad zostávajúceho času nahrávania.
- **Klapka** pod nahrávaním: projekt, **shooting day** (natáčací deň), réžia, DoP, **obraz**, **záber**, **pokus**,
  INT/EXT, DAY/NIGHT/DUSK, MOS, poznámka a „dobrý pokus“ (★). Pokus sa po každom zábere sám zvýši
  o 1, zmena obrazu alebo záberu ho nastaví na 1. Počas nahrávania sú obraz/záber/pokus zamknuté,
  poznámku a ★ možno meniť. Údaje sa uložia do `C001_SLATE.JSON` a zapíšu sa aj ako
  QuickTime metadáta do oboch `.mov` (názov, popis, komentár, réžia, kamera A/B, dátum) –
  vidno ich napr. vo Finderi (Informácie) alebo v DaVinci Resolve.
  Posledná klapka sa pamätá aj po reštarte aplikácie.
- **REHEARSAL** (vedľa REC, **⇧⌘R**) – skúška: oba obrazy nahrá len appka (kamery nenahrávajú), take sa
  označí ako Rehearsal (oranžový rámček a „● REHEARSAL“, v Playbacku štítok REHEARSAL / REH, v CSV stĺpec
  `rehearsal`, v PDF a metadátach). Nezvýši číslo take ani Cam clip; „Record with the camera“ sa počas skúšky
  ignoruje a varovanie „Camera is NOT recording“ sa neukazuje. Ukončí sa tlačidlom STOP.
- **IN / OUT počas nahrávania** – tlačidlá IN / OUT (**⌘I** / **⌘O**) pri REC označia
  aktuálny čas záberu. **Viac úsekov:** IN začne úsek, OUT ho uzavrie, ďalšie IN začne ďalší (IN pri otvorenom
  úseku len posunie jeho začiatok); × zmaže posledný úsek. Značky sa po STOP uložia do `C001_MARKS.JSON`
  vedľa videí (`ranges`, čas v sekundách od začiatku záberu, platí pre CamA aj CamB; prvý úsek aj ako starý
  `inPoint` / `outPoint`) a použije ich prehrávanie, strih aj PDF.

### Záložka PREHRÁVANIE
- Pri zábere v zozname je aj „Obraz · Záber · Pokus“ a ★ pri dobrom pokuse; pod prehrávačmi
  je súhrn klapky a tlačidlo **Edit slate…** na dodatočnú úpravu (uloží sa do `C###_SLATE.JSON`).
- Zoznam klipov je **zoradený podľa shooting day** (najnovší deň hore, prirodzené poradie
  „9 < 10“, „D02 < D03“), každý deň má vlastný nadpis; v rámci dňa najnovší klip hore.
  Klipy bez shooting day sú na konci.
- **Hľadanie** v zozname klipov: číslo klipu, súbor, scéna, záber, pokus (`T04`), shooting day,
  Cam clip, poznámka, INT/EXT, DAY/NIGHT a slová `good` / `mos`; viac slov = všetky musia sedieť
  (napr. `12 3B good`). Počas písania sú jednoklávesové skratky (medzerník, I, O, šípky) vypnuté.
- **Prev / Next** (↑ / ↓, aj ⌘← / ⌘→) prepne na predchádzajúci / nasledujúci klip (podľa čísla klipu),
  funguje aj v Screens only.
- **Zoznam klipov je predvolene skrytý** – otvorí/skryje ho tlačidlo **Clips** (⌘L), takže
  prehrávače majú celú šírku okna. Pri prepnutí na Playback sa **automaticky načíta posledný
  nahraný klip** (označený LATEST); iný klip vyberieš v zozname a zoznam potom skryješ.
- Zoznam záberov v priečinku (sleduje zmeny v priečinku; práve nahrávaný záber je skrytý),
  pri každom zábere **náhľadový obrázok zo stredu záznamu** (z CamA, ak chýba tak z CamB).
- Po výbere sa načíta CamA a CamB vedľa seba v dvoch `AVPlayer`-och.
- Spoločné **play/pause** (medzerník), **posuvník**, **krokovanie po snímkach** (← / →),
  **rýchlosť 0,5× / 1× / 2×**, výber zvuku A/B, zobrazenie rozdielu pozícií B−A.
- **IN / OUT:** záber sa po načítaní nastaví na IN. **Loop** (vpravo pod Speed): **NO** prehrá klip raz do konca,
  **IN/OUT** prehráva len označené úseky za sebou a dokola (medzery preskočí; bez OUT až do konca klipu),
  lišta pod posuvníkom ukazuje všetky úseky,
  **CLIP** (predvolene) prehráva dokola celý klip a IN/OUT ignoruje. IN/OUT sa dá v prehrávaní upraviť
  (I / O na aktuálnej snímke), skočiť na IN/OUT alebo zrušiť – zmeny sa hneď uložia do
  `C###_MARKS.JSON`. Zábery so značkami majú v zozname žltú vlajku.
- Synchronizácia cez `setRate(_:time:atHostTime:)` so spoločným časom hostiteľských hodín;
  seek a krokovanie sú presné na snímku (nulová tolerancia) na oboch prehrávačoch.

### Živý náhľad na telefónoch (Settings → Live view on phones)
- **Settings (⌘,) → Live view on phones** – zapni prepínač. Zobrazia sa **dva QR kódy**
  s adresami (napr. `http://dualcam.local:8090/?k=ab12cd34`) a počet pripojených telefónov.
- Adresa **`dualcam.local`** (Bonjour/mDNS) sa nemení, keď router pridelí Macu inú IP – QR kód
  vytlačený raz platí stále (kým nezmeníš prístupový kód). Treba povoliť **Lokálnu sieť** pre DualCamRecorder
  (macOS sa spýta raz; inak Systémové nastavenia › Súkromie a bezpečnosť › Lokálna sieť, potom náhľad vypni a zapni).
  Bez povolenia, alebo keď meno už používa iný Mac v sieti, sa použije meno Macu (`Mac-mini.local`).
  Pod adresou je aj IP adresa; prepínač **QR code: Name / IP address** – niektoré Android telefóny `.local` neotvoria.
- Telefóny v **rovnakej Wi-Fi** (iPhone aj Android, aj viac naraz) naskenujú QR kód a v prehliadači
  vidia obe kamery naživo, ● REC s časom, súbory a klapku; na výšku pod sebou, na šírku vedľa seba.
  Netreba žiadnu aplikáciu.
- Obraz sa posiela ako **MJPEG stream** (Mac posiela každý nový obrázok po jednom otvorenom spojení).
  **Picture quality**: **Low** 640×360 ~6 obr./s · **Standard** 960×540 ~12 obr./s ·
  **High** 1280×720 ~12–15 obr./s (pri 25p zdroji 12,5; treba dobrú Wi-Fi, ~5–15 Mbit/s na kameru podľa obrazu).
  Pomalý telefón obrázky preskakuje, oneskorenie sa nenahromadí.
- **Dva kódy (dva QR kódy):**
  - **Crew – watch only** – pre celý štáb: obe kamery, REC a klapka, nič sa nedá zmeniť.
  - **Slate – can change the slate** – pre skript / 2. asistenta: na celoobrazovkovej klapke sa ťukom mení
    scéna, záber, pokus a čísla kariet (ako doteraz).
  - Každý kód je náhodný – bez neho server odpovie 403; s kódom štábu server zmenu klapky odmietne.
    **New code** pri každom zneplatní len jeho staré odkazy.
  - **Watermark** (pri kóde štábu): text cez celý obraz – šikmo, opakovane, polopriehľadne (napr. názov
    produkcie; prázdne = *CONFIDENTIAL*). Je vpálený priamo do obrázkov, ktoré dostanú telefóny štábu, takže je
    na každom screenshote aj nahrávke obrazovky a orezaním sa nedá odstrániť. Telefóny s kódom klapky dostávajú
    čistý obraz. Obraz s watermarkom sa robí na samostatnej fronte a len vtedy, keď sa pozerá telefón štábu.
  - **Print…** pri každom QR kóde – A4 list (tlač alebo „Uložiť ako PDF“ v dialógu tlače): veľký QR kód, názov
    projektu, Wi-Fi a tri kroky. Tlačí sa QR kód podľa prepínača **Name / IP address** (na celé natáčanie je lepší
    *Name* – `dualcam.local` sa nemení). Na liste kódu klapky je upozornenie, že nie je pre celý štáb.
  - **Wi-Fi on the printed sheet** – názov a (voliteľne) heslo siete, len pre vytlačený list (uložené v Macu).
- JPEG sa robí len vtedy, keď sa nejaký telefón pozerá, na samostatnej fronte (nespomalí náhľad
  na Macu) → nahrávanie to nezaťaží. Pri prvom spustení macOS môže žiadať povolenie prichádzajúcich spojení / lokálnej siete.
- Telefóny vidia vstupy kamier (aj keď je na Macu otvorený Playback), nie prehrávané klipy.

### Strih pre režiséra (záložka Edit, E)
- V Playbacku sa označí IN / OUT a tlačidlom **+ Camera A** / **+ Camera B** (⇧A / ⇧B) sa každý úsek
  pridá na koniec timeline ako samostatný kúsok – vždy len jedna kamera. Bez IN / OUT sa pridá celý klip (len IN → do konca,
  len OUT → od začiatku). Po pridaní sa na chvíľu ukáže „Added to timeline: …“.
- V záložke **Edit** je vľavo **zoznam klipov** (Clips, ⌘L) s vyhľadávaním, kde má každá kamera klipu
  vlastný riadok (Clip 014 · Camera A, Clip 014 · Camera D). **+**, dvojklik alebo ↵ pridá riadok na koniec
  timeline – s IN / OUT v tej dĺžke, inak celý klip.
- **Zmazanie klipu** v Playback: pravý klik na klip v zozname klipov → Move to Trash. Oba súbory
  kamier, slate a IN / OUT idú do Koša (dajú sa vrátiť), CLIPLOG.CSV sa prepíše; ak je klip v strihu,
  potvrdenie napíše v ktorých sekvenciách (tie úseky budú chýbať).
- **Edit** prehrá celú timeline ako jeden film (medzerník, ← / → po snímke, ↑ / ↓ predchádzajúci /
  nasledujúci úsek, klik do timeline = skok). Nad tlačidlami je popis úseku pod playheadom.
- **Playhead myšou:** klik alebo ťahanie po pravítku nad úsekmi (aj po prázdnej časti timeline) ho dá
  pod myš, červený úchyt / čiaru sa dá chytiť a ťahať aj ponad úseky; obraz sa ukazuje počas ťahania.
- Na timeline: klik vyberie úsek, **ťahanie úseku** zmení poradie (aj ⌥← / ⌥→), **ťahanie okraja**
  posunie IN / OUT (nie za koniec klipu), pri vybranom úseku sa dá prepnúť **Camera A / B**,
  **Remove** (⌫) ho vyhodí, **Undo** (⌘Z) vráti poslednú zmenu. Zoom posuvníkom.
- **Sekvencie** (vpravo, Sequences, ⌘K): projekt má viac strihov – postriháš jednu pasáž, dáš **New** (⌥⌘N)
  a strihaš ďalšiu. Klik na sekvenciu ju ukáže na timeline, dvojklik premenuje, kontextové menu ju
  zduplikuje alebo zmaže (posledná sa len vyprázdni). Undo platí v rámci sekvencie (pri prepnutí sa začína znova).
  Export MOV ponúkne názov `<projekt>_<sekvencia>.mov`.
- Timeline sa ukladá do `EDIT.JSON` v priečinku projektu (verzia 2: všetky sekvencie + vybraná; starý súbor
  s jednou timeline sa načíta ako „Sequence 1“); nahrávky sa nikdy nemenia ani nekopírujú.
- **Export MOV…**: H.264 1080p film celej timeline so zvukom vybranej kamery, voliteľne s popisom
  úseku v ľavom dolnom rohu (Clip · Scene · Shot · Take · Camera). Predvolene `<projekt>_EDIT.mov`
  v priečinku projektu.

### Overlay – compositing (záložka Overlay, O)
- Jeden obraz: **snímka nahratého klipu** (zastavená) a cez ňu **živá kamera** – na zarovnanie herca / kamery
  podľa skoršieho záberu.
- Vľavo zoznam klipov (každá kamera klipu zvlášť, s hľadaním); klip začne na svojej značke IN.
  Snímka: posuvník, **← / →** po jednej snímke, tlačidlá IN / OUT.
- **Live**: ktorá živá kamera ide navrch. Režimy:
  - **Mix** – priehľadnosť živej kamery (0 % len klip, 100 % len živý obraz), **↑ / ↓** po 10 %, tlačidlá 0–100;
  - **Difference** – kde sa obraz zhoduje, je čierny; svieti len to, čo sa pohlo;
  - **Wipe** – klip vľavo, živý obraz vpravo, žltú čiaru ťaháš myšou po obraze.
- Snímka z klipu sa dekóduje a prevádza rovnako ako živý obraz (VideoToolbox → BGRA, bez prepočtu farieb),
  takže Difference je naozaj čierny. Skladanie na GPU (Core Image), nahrávanie nespomaľuje; v Recorde sa dá
  nahrávať ďalej. Flip / Flop živej kamery platí aj tu.
- **Blackmagic monitor** na záložke Overlay ukazuje overlay (celý obraz).
- **Demo pictures** (hore v zozname) – vyskúšanie bez kamier: široký záber ako klip, detail postavy ako živý obraz
  (obrázky DemoWide / DemoClose v Assets.xcassets).

### Export PDF (⇧⌘P)
- V lište okna tlačidlo **Export PDF…**: report klipov **podľa natáčacích dní** (všetky dni alebo
  jeden deň, voliteľne len ★ dobré pokusy, s obrázkami alebo bez).
- **A4 na šírku (6 klipov / strana) alebo na výšku (8 klipov / strana)**, každý deň začína novou stranou (projekt, deň, dátum, počet klipov); na strane
  6 klipov. Riadok: obrázok zo stredu klipu z kamery A aj B, číslo klipu, ★ / MOS,
  Scene / Shot / Take, INT/EXT · DAY/NIGHT, súbory + Cam clip, dĺžka, IN / OUT / DUR,
  čas nahrávania, poznámka, nastavenia kamier (ak sú vyplnené). Ukážky: `docs/preview/sample_clip_report.pdf` (na šírku), `docs/preview/sample_clip_report_portrait.pdf` (na výšku).
- PDF sa uloží (predvolene do priečinka projektu) a hneď otvorí.

### Waveform (⇧⌘W)
- Tlačidlo **Waveform** v lište okna zapne **luma waveform (0–100 IRE)** zvlášť pre každú kameru –
  malý panel v pravom dolnom rohu obrazu (Record aj Playback, aj v Screens only).
- Record: počíta sa zo zmenšeného náhľadu (~12× za sekundu), nezaťažuje nahrávanie.
  Playback: z aktuálne zobrazenej snímky oboch prehrávačov (aj pri pauze / krokovaní).
- Super-whites nad 100 IRE a pod 0 IRE sa orežú na okraj stupnice.

### Režim „Screens only“ (⌘F)
- Tlačidlo **Screens only** v lište okna (alebo **⌘F**) skryje v Record aj Playback všetko okrem
  dvoch obrazoviek; **Show controls** / ⌘F ich vráti. Pre úplne čistú plochu použi aj celú
  obrazovku macOS (⌃⌘F).
- Skratky fungujú ďalej: Record – ⌘R (REC/STOP), ⌘I / ⌘O (IN/OUT); Playback – medzerník,
  ← / →, I / O; prepnutie záložiek ⌘1 / ⌘2. Červený rámik a odznaky REC / No signal ostávajú.

### Nastavenia (⌘,)
- Umiestnenie nových projektov a informácie o SDK / ovládači / zariadeniach.
- Playback vždy číta z priečinka otvoreného projektu.

### Simulovaný vstup
V zozname zariadení je vždy položka **„Simulovaný vstup (testovací obraz)“** – farebné pruhy,
časový kód, bežiaci pruh, **biely blesk + 1 kHz pípnutie každú sekundu**. Obe simulované kamery
zdieľajú hodiny, kamera B má posun fázy 0,4 snímky (ako dve negenlocknuté kamery). Takto sa dá
celé UI aj synchronizácia (štart, prehrávanie, krokovanie) overiť bez hardvéru – blesky v A a B
musia v prehrávaní padnúť na rovnakú snímku.

---

## Ako funguje synchronizácia A/B

1. Každá snímka z DeckLinku má `GetHardwareReferenceTimestamp` (hodiny zariadenia) a
   `GetStreamTime` (časová os streamu, rovnaká ako `GetPacketTime` audia).
2. Most (`DLCapture.mm`) pri každej snímke vzorkuje `GetHardwareReferenceClock` spolu s
   hostiteľskými hodinami (`CLOCK_UPTIME_RAW`), vyhladzuje offset a prepočíta čas snímky na
   **spoločný hostiteľský čas** – ten je porovnateľný medzi oboma zariadeniami.
3. REC určí spoločný okamih `T0 = teraz + 200 ms`. Každý kanál zahodí snímky s
   `hostTime < T0 − ½ snímky`. Prvé snímky A a B sú teda od seba **max. ½ snímky**.
4. STOP určí spoločné `T1`; zapíšu sa snímky s `hostTime < T1 − ½ snímky` → rovnaká dĺžka.
5. PTS v súbore = `streamTime − streamTime(prvej snímky)`; audio používa tú istú os a je
   orezané po vzorkách. Výpadok snímky zostane v súbore ako medzera, takže sa súbory nerozídu.

---

## Požiadavky

- macOS 14 Sonoma alebo novší, Apple Silicon (projekt je nastavený na `arm64`).
- Xcode 15 alebo novší (testované nastavenia: Swift 5 režim).
- **Blackmagic Desktop Video** (ovládač) – nainštalovaný `/Library/Frameworks/DeckLinkAPI.framework`.
- **Blackmagic DeckLink SDK** 12.x – 15.x rozbalené do `./DeckLinkSDK` tak, aby existoval
  `DeckLinkSDK/Mac/include/DeckLinkAPI.h` (viď [`DeckLinkSDK/README.md`](DeckLinkSDK/README.md)).

## Zostavenie

```bash
# 1) SDK: obsah "Blackmagic DeckLink SDK xx.y/" skopírovať do ./DeckLinkSDK
ls DeckLinkSDK/Mac/include/DeckLinkAPI.h

# 2) Build (Release)
xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder \
           -configuration Release -derivedDataPath build build

# ak by podpisovanie robilo problémy:
xcodebuild -project DualCamRecorder.xcodeproj -scheme DualCamRecorder \
           -configuration Release -derivedDataPath build build CODE_SIGNING_ALLOWED=NO
```

Ak SDK chýba, build prejde s varovaním
`DeckLink SDK headers not found … building with simulated input only` a aplikácia ponúkne len
simulovaný vstup.

Po pridaní/odobratí zdrojových súborov sa dá projekt pregenerovať:
`python3 tools/gen_xcodeproj.py`.

## Spustenie

```bash
open build/Build/Products/Release/DualCamRecorder.app
```

1. V *Nastaveniach* (⌘,) vyber umiestnenie projektov (ideálne rýchly externý SSD) a na úvodnej
   stránke vytvor projekt.
2. Na záložke **Nahrávanie** priraď zariadenia ku Kamera A / B, skontroluj formát a audio meter.
3. **REC** (⌘R) → **STOP**. Pod časovačom sa zobrazí uložený záber a posun štartu B−A.
4. Záložka **Prehrávanie** → vyber záber → medzerník / ← → / 0,5×–1×.

Na test bez kamier vyber pri oboch kamerách „Simulovaný vstup“.

---

## Štruktúra projektu

```
DualCamRecorder.xcodeproj         Xcode projekt (generovaný tools/gen_xcodeproj.py)
DeckLinkSDK/                      sem patrí Blackmagic SDK (nie je v gite)
DualCamRecorder/
  App/        DualCamRecorderApp.swift (TabView, Settings), AppSettings.swift
  Bridge/     DLCapture.h / DLCapture.mm (Obj-C++ nad DeckLink SDK), bridging header
  Capture/    VideoSource protokol, DeckLinkSource, SimulatedSource, HostClock
  Recording/  CameraChannel (sync štart/stop, štatistiky), MovieWriter (ProRes+LPCM),
              RecordingController (zariadenia, REC/STOP, IN/OUT, disk), TakeNaming,
              TakeMarks (IN/OUT, C###_MARKS.JSON), SlateInfo (klapka, C###_SLATE.JSON)
  Preview/    PreviewRenderer (VTPixelTransfer → AVSampleBufferDisplayLayer), PreviewView
  Playback/   TakeLibrary, ThumbnailCache (náhľady zo stredu záberu),
              SyncPlaybackController (2× AVPlayer), PlayerView
  Edit/       EditTimeline (EDIT.JSON, undo), EditComposition (AVMutableComposition,
              prehrávač, export H.264), EditView (timeline), EditClipList (klipy po kamerách)
  Views/      RecordView, PlaybackView, SettingsView, Components
docs/PLAN.md                      plán a architektúra
tools/gen_xcodeproj.py            generátor project.pbxproj + zdieľanej schémy
```

### Prečo sa pri nahrávaní nevynechávajú snímky
- DeckLink callback iba skopíruje snímku do `CVPixelBufferPool` (IOSurface) a vráti sa.
- Zápis beží na samostatnej sériovej fronte s QoS *userInteractive* pre každú kameru;
  ProRes kódovanie ide na hardvérový ProRes engine M4 Pro.
- Náhľad má vlastnú frontu a pri zaneprázdnení snímky preskakuje (nikdy neblokuje zápis);
  keď je otvorená záložka Prehrávanie, náhľad sa nevykresľuje vôbec.
- Aplikácia drží `ProcessInfo` aktivitu *latencyCritical* (bez App Nap / spánku).
- Ak by fronta zápisu narástla nad 10 snímok, snímka sa zahodí a započíta do
  „Vynechané (zápis)“ – nič sa tak nedeje potichu.

---

## Známe obmedzenia

- **Stav overenia:** projekt bol napísaný a skontrolovaný mimo macOS. Objective-C++ most bol
  preložený (`clang -fsyntax-only -Wall -Wextra`, bez varovaní) proti macOS 14.5 SDK a reálnym
  hlavičkám DeckLink SDK 12.0, aj v režime bez SDK. Swift kód prešiel len syntaktickou kontrolou –
  **`xcodebuild` ani test na hardvéri zatiaľ neprebehol**, prvé zostavenie na Macu môže
  vyžadovať drobné opravy.
- **Kamery nie sú genlocknuté:** zarovnanie je na ±½ snímky (fyzický limit bez genlocku).
  Pre úplne presnú synchronizáciu treba obom kamerám spoločný sync/genlock alebo dosynchronizovať
  podľa timecodu v postprodukcii.
- Offset hodín zariadenia voči hostiteľovi sa odhaduje softvérovo (vzorkovanie
  `GetHardwareReferenceClock`); presnosť je typicky pod 1 ms.
- **Zmena formátu počas nahrávania** (napr. prepnutie snímkovej frekvencie na kamere) nie je
  podporovaná – záber treba zastaviť a spustiť znova.
- Pri strate signálu DeckLink dodáva čierne snímky; zapisujú sa (časová os ostane zarovnaná)
  a počítajú sa ako „bez signálu“.
- Audio: SDI vždy nesie audio kanály. Ak kamera nič neembeduje, zapíše sa ticho – či audio
  naozaj prichádza, ukazuje audio meter. Počet kanálov (2/8/16) sa mení v Nastaveniach
  a aplikuje tlačidlom „reštart vstupov“.
- 10-bit 4:2:2 (v210) je predvolený, ak ho zdroj posiela; pri problémoch zapni
  „Vynútiť 8-bit“. RGB 4:4:4 vstup sa zachytáva ako 8-bit BGRA.
- Prekladané formáty (1080i) sa označia field atribútmi, ale neboli overené na hardvéri.
- Aplikácia nie je sandboxovaná a nemá hardened runtime (kvôli načítaniu `DeckLinkAPI.framework`
  z `/Library/Frameworks`); je podpísaná ad-hoc („Sign to Run Locally“).
- Odhad zostávajúceho času vychádza z nominálnych dátových tokov ProRes (Apple white paper).
- Metadáta v `.mov` sa zapíšu pri štarte záberu; poznámka a ★ zmenené počas nahrávania alebo
  neskôr v prehrávaní sa uložia len do `C###_SLATE.JSON` (súbor videa sa už neprepisuje).
- IN/OUT počas nahrávania sa berie podľa času stlačenia (hostiteľské hodiny) – presnosť je
  ±1 snímka plus reakčný čas obsluhy; jemne sa dajú doladiť v prehrávaní po snímkach.
- Synchronizácia dvoch `AVPlayer`-ov je na úrovni zobrazovacieho snímku; pri pauze sa oba
  prehrávače dorovnajú presne na rovnakú snímku.
