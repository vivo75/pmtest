# Registry dei package manager (`managers/`)

Questo è il punto in cui si dichiara **quale PM viene testato**.
Nessun path di PM è hardcoded nell'infrastruttura: i run (pytest e
`differential-test-bed/`) risolvono `emerge`/`ebuild`/`mrg` tramite la voce attiva del
registry, selezionata con la variabile d'ambiente `PMTEST_PM`.

```sh
PMTEST_PM=portage python3 -m pytest pytests-contract-suite -q   # testate il portage reale
PMTEST_PM=portuale python3 -m pytest pytests-contract-suite -q  # testate portuale (default)
```

## Formato di una voce (`managers.yaml`)

```yaml
pms:
  nome-del-pm:
    type: portage-compatible   # oppure: reference
    emerge: /percorso/del/binario-emerge
    ebuild: /percorso/del/binario-ebuild
    mrg: /percorso/del/binario-mrg
    version: stringa-libera    # commit, versione, o etichetta del PM
```

Campi opzionali per i PM costruiti da sorgente (come portuale):

```yaml
    repo: ../portuale          # albero sorgente; la build gira in <repo>/rust
    rust_dir: ../portuale/rust # default: <repo>/rust (serve solo se diverso)
    package: portuale          # package cargo del multicall (default: portuale)
    binary: /path/esplicito    # vince su emerge per la fixture product-binary
    versions_harness: /path    # override per-harness (default:
    atom_harness: /path        #   <rust_dir>/target/release/<package-harness>)
```

- `type: reference` — il PM oracolo (oggi il portage reale). Il suo
  output è il comportamento atteso; non si modifica mai il test per
  farlo passare, si fissa il PM sotto test.
- `type: portage-compatible` — un PM alternativo che deve replicare il
  comportamento del reference (oggi portuale).
- `emerge` / `ebuild` / `mrg` — per i multicall (portuale) puntano tutti
  allo stesso binario: la dispatch avviene via `argv[0]`, quindi i test
  creano symlink `emerge`/`ebuild`/`mrg` verso quel path ed esercitano
  lo stesso percorso di un'installazione reale. I path relativi si
  risolvono contro la root di pmtest.
- Risoluzione (a parità di voce): path esplicito se esiste → altrimenti
  `cargo build --release` del `package` da `rust_dir` (solo se la voce
  ha `repo`/`rust_dir`) → altrimenti skip con messaggio esplicito. Un PM
  senza `repo` (come `portage`) non ha harness neutrali: gli harness
  contract per lui fanno skip, i contract via `emerge` girano normali.
- `version` — solo documentazione: serve a risalire a *quale* build del
  PM un report si riferisce. Tenetela aggiornata a ogni cambio di PM.

## Come aggiungere un PM

1. Aggiungete una voce in `managers.yaml`, ad esempio una seconda build
   di portuale da un altro albero:

   ```yaml
   portuale-dev:
     type: portage-compatible
     emerge: /home/vivo/repo/PORTUALE/portuale-dev/rust/target/release/portuale
     ebuild: /home/vivo/repo/PORTUALE/portuale-dev/rust/target/release/portuale
     version: <commit della build>
   ```

2. Verificate che i symlink risolvano:

   ```sh
   PMTEST_PM=portuale-dev python3 -m pytest pytests-contract-suite/test_portuale.py -q
   ```

3. Per il differential su albero reale (`differential-test-bed/run/l*.sh`), la voce
   `portuale` deve puntare alla build release corrente: gli orchestrator
   montano `rust/target/release` nel container (cfr. `differential-test-bed/run/lib.sh`
   `podman_run_portuale`), quindi rieseguite la build del PM prima del
   run.

## Come modificare una voce esistente

- **Nuova versione dello stesso PM**: aggiornate solo `version` (e il
  path, se la build vive altrove). Non toccate i test.
- **Divergenza attesa e legittima** (es. un PM che dichiara una
  differenza voluta): non si allenta il test — si registra in
  `differential-test-bed/compare/known-divergences.yaml` (L0/L1/L2) oppure si apre una
  voce di backlog. Il run è verde solo se ogni finding è spiegato lì.
- **Rinominare una voce**: è solo una chiave YAML, ma aggiornate anche
  gli eventuali `PMTEST_PM=...` negli script che la usano.

## Nota sullo stato

`pytests-contract-suite/conftest.py` è cablato sul registry: `PMTEST_PM` seleziona la
voce, i path espliciti vincono se esistono sul disco, altrimenti la
voce viene costruita con `cargo build --release` da `<repo>/rust`
(solo se la voce dichiara `repo` e `cargo` è disponibile), altrimenti
il test fa skip con un messaggio che dice cosa manca. Un `PMTEST_PM`
sconosciuto fallisce subito elencando le voci disponibili.

Ancora hardcoded fuori dalla suite pytest: `bench/run_benchmark.py`
(coppia Rust-vs-Python) e `differential-test-bed/run/lib.sh` (`ensure_portuale_built`)
— prossimi candidati allo stesso trattamento.
