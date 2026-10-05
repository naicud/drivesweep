# DriveSweep 3.1

Pulizia dei metadati macOS sui **dischi esterni fisici scrivibili**, con app nativa e CLI che condividono motore, preferenze e consensi per VolumeUUID. Gratis, Apache-2.0, senza account, abbonamenti, telemetria o servizi esterni.

Sorgente: **3.1.0, build 21**. Il Cask conserva la release pubblicata **0.4.11**: la nuova build locale non è una release GitHub già pubblicata. Homebrew non fornisce ancora la 3.1.

## App e CLI

| Funzione | App | CLI |
|---|---|---|
| Dischi, capacità e formato | Schede del dashboard | `list` |
| Analisi singola / tutti i dischi | Analizza / Analizza tutti | `analyze VOLUME` / `analyze --all` |
| Conteggi, categorie, protetti, byte logici | Dettagli e snapshot | Report e `--json` |
| Esportazione locale JSON | Esporta | `analyze --export FILE` |
| Pulizia e pulizia con espulsione | Conferma delle categorie | `clean VOLUME [--eject]` |
| Profili e categorie avanzate | Preferenze | `profiles`, `config` |
| Esclusioni e consensi per UUID | Controlli della scheda | `rules` |
| Conferma estensioni personalizzate | Analisi e conferma | `rules confirm-custom` |
| Avvio, stop e intervallo periodico | Pianificazione | `schedule` |
| Pulizia automatica al mount | App aperta | `daemon` in primo piano |
| CPU, RAM, I/O, PID e thread | Tachimetri e Processi live | `resources --watch` |
| Annullamento | Annulla | Ctrl-C / SIGTERM |

Cronologia e snapshot del dashboard appartengono alla sessione dell'app. La CLI esporta i propri report. Le preferenze si sincronizzano tra frontend; un solo runner gestisce l'automazione e un lock tra processi impedisce pulizie concorrenti.

## Partenza rapida

macOS 13+, Apple Silicon/Intel. Command Line Tools per compilare; Python 3 soltanto per i test di integrazione.

```sh
make test
make dmg
```

Installa `build/DriveSweep.app` in Applications e il launcher seguendo [Installazione](docs/INSTALLATION.md). Poi:

```sh
drivesweep --help
drivesweep list
drivesweep analyze /Volumes/USB --export ./report-usb.json
drivesweep resources --watch
drivesweep clean /Volumes/USB
```

`VOLUME` è la radice esatta del mount. La CLI richiede di scrivere `PULISCI` in un terminale interattivo; `--yes` è la conferma esplicita per script, senza saltare controlli o esclusioni. La pulizia è **definitiva**: analizza e controlla le categorie prima di procedere. AppleDouble può contenere metadati utili; cestino ed estensioni personalizzate possono selezionare dati personali.

## Dashboard e risorse live

Dashboard con capacità, formato, stato, candidati, protetti, durata dell'analisi e attività recente. Tachimetri CPU/RAM aggiornati ogni secondo fuori dal lavoro filesystem. Processi live mostra motore, altre istanze DriveSweep dello stesso utente e figli, inclusi scanner e strumenti di sistema.

CPU: **100% = un core**, arco su tutti i core logici. RAM: physical footprint in MiB, scala visiva 750 MiB. Disponibili RSS, picco della sessione, I/O al secondo e thread. I totali possono includere memoria condivisa più volte. Primo campione CPU/I/O non disponibile; processi molto brevi possono sfuggire. Massimo 60 campioni e 128 PID, con dati parziali segnalati. Misure via `libproc`, senza lanciare strumenti di monitoraggio.

La protezione della **pulizia periodica** controlla runner e propri figli ogni 2 s: oltre 80% CPU di un core oppure 750 MiB RSS per due campioni consecutivi, annulla cooperativamente e disattiva la pianificazione. Il monitor generale resta attivo anche senza pulizia.

## Categorie e automazione

Default: `.DS_Store` e `._*` selezionati, automazioni globali spente. Avanzate spente: `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.apdisk`, `.VolumeIcon.icns`, `Desktop.ini`, `Thumbs.db`, `.TemporaryItems`, `.AppleDouble` ed estensioni custom esatte.

Profili: `crossPlatform` seleziona AppleDouble e `.DS_Store`; `macMetadata` solo `.DS_Store`; `custom` conserva le scelte. La whitelist preserva AppleDouble per estensione. Le estensioni custom rifiutano wildcard e percorsi, escludono pacchetti/link/directory protette e per l'automazione richiedono analisi completa più consenso alla lista corrente.

Automazione = interruttore globale più consenso per UUID. Al mount pulisce una volta per montaggio dopo un breve ritardo, senza sorveglianza continua dei file. Pianificazione: 1..10080 minuti. Occorre app aperta oppure `drivesweep daemon` attivo; la CLI non installa servizi né resta in background dopo la chiusura del terminale.

## Reattività e confini

Analisi in un figlio di sola lettura, traversata unica, progressi circa 4 Hz, discovery su coda separata e richieste coalescenti. L'annullamento libera la coda principale e termina il figlio; I/O bloccato nel kernel può ritardarne l'uscita. La pulizia è cooperativa e non recupera file già rimossi.

UUID e idoneità ricontrollati prima delle azioni. Rifiutati: interni, immagini, rete, read-only, sottocartelle arbitrarie e UUID non verificati. Nessuna espulsione forzata; fallimento/annullamento impediscono l'espulsione successiva. I byte candidati sono dimensione logica dei soli file, non spazio recuperabile garantito. Cambio opzioni, pulizia e smontaggio invalidano gli snapshot.

## Documentazione e verifica

- [CLI](docs/CLI.md): comandi, flag, configurazione, JSON e codici di uscita.
- [Installazione](docs/INSTALLATION.md): aggiornamento, DMG, launcher e stato Homebrew.
- [Sicurezza](docs/SECURITY.md): effetti sui dati, filesystem e firma.
- [Implementazione e verifiche V3](docs/V3.md): evidenze e prove hardware pendenti.
- [Analisi di mercato](docs/market-analysis-v3.md): competitor e fonti primarie.
- [Ricerca BlueHarvest](docs/research-blueharvest-compatibility.md): comportamento documentato e differenze.

`make test` verifica bundle, sicurezza, IPC e CLI, senza pulire dati utente. Firma **ad-hoc**, senza Developer ID o notarizzazione Apple. I test locali non dimostrano superiorità su ogni competitor o assenza assoluta di blocchi su supporti guasti. Licenza [Apache-2.0](LICENSE).
