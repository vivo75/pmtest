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
- Risoluzione (a parità di voce): se la voce ha `repo`/`rust_dir` si
  esegue **sempre** `cargo build --release` del `package` (cargo è il
  proprio controllo di aggiornamento: no-op se nulla è cambiato, ma
  nessun run può graduare un binario stale dopo una modifica al
  sorgente; `PMTEST_NO_BUILD=1` disattiva la build dove il binario è
  volutamente prebuilt) → poi si usa il path dichiarato, e se manca è
  errore. Un PM senza `repo` (come `portage`) usa il path esplicito e
  non ha harness neutrali: gli harness contract per lui fanno skip, i
  contract via `emerge` girano normali.
- `version` — **risolta a run time, non scritta a mano**: `git` = commit
  corto di `<repo>` più `-dirty` se quel checkout ha modifiche non
  committate (un numero misurato su un albero sporco non è
  riproducibile dal commit, e non deve fingere di esserlo); `latest` =
  la prima riga che il binario stampa con `--version`. Qualunque altro
  valore viene usato alla lettera. È il dato che identifica la build a
  cui un report si riferisce, e i run lo scrivono da soli: `pm.json`
  nella dir di ogni run del bed, `pm`/`pm_version` nel JSON del
  benchmark.

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

3. Per il differential su albero reale (`differential-test-bed/run/l*.sh`)
   la voce deve dichiarare `repo`: gli orchestrator ricostruiscono il PM
   da lì e montano nel container la sua build dir e il suo checkout
   (cfr. `differential-test-bed/run/lib.sh`, `ensure_pm_built` /
   `podman_run_pm`).

## Come modificare una voce esistente

- **Nuova versione dello stesso PM**: aggiornate solo `version` (e il
  path, se la build vive altrove). Non toccate i test.
- **Divergenza attesa e legittima** (es. un PM che dichiara una
  differenza voluta): non si allenta il test — si registra in
  `differential-test-bed/compare/known-divergences.yaml` (L0/L1/L2) oppure si apre una
  voce di backlog. Il run è verde solo se ogni finding è spiegato lì.
- **Rinominare una voce**: è solo una chiave YAML, ma aggiornate anche
  gli eventuali `PMTEST_PM=...` negli script che la usano.

## Chi risolve cosa: `managers/registry.py`

La risoluzione vive in un solo posto, `managers/registry.py`, e tutto il
resto la usa — niente path di PM cablati altrove:

| Consumatore | Come |
|---|---|
| `pytests-contract-suite/conftest.py` | `registry.applet/harness/product_binary` (un `NotProvided` diventa `skip`, ogni altro errore `fail`) |
| `differential-test-bed/run/lib.sh` | `registry.py --sh` → `PM_NAME PM_PACKAGE PM_VERSION PM_EMERGE PM_BIN_DIR PM_REPO PM_RUST_DIR`; `--no-build` risolve senza costruire; `ensure_pm_built "$OUT"` scrive `pm.json` nella dir del run |
| `bench/run_benchmark.py` | `registry.harness("versions")` |
| `scripts/primitive_tree_differential.py` | `registry.harness(...)` per i tre harness |
| `scripts/portage_repin_review.py` | `registry.rust_dir(...)` (le citazioni da rivedere sono nei sorgenti del PM) |
| `scripts/real_world_spotcheck.sh`, `differential-test-bed/scripts/mo-trace/ptl-trace.sh` | `registry.py --sh` |

Tre cose che il registry impone, e che valgono per ogni PM:

- **Il bed differenziale gira solo su PM costruiti da sorgente.** Monta
  la build dir del PM come `/usr/local/bin` *e* il suo checkout al
  proprio path host, perché un binario può risolvere i propri dati di
  runtime (portuale: `bin/`, `3rdparty/portage`) da un path inciso a
  compile-time, che esiste solo dentro il suo albero. Una voce senza
  `repo` viene rifiutata con quel messaggio: il portage reale con cui si
  confronta è già dentro il container.
- **I path dei binari non vengono canonicalizzati.** `/usr/sbin/emerge`
  è un symlink verso un wrapper e la dispatch dei multicall guarda il
  basename di `argv[0]`: risolvere il symlink cambierebbe quale applet
  parte. Vengono canonicalizzate solo le *directory* (`repo`,
  `rust_dir`), perché sono mount point del container e prefissi da
  potare dagli snapshot, e devono combaciare con il path che il binario
  calcola per sé.
- **Diagnostica:** `python3 managers/registry.py` stampa la voce attiva,
  dove risolve i tre applet e a che versione, senza costruire nulla.

Un `PMTEST_PM` sconosciuto fallisce subito elencando le voci disponibili.
