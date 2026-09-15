# Mangaworld Downloader

App macOS nativa, in SwiftUI, per cercare manga su [Mangaworld](https://www.mangaworld.mx) e scaricare
ogni volume completo in un file `.cbz`, pronto per qualsiasi lettore di fumetti.

---

## Cosa fa

- **Copertine in prima pagina**: senza scrivere niente mostra le liste della home del sito — capitoli di
  tendenza, ultimi capitoli aggiunti, manga del mese, ultime aggiunte
- **Ricerca per titolo e con i filtri del sito**: generi, tipo, stato, autore, artista, anno e ordinamento.
  I filtri bastano da soli: con il solo genere Horror compaiono tutti i manga horror
- **Scheda di ogni manga**: copertina, trama, anno, generi e l'elenco dei volumi con i loro capitoli
- **Un volume o tutti**: ogni volume diventa un `.cbz` con tutti i suoi capitoli, in ordine di lettura; i
  volumi già scaricati sono segnati
- **Tavole doppie senza doppioni**: se il sito ha una tavola doppia e anche le sue due metà già divise, la
  tavola doppia resta fuori; se c'è solo quella, resta
- **Coda dei download**: avanzamento pagina per pagina, interrompi, riprova, mostra nel Finder; la lista
  resta anche dopo la chiusura dell'app
- **Mai un volume a metà**: se una pagina non arriva, il volume fallisce e si può riprovare, invece di
  salvare un `.cbz` con dei buchi

---

## Requisiti

- **macOS 15** o successivo
- Per compilarla, **Xcode** o gli strumenti a riga di comando di Swift

Nessuna dipendenza esterna: le immagini passano per ImageIO e i `.cbz` li scrive lo `zip` di sistema.

---

## Installazione

```bash
./scripts/build-release.sh
```

Lo script esegue i test, compila, mette `Mangaworld Downloader.app` in `~/Downloads` e la apre. Se l'app è
già aperta la chiude, quindi eventuali download in corso si interrompono.

L'app è firmata ad hoc e non notarizzata: sul Mac che l'ha compilata si apre normalmente, altrove macOS ne
blocca il primo avvio. Per sbloccarla: **Impostazioni di Sistema → Privacy e sicurezza → Apri comunque**.

### Da sorgente

```bash
swift run                # l'app
swift test               # i test, senza toccare il sito
LIVE=1 swift test        # anche quelli sul sito vero, compreso un download completo
```

Xcode apre `Package.swift` come progetto.

---

## Dove finiscono i file

Nella cartella scelta nelle impostazioni, `~/Documents/Mangaworld` se non la cambi:

```
<cartella>/
├── Berserk/
│   ├── Volume 01.cbz
│   └── Volume 02.cbz
└── Your Ryan/
    └── Your Ryan.cbz
```

Un manga che il sito tiene senza volumi diventa un solo file, con il suo nome. Dentro ogni `.cbz` le pagine
sono numerate `0001`, `0002`… in ordine di lettura, senza compressione: sono già immagini compresse.

---

## Impostazioni

- **Dominio**: vuoto usa `www.mangaworld.mx`. Il sito cambia indirizzo ogni tanto; quello nuovo si incolla
  qui, anche copiato dal browser
- **Cartella** dove salvare i volumi
- **Volumi contemporanei**: quanti scaricarne insieme, 2 all'inizio

---

## Come riconosce le tavole doppie

Una pagina larga circa il doppio delle altre dello stesso volume è una tavola doppia. Le sue due metà vengono
confrontate con le due pagine subito prima e subito dopo, rimpicciolite in grigio: se entrambe si somigliano
abbastanza, in un ordine o nell'altro, la tavola doppia è un doppione e resta fuori dal `.cbz`.

La tavola doppia si scarica comunque, perché le metà si riconoscono solo dai pixel. Il confronto per
correlazione regge i disegni a matita e i ritagli leggermente diversi, dove un'impronta più grezza sbagliava.

---

## Com'è fatta

- `Sources/Source.swift` — le richieste al sito e la lettura delle sue pagine: ricerca, filtri, home, scheda
  del manga, pagine dei capitoli
- `Sources/Downloads.swift` — il download di un volume, la creazione del `.cbz`, le tavole doppie, la coda
- `Sources/Views.swift` — la finestra: ricerca, filtri, scheda del manga, download, impostazioni
- `Sources/App.swift` — le scene e l'avvio
- `icon/AppIcon.icon` — l'icona, un documento di Icon Composer che lo script compila con `actool`
- `Tests/Tests.swift` — i test

---

## Nota

L'app scarica quello che il sito pubblica; i manga appartengono ai rispettivi autori ed editori. Usala per
uso personale e nel rispetto delle leggi del tuo paese.

---

## Licenza

MIT. Vedi [LICENSE](LICENSE).
