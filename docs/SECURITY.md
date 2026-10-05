# Sicurezza, dati e distribuzione

DriveSweep 3.1.1 è gratuito, Apache-2.0. App e CLI usano lo stesso motore locale senza rete, account, telemetria, helper privilegiati o servizi nascosti. Il Cask resta alla release pubblica 0.4.11 fino alla pubblicazione verificata della nuova versione.

## Firma e provenienza

Le build locali usano un certificato persistente in un keychain dedicato dell'utente. Il requisito designato vincola bundle ID e impronta del certificato: due build diverse della stessa identità soddisfano il medesimo requisito TCC; una copia firmata con un altro certificato non lo soddisfa. Nessuna scrittura nel database TCC, richiesta di privilegi root o modifica della fiducia di sistema. Il primo passaggio da ad hoc richiede un nuovo consenso macOS. La CI e le vecchie release sono ad hoc e non mantengono questa identità tra build.

`codesign --verify --deep --strict` verifica integrità, non equivale a Developer ID, notarizzazione o revisione antivirus di Apple. [Installazione](INSTALLATION.md) descrive conservazione dell'identità e distingue checksum locali e pubblici: l'hash 0.4.11 non vale per 3.1.

## Target e identità

- Solo volumi esterni fisici scrivibili: classificazione machine-readable di `diskutil`, caratteristiche del volume e VolumeUUID verificabili.
- CLI: radice assoluta esatta del mount, senza sottocartelle, target interni, rete, immagini o fallback al nome.
- Prima di pulizia e categorie distruttive si ricontrollano idoneità, UUID ed esclusioni. Cambio disco ferma il lavoro.
- Traversate senza symlink o attraversamento del dispositivo, con radici riservate protette. Estensioni custom escludono pacchetti, link e directory protette.
- Espulsione ordinaria, mai forzata, con UUID ricontrollato. Fallimento e annullamento impediscono l'espulsione successiva.

## Consenso ed effetti

Rimozione **definitiva**. `.DS_Store` contiene stato Finder; AppleDouble può contenere resource fork e attributi. `.Trashes` può contenere documenti recuperabili; le estensioni custom selezionano file reali. Default: `.DS_Store` e AppleDouble selezionati per manuale, avanzate e automazioni globali spente.

La GUI conferma le categorie. La CLI richiede `PULISCI` oppure `--yes`, senza saltare esclusioni o controlli. Nessun `clean --all`. Automazione = globale più consenso VolumeUUID. Le estensioni custom richiedono analisi completa e consenso al fingerprint corrente per ogni disco: cambiare lista lo invalida. `config set` non consente di iniettare `volumeRules`.

Un lock esclusivo coordina app/daemon per le automazioni, un altro il motore per ogni pulizia. Lock per utente, `O_NOFOLLOW`, controlli proprietario/file regolare/link count e `flock`; descriptor chiusi anche all'uscita anomala. Inode stabile, nessun dato utente nei lock. Non coordinano programmi terzi o altri utenti.

## Annullamento e filesystem

Analisi in figlio di sola lettura: annullamento libera il runner principale e termina il figlio; SIGKILL solo per quel worker. Un figlio non ancora uscito impedisce ulteriori scanner. Pulizia distruttiva cooperativa dopo il ritorno della chiamata filesystem corrente; annullare non recupera file già rimossi.

I/O lento o guasto può rimanere nel kernel. UUID e confini riducono il rischio, senza garantire una transazione atomica contro ogni modifica concorrente. Report parziale/annullato non è successo completo. TCC e permessi sono rispettati; nessuna modifica delle protezioni macOS.

## Risorse e report

`libproc` legge CPU, physical footprint, RSS, I/O e thread della famiglia DriveSweep dello stesso utente e dei figli. Massimo 128 PID e 60 campioni in memoria. CPU/I/O iniziali `null`, dati mancanti e troncamento espliciti. RAM condivisa può essere contata in più righe. Nessun invio automatico.

La protezione periodica controlla runner e propri figli, senza includere altre istanze: ogni 2 s, sospensione dopo due superamenti consecutivi di 80% CPU di un core o 750 MiB RSS. Non è un limite del kernel né un ottimizzatore RAM del Mac.

Report = snapshot; byte logici dei soli file, non spazio recuperabile garantito. Export CLI può contenere percorsi dei volumi/errori: controllalo prima di condividere. Export dashboard esclude percorsi privati degli errori. I risultati dell'app con opzioni superate vengono invalidati.

## Prove e segnalazioni

`make test`: fixture sacrificabili, identity/consent boundaries, symlink, directory protette, IPC, annullamento, lock e CLI reale senza pulizie di dati utente. [Evidenze](V3.md) separa fixture e prove hardware. Segnala problemi al manutentore evitando documenti personali o credenziali nei log.
