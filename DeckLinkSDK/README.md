# DeckLink SDK

Sem patrí Blackmagic **Desktop Video / DeckLink SDK** (stiahni z
https://www.blackmagicdesign.com/developer/ → „Desktop Video SDK“).

Po rozbalení skopíruj obsah tak, aby existoval tento súbor:

```
DeckLinkSDK/Mac/include/DeckLinkAPI.h
DeckLinkSDK/Mac/include/DeckLinkAPIDispatch.cpp
```

(t. j. obsah priečinka `Blackmagic DeckLink SDK xx.y/` priamo sem). Xcode projekt hľadá hlavičky v
`DeckLinkSDK/Mac/include`, `DeckLinkSDK/include` a `DeckLinkSDK`.

Podporované verzie SDK: 12.x – 15.x (pri ≥ 14.3 sa použijú legacy rozhrania `*_v14_2_1`).

Bez SDK sa aplikácia zostaví tiež, ale bude dostupný len **simulovaný vstup**.
Obsah tohto priečinka (okrem tohto README) je v `.gitignore` – SDK má vlastnú licenciu.
