# DualCamRecorder – plán a štruktúra projektu

## Cieľ
Natívna macOS 14+ (Apple Silicon) aplikácia na súčasné nahrávanie dvoch SDI kamier cez
dve Blackmagic UltraStudio Recorder 3G do ProRes 422 `.mov` a synchronizované prehrávanie
dvojice záberov – oboje naraz bez vynechávania snímok.

## Architektúra (vrstvy)

```
┌──────────────────────── SwiftUI ────────────────────────┐
│ RecordView        PlaybackView        SettingsView      │
└────────┬───────────────────┬────────────────────────────┘
         │                   │
 RecordingController   SyncPlaybackController (2× AVPlayer,
   ├─ CameraChannel A        setRate(_:time:atHostTime:))
   │    ├─ VideoSource ──► CapturedFrame (CVPixelBuffer + časy + audio)
   │    ├─ PreviewRenderer (VTPixelTransfer → AVSampleBufferDisplayLayer)
   │    └─ MovieWriter (AVAssetWriter ProRes 422 + LPCM)
   └─ CameraChannel B (to isté)
         │
 VideoSource = DeckLinkSource | SimulatedSource
         │
 DeckLinkSource ──► DLCapture.h/.mm (Objective-C++ most)
                         └─► DeckLink SDK (IDeckLinkDiscovery, IDeckLinkInput, ...)
```

### Synchronizácia štartu A/B
1. Každý `IDeckLinkVideoInputFrame` nesie `GetHardwareReferenceTimestamp` (hodiny zariadenia)
   a `GetStreamTime` (časová os streamu, rovnaká ako `GetPacketTime` audia).
2. Most priebežne meria offset hodín zariadenia voči hostiteľským hodinám
   (`GetHardwareReferenceClock` ↔ `CLOCK_UPTIME_RAW`, vyhladené) a prepočíta čas snímky
   na **hostiteľský čas** – ten je spoločný pre obe zariadenia.
3. REC zvolí spoločný okamih `T0 = teraz + 200 ms`. Každý kanál zahodí snímky s
   `hostTime < T0 − ½ snímky`; prvá zapísaná snímka oboch kamier je teda od `T0`
   vzdialená max. ½ snímky (kamery nie sú genlocknuté, presnejšie to fyzicky nejde).
4. STOP rovnako: spoločné `T1`, zapíšu sa len snímky s `hostTime < T1 − ½ snímky`.
5. PTS v súbore = `streamTime − streamTime(prvej zapísanej snímky)`, audio rovnako
   (audio pred začiatkom sa orezáva po vzorkách). Medzery pri výpadku zostanú medzerami
   (synchronizácia sa nerozíde).

### Vlákna (aby nahrávanie a prehrávanie nekolidovali)
- DeckLink callback vlákno: iba kópia rámca do `CVPixelBufferPool` (IOSurface) + čas.
- Sériová fronta na kanál (QoS userInteractive): rozhodnutie o zápise + `append`.
- Náhľad: samostatná fronta, preskakuje snímky, ak je zaneprázdnená (nikdy neblokuje zápis).
- Prehrávanie: AVPlayer (vlastné vlákna), ProRes dekódovanie na HW ProRes engine M4 Pro.

## Štruktúra súborov

```
DualCamRecorder.xcodeproj/          Xcode projekt (generovaný tools/gen_xcodeproj.py)
DeckLinkSDK/                        sem rozbaľ Blackmagic DeckLink SDK (Mac/include/…)
DualCamRecorder/
  App/
    DualCamRecorderApp.swift        @main, TabView (Nahrávanie / Prehrávanie), Settings
    AppSettings.swift               UserDefaults: priečinky zápis/čítanie, audio, 8/10 bit…
  Bridge/
    DualCamRecorder-Bridging-Header.h
    DLCapture.h                     Obj-C rozhranie mosta (bez C++ typov)
    DLCapture.mm                    Obj-C++ implementácia nad DeckLink SDK
  Capture/
    HostClock.swift                 hostiteľské hodiny (ns) ↔ CMTime
    VideoSource.swift               protokol zdroja + CapturedFrame + VideoFormatInfo
    DeckLinkSource.swift            VideoSource nad DLCaptureDevice
    SimulatedSource.swift           testovací obraz + tón (bez kamier)
  Recording/
    MovieWriter.swift               AVAssetWriter ProRes 422 + LPCM audio
    CameraChannel.swift             zdroj → náhľad + zápis, štatistiky, synchronizácia
    RecordingController.swift       zariadenia, priradenie A/B, REC/STOP, disk
    TakeNaming.swift                C###_S<obraz>_SH<záber>_T<pokus>_CAMA/B.MOV, auto-číslovanie
  Preview/
    PreviewRenderer.swift           zmenšenie a zobrazenie náhľadu
    PreviewView.swift               NSViewRepresentable s AVSampleBufferDisplayLayer
  Playback/
    TakeLibrary.swift               zoznam záberov v priečinku
    SyncPlaybackController.swift    2× AVPlayer synchronizovane
    PlayerView.swift                AVPlayerLayer view
  Views/
    RecordView.swift
    PlaybackView.swift
    SettingsView.swift
    Components.swift                meter, status odznaky
tools/gen_xcodeproj.py              generátor project.pbxproj
README.md
```

## Kroky implementácie
1. Most DeckLink (Obj-C++): discovery, vstup s auto-detekciou formátu, SDI vstup, audio,
   kópia rámca, prepočet HW času → host čas, počítanie výpadkov.
2. Swift zdroje: DeckLinkSource, SimulatedSource.
3. MovieWriter + CameraChannel (synchronizovaný štart/stop, orezanie audia).
4. RecordingController + RecordView (priradenie, náhľady, REC/STOP, dropped, disk).
5. TakeLibrary + SyncPlaybackController + PlaybackView.
6. Nastavenia, README, Xcode projekt.
