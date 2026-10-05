# Installazione di DriveSweep 3.1

macOS 13+, Apple Silicon/Intel. App e CLI nello stesso bundle universale, versione locale 3.1.0 (21). Il Cask pubblico resta 0.4.11 e non contiene la CLI 3.1.

## Sorgente e aggiornamento

Servono Command Line Tools e Python 3 per i test:

```sh
git clone https://github.com/naicud/drivesweep.git
cd drivesweep
make test
make dmg
codesign --verify --deep --strict build/DriveSweep.app
plutil -extract CFBundleShortVersionString raw build/DriveSweep.app/Contents/Info.plist
lipo -archs build/DriveSweep.app/Contents/MacOS/DriveSweep
hdiutil verify build/DriveSweep.dmg
shasum -a 256 build/DriveSweep.dmg
```

Un clone pubblico precedente alla pubblicazione può avere il vecchio sorgente: verifica `Sources/CLI.inc`, `Sources/Resources.inc` e versione 3.1 in `Resources/Info.plist`. Il risultato è `build/DriveSweep.app` e `build/DriveSweep.dmg`.

Chiudi l'app precedente, sposta la vecchia copia da Applications nel Cestino con Finder e copia la nuova. Evita di unire i due bundle. Conserva le preferenze: categorie, esclusioni e consensi UUID restano salvati. Apri la nuova copia e controlla dashboard e versione CLI.

## Launcher CLI

Il launcher è `/Applications/DriveSweep.app/Contents/Resources/drivesweep`. Collega una directory **già nel PATH e scrivibile**, ad esempio:

```sh
ln -s /Applications/DriveSweep.app/Contents/Resources/drivesweep /opt/homebrew/bin/drivesweep
drivesweep --version
drivesweep --help
drivesweep resources --samples 2 --json
```

Su Intel puoi usare `/usr/local/bin` se scrivibile e nel PATH. Se il link esiste, verifica prima la destinazione e sostituisci solo il launcher DriveSweep. Il symlink continua a funzionare dopo gli aggiornamenti dell'app. Puoi anche invocare il percorso completo, senza link.

Prova della build senza installazione:

```sh
build/DriveSweep.app/Contents/MacOS/DriveSweep --cli --help
DRIVESWEEP_BIN="$PWD/build/DriveSweep.app/Contents/MacOS/DriveSweep" sh Scripts/drivesweep list --json
```

App e CLI condividono il dominio preferenze del bundle. Non serve `sudo` per l'uso normale.

## DMG e Homebrew pubblico

Scarica solo dalla [pagina release ufficiale](https://github.com/naicud/drivesweep/releases), verifica l'hash della **stessa versione**, apri il DMG e copia l'app. Il DMG include un collegamento ad Applications. Il Cask mantenuto per 0.4.11 usa SHA-256:

```text
c059f39fecd787e47cbb2ece6f647555ff6611e222f23fd1801bb41a29292d14
```

```sh
brew tap naicud/drivesweep https://github.com/naicud/drivesweep
brew install --cask drivesweep
```

Homebrew installa la versione pubblicata, non la 3.1 locale. Il checksum locale è `build/DriveSweep.dmg.sha256` quando generato; una ricostruzione può cambiarlo.

## Firma e primo utilizzo

Firma ad-hoc, senza notarizzazione Apple. Un download può ricevere un avviso Gatekeeper: verifica provenienza e integrità e consulta [Sicurezza](SECURITY.md) e la [guida Apple](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-identified-developer-mh40616/mac). Non è necessario disattivare globalmente le protezioni.

Collega un disco esterno scrivibile, analizza e controlla le categorie prima di pulire. Target interni, immagini e rete sono esclusi; errori di permesso sono espliciti. App e CLI rispettano TCC e non aggirano macOS.

Per l'automazione lascia l'app aperta oppure esegui `drivesweep daemon` in primo piano. Solo uno possiede il runner; se già occupato il daemon esce con codice 4. [Guida CLI](CLI.md).

Disinstallazione: chiudi app/daemon, sposta il bundle nel Cestino e rimuovi il solo symlink. Conservare le preferenze permette di reinstallare mantenendo le regole.
