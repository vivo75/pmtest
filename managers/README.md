# Registry dei package manager (`managers/`)

Questo è il punto in cui si dichiara **quale PM viene testato**.
Nessun path di PM è hardcoded nell'infrastruttura: i run (pytest e
`TEST/`) risolvono `emerge`/`ebuild`/`mrg` tramite la voce attiva del
registry, selezionata con la variabile d'ambiente `PMTEST_PM`.

```sh
PMTEST_PM=portage python3 -m pytest tests -q   # testate il portage reale
PMTEST_PM=portuale python3 -m pytest tests -q  # testate portuale (default)
```

## Formato di una voce (`managers.yaml`)

```yaml
pms:
  nome-del-pm:
    type: portage-compatible   # oppure: reference
    emerge: /percorso/del/binario-emerge
    ebuild: /percorso/del/binario-ebuild
    version: stringa-libera    # commit, versione, o etichetta del PM
```

- `type: reference` — il PM oracolo (oggi il portage reale). Il suo
  output è il comportamento atteso; non si modifica mai il test per
  farlo passare, si fissa il PM sotto test.
- `type: portage-compatible` — un PM alternativo che deve replicare il
  comportamento del reference (oggi portuale).
- `emerge` / `ebuild` — per i multicall (portuale) puntano entrambi allo
  stesso binario: la dispatch avviene via `argv[0]`, quindi i test
  creano symlink `emerge`/`ebuild`/`mrg` verso quel path ed esercitano
  lo stesso percorso di un'installazione reale.
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
   PMTEST_PM=portuale-dev python3 -m pytest tests/test_portuale.py -q
   ```

3. Per il differential su albero reale (`TEST/run/l*.sh`), la voce
   `portuale` deve puntare alla build release corrente: gli orchestrator
   montano `rust/target/release` nel container (cfr. `TEST/run/lib.sh`
   `podman_run_portuale`), quindi rieseguite la build del PM prima del
   run.

## Come modificare una voce esistente

- **Nuova versione dello stesso PM**: aggiornate solo `version` (e il
  path, se la build vive altrove). Non toccate i test.
- **Divergenza attesa e legittima** (es. un PM che dichiara una
  differenza voluta): non si allenta il test — si registra in
  `TEST/compare/known-divergences.yaml` (L0/L1/L2) oppure si apre una
  voce di backlog. Il run è verde solo se ogni finding è spiegato lì.
- **Rinominare una voce**: è solo una chiave YAML, ma aggiornate anche
  gli eventuali `PMTEST_PM=...` negli script che la usano.

## Nota sullo stato

Oggi `tests/conftest.py` (copiato da portuale) costruisce ancora il
binario con `cargo build -p portuale` hardcoded: leggere `managers.yaml`
e onorare `PMTEST_PM` è il prossimo passo di cablaggio. Fino ad allora
il registry è il riferimento per i run manuali/`TEST` e per la
documentazione di quale PM ha prodotto un report.
