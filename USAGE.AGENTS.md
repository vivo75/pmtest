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

1. `PMTEST_PM=<nome> python3 -m pytest tests -q` — suite fixture-based.
2. `TEST/run/l0-resolver.sh` e `TEST/run/l1-merge-from-binpkg.sh` —
   differential su albero reale (serve `localhost/test-portuale:latest`;
   poi `l0-fixture-oracle.sh`, `l2-portuale-builder.sh`,
   `l3-source-parity.sh`).
3. `python3 bench/run_benchmark.py --ops 200000 --repeat 5 --json out.json`
   — benchmark harness batch (default: `--dataset snapshot`, seed 0;
   riporta il migliore di 5).
4. Gate in CI: `PORTUALE_RUN_BENCHMARK=1 python3 -m pytest tests -q`.
5. Re-sync infrastruttura solo da `../portuale` (comando in `README.md`).

## Ammesso

- A1. Aggiungere voci in `managers/managers.yaml`. Aggiorna sempre `version`.
- A2. Registrare divergenze attese in `TEST/compare/known-divergences.yaml`
  (e `known-divergences-fixture-oracle.yaml`).
- A3. Run in sola lettura: pytest, `TEST/run/l*.sh`, benchmark.
  I run non modificano mai il PM sotto test.
- A4. Fix all'harness in commit separato dal report dei risultati.

## Vietato

- F1. Modificare test, fixture, oracoli o soglie per far passare un PM.
  Un rosso si fissa nel PM, non qui.
- F2. Committare output di run: `TEST/logs/`, `fixtures/var/cache/`,
  `__pycache__/`, tarball stage3, `TEST/WORKDIR/`, `TEST/repos/`.
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
3. Scala reale: `TEST/logs/l0-report.json` (parità resolver) e
   `l1-report.json` (0 hard finding attesi). Misurano comportamento,
   non velocità: pubblicali accanto ai secondi, mai al posto dei secondi.
4. Ogni numero pubblicato riporta tutti e sei questi dati, altrimenti
   si scarta:
   - voce registry + `version`
   - `ops`, `seed`, `repeat`, `dataset`
   - macchina (CPU, RAM, host OS)
