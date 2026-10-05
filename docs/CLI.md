# CLI DriveSweep 3.1

`drivesweep` invoca il binario dell'app con `--cli`, senza finestre. Stesso motore, categorie, preferenze e consensi. [Installazione del launcher](INSTALLATION.md#launcher-cli).

## Dischi e operazioni

```sh
drivesweep --version
drivesweep --help
drivesweep list --json
drivesweep analyze /Volumes/USB
drivesweep analyze --all --export ./report.json --json
drivesweep clean /Volumes/USB
drivesweep clean /Volumes/USB --eject --yes --json
```

`VOLUME`: radice esatta di un esterno fisico scrivibile con UUID verificato; quota percorsi con spazi. `--all` solo per analisi, salta esclusi. `--export` rifiuta file già esistenti. Analisi di sola lettura: categorie, conteggi, AppleDouble protetti, errori e `candidateFileBytes` (byte logici dei soli file, senza promessa di spazio recuperabile). I report sono raccolti nell'array `reports`.

Pulizia definitiva: conferma digitando `PULISCI`, oppure `--yes` negli script. Questo flag non salta controlli o esclusioni. `--eject` solo dopo successo e UUID ricontrollato; nessun target interno, sottocartella o force eject. `--json` riserva stdout al JSON; progressi/notifiche su stderr.

## Profili e configurazione

```sh
drivesweep profiles
drivesweep profiles set macMetadata
drivesweep config show --json
drivesweep config set dsStore true
drivesweep config set appleDoubleExtensions eps,font
drivesweep config set customFileExtensions tmp,bak
drivesweep config set customFiles true
drivesweep config reset --yes
```

Profili: `crossPlatform` (`._*` e `.DS_Store`), `macMetadata` (solo `.DS_Store`), `custom` (conserva scelte). Cambiare categorie o estensioni seleziona `custom`. `reset` conserva regole UUID ed esclusioni nominali, ripristina categorie iniziali e spegne automazioni.

| Chiave | Valore |
|---|---|
| `automaticCleaning`, `periodicCleaning` | Booleano true/false; accetta yes/no, 1/0 |
| `periodicCleaningInterval` | Minuti interi 1..10080 |
| `cleanupProfile` | crossPlatform, macMetadata, custom |
| `appleDouble`, `dsStore`, `customFiles` | Booleano |
| `trashes`, `spotlight`, `fileEvents`, `apdisk`, `volumeIcon` | Booleano, categorie avanzate |
| `desktopIni`, `thumbsDb`, `temporaryItems`, `appleDoubleDirectories` | Booleano, categorie avanzate |
| `appleDoubleExtensions` | Lista separata da virgole da **preservare** per AppleDouble |
| `customFileExtensions` | Estensioni esatte da **rimuovere**, senza wildcard/percorso |
| `excludedVolumes` | Nomi separati da virgole; preferire UUID |

Rifiutati prima di salvare: chiavi sconosciute, booleani ambigui, intervalli non validi e liste custom parzialmente valide. `volumeRules` e chiavi interne non impostabili. App e daemon ricevono modifiche alle preferenze; evita scritture simultanee da più frontend, senza transazione multi-chiave.

## Consensi del disco

```sh
drivesweep rules list --json
drivesweep rules set /Volumes/USB --exclude true
drivesweep rules set /Volumes/USB --exclude false
drivesweep rules set /Volumes/USB --automatic true --periodic true --yes
drivesweep rules confirm-custom /Volumes/USB --yes --json
```

Regole legate all'UUID, non al nome. Escludere spegne automatico/periodico per il disco. Rimuovi l'esclusione prima di abilitarli. Abilitazione richiede conferma, `false` revoca.

`confirm-custom`: categoria custom attiva e lista valida, analisi completa di sola lettura, report e conferma della lista corrente. Errore, annullamento o UUID cambiato impediscono il consenso. Con `--json` produce due righe JSON: report e regola finale, oppure report ed errore se la conferma viene negata. Cambiare lista invalida la conferma.

## Pianificazione e mount

```sh
drivesweep schedule status --json
drivesweep schedule start 30
drivesweep schedule stop
drivesweep config set automaticCleaning true
drivesweep daemon
```

`start` configura senza pulire subito. `stop` disattiva globale e richiede annullamento periodico attivo. Servono globale e consenso UUID. La configurazione persiste; l'esecuzione richiede app aperta oppure daemon in primo piano.

`daemon`: mount/unmount e pianificazione, riconciliazione ogni 15 s, risorse live se stdout è TTY. `daemon --json`: NDJSON al secondo, notifiche stderr. Un solo runner: se app/daemon proprietario, esce 4. Nessun launchd, login item o servizio persistente. Ctrl-C lo ferma.

`schedule run`: passaggio periodico sui dischi autorizzati, solo con globale attivo e runner libero. Applica consensi custom, verifiche e guard CPU/RSS. Nessun disco autorizzato restituisce report vuoti senza pulizia.

## Risorse live

```sh
drivesweep resources --watch
drivesweep resources --watch --interval 0.5 --json
drivesweep resources --samples 5 --interval 1 --json
```

Default: due campioni, distanza 1 s. `--watch` fino a Ctrl-C; `--samples` intero 1..3600; `--interval` 0.25..10 s. JSON: una riga per campione. Terminale: barre/tachimetri CPU/RAM e righe PID.

Campi: `timestamp` Unix, `cpuPercent` (100% = un core), `logicalCPUs`, `physicalBytes`, `residentBytes`, `peakPhysicalBytes`, `readBytesPerSecond`, `writeBytesPerSecond`, `unavailable`, `warmingProcesses`, `truncated`, `processes`. Per processo: PID, nome, CPU, footprint/RSS, I/O, thread; se non accessibile `available:false`. CPU/I/O al primo campione `null`, non zero inventato.

Include processo corrente, altre istanze DriveSweep dello stesso utente e figli, senza duplicare PID. Identità PID+istante di avvio protegge i delta dai PID riutilizzati. Massimo 128 processi e 60 campioni in memoria; processi brevi possono sfuggire e RAM condivisa può comparire in più righe. Scala CPU su tutti i core, RAM fisica 750 MiB (scala visiva, non RAM totale Mac). Misure via [libproc Apple](https://github.com/apple-oss-distributions/xnu/blob/main/libsyscall/wrappers/libproc/libproc.h).

## Interruzioni ed exit

Ctrl-C/SIGTERM fermano nuovo lavoro e annullano l'attivo. Analisi termina il figlio di sola lettura; pulizia cooperativa dopo I/O corrente. Il monitor termina senza modificare preferenze. File già rimossi non vengono recuperati.

| Codice | Significato |
|---|---|
| 0 | Successo |
| 1 | Operazione, export o espulsione falliti |
| 2 | Uso, valore o conferma non validi |
| 3 | Target non idoneo/non verificato/escluso |
| 4 | Runner o pulizia occupati |
| 130 / 143 | SIGINT / SIGTERM |

Flag duplicati o non previsti sono errori. Export locali possono contenere percorsi/errori: controllali prima di condividere. [Sicurezza](SECURITY.md), [evidenze](V3.md).
