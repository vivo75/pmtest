# USAGE — come usare pmtest

Istruzioni operative per agenti e umani. Dettagli in `README.md`
(layout, immagine container) e `managers/README.md` (formato registry).

## Contesto

- Root del repo: pmtest. Sorgente di sync: `../portuale` (mai `../2p`).
- PM sotto test: voce di `managers/managers.yaml`, attiva via
  `PMTEST_PM=<nome>` (default `portuale`).
- Correttezza prima dei numeri: suite verde + L0/L1 senza finding
  inspiegati, poi benchmark. Un PM veloce e sbagliato vale zero.

## Usa così

1. `PMTEST_PM=<nome> python3 -m pytest pytests-contract-suite -q` — suite fixture-based.
2. `differential-test-bed/run/l0-resolver.sh` e `differential-test-bed/run/l1-merge-from-binpkg.sh` —
   differential su albero reale (serve `localhost/test-portuale:latest`;
   poi `l0-fixture-oracle.sh`, `l2-portuale-builder.sh`,
   `l3-source-parity.sh`). Variante VM (serve `vm/work/golden.qcow2`,
   vedi `differential-test-bed/vm/README.md`):
   `differential-test-bed/run/l0-resolver-vm.sh [atomlist]`
   (report `l0-vm-*`, mai `l0-*`).
3. `python3 bench/run_benchmark.py --ops 200000 --repeat 5 --json out.json`
   — benchmark harness batch (default: `--dataset snapshot`, seed 0;
   riporta il migliore di 5).
4. Gate in CI: `PORTUALE_RUN_BENCHMARK=1 python3 -m pytest pytests-contract-suite -q`.
5. Nessun sync da rifare: l'infrastruttura vive solo qui (`README.md`,
   "Provenienza"), **`fixtures/` compresa** — l'albero del PM ci punta
   con un symlink, quindi ogni fixture nuova o corretta si aggiunge qui.
   Il PM sotto test viene **ricostruito a ogni run** dal suo `repo` di
   registry, quindi non si testa mai un binario stale; `python3
   managers/registry.py` dice quale voce è attiva, dove risolve e a che
   versione.

## Ammesso

- A1. Aggiungere voci in `managers/managers.yaml`. `version` non si scrive a
  mano: `git` (commit corto di `<repo>`, `-dirty` se il checkout ha
  modifiche non committate) o `latest` (quello che risponde il binario a
  `--version`).
- A2. Registrare divergenze attese in `differential-test-bed/compare/known-divergences.yaml`
  (e `known-divergences-fixture-oracle.yaml`).
- A3. Run in sola lettura: pytest, `differential-test-bed/run/l*.sh`, benchmark.
  I run non modificano mai il PM sotto test.
- A4. Fix all'harness in commit separato dal report dei risultati.

## Vietato

- F1. Modificare test, fixture, oracoli o soglie per far passare un PM.
  Un rosso si fissa nel PM, non qui.
- F2. Committare output di run: `differential-test-bed/logs/`, `fixtures/var/cache/`,
  `__pycache__/`, tarball stage3, `differential-test-bed/WORKDIR/`, `differential-test-bed/repos/`.
- F3. Testare un PM non dichiarato nel registry (niente path hardcoded,
  niente binari copiati a mano nel repo).
- F4. Confrontare PM su condizioni diverse: stessi `fixtures/`, stesso
  `bench/gentoo_snapshot.json`, stesso seed e stessi `--ops`/`--repeat`.
- F5. `--dataset synthetic` per i numeri ufficiali: solo `snapshot`.

## Valuta l'efficienza così

1. Esegui il comando del punto 3 sopra e leggi `out.json`:
   `speedup` = `python_seconds / rust_seconds`,
   `python_ops_per_sec` / `rust_ops_per_sec` per il throughput.
   Il gate richiede `speedup > 1.0` (`--min-speedup`).
2. Regressioni: `python3 bench/run_benchmark.py --check-baseline`
   (fallisce sotto il 90% di `bench/baseline.json`).
   `--update-baseline` solo in commit dedicato, mai con un cambio di PM.
3. Scala reale: `differential-test-bed/logs/l0-report.json` (parità resolver) e
   `l1-report.json` (0 hard finding attesi). Misurano comportamento,
   non velocità: pubblicali accanto ai secondi, mai al posto dei secondi.
4. Ogni numero pubblicato riporta tutti e sei questi dati, altrimenti
   si scarta (i primi due te li scrivono i run: `pm`/`pm_version` in
   `out.json`, `pm.json` nella dir di ogni run del bed):
    - voce registry + `version` risolta
    - `ops`, `seed`, `repeat`, `dataset`
    - macchina (CPU, RAM, host OS) + per i run VM: guest fs (`VM_FS`)
