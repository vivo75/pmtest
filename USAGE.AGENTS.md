# USAGE — come usare pmtest

Istruzioni operative. Leggi anche `README.md` (layout, immagine
container) e `managers/README.md` (formato del registry).

## Usa così

1. Seleziona il PM sotto test: `PMTEST_PM=<nome>` (default `portuale`).
   Le voci vivono in `managers/managers.yaml`.
2. Suite fixture-based: `python3 -m pytest tests -q`.
3. Differential su albero reale (serve `localhost/test-portuale:latest`,
   vedi `README.md`): `TEST/run/l0-resolver.sh`,
   `TEST/run/l1-merge-from-binpkg.sh`, poi L2/L3.
4. Benchmark: `python3 bench/run_benchmark.py --ops 200000`
   (gate in CI: `PORTUALE_RUN_BENCHMARK=1 python3 -m pytest tests -q`).
5. Re-sync dell'infrastruttura solo da `../portuale`, mai da altri
   clone (comando in `README.md`).

## Ammesso

- Aggiungere voci in `managers/managers.yaml` (nuovi PM, nuove versioni,
  nuove build). Aggiorna sempre `version`.
- Registrare divergenze attese e legittime in
  `TEST/compare/known-divergences.yaml` (e `-fixture-oracle.yaml`).
- Eseguire qualunque run in lettura: pytest, `TEST/run/l*.sh`,
  benchmark. I run non modificano mai il PM sotto test.
- Proporre fix all'harness (conftest, compare, script) con commit
  separato dal report dei risultati.

## Vietato

- Modificare test, fixture, oracoli o soglie per far passare un PM.
  Un rosso si fissa nel PM, non qui.
- Committare output di run: `TEST/logs/`, `fixtures/var/cache/`,
  `__pycache__/`, tarball stage3, `WORKDIR/`, `repos/` (sono git-ignorati).
- Testare un PM senza dichiararlo nel registry (niente path hardcoded,
  niente binari copiati a mano nel repo).
- Confrontare PM diversi su fixture, dataset o seed diversi: stesso
  `fixtures/`, stesso `bench/gentoo_snapshot.json`, stesso seed,
  altrimenti il confronto non vale.
- Usare `--dataset synthetic` per i numeri ufficiali: il riferimento è
  sempre `--dataset snapshot` (albero Gentoo reale).

## Valuta l'efficienza così

Ordine tassativo: prima la correttezza (suite verde + L0/L1 senza
finding inspiegati), poi i numeri. Un PM veloce e sbagliato vale zero.

1. `python3 bench/run_benchmark.py --ops 200000 --repeat 5 --json out.json`
   (default: snapshot reale, seed 0; minimo riportato = migliore di 5).
2. Leggi `out.json`: `speedup` = `python_seconds / rust_seconds`
   (o PM-sotto-test vs reference), `*_ops_per_sec` per il throughput.
   Il gate richiede `speedup > 1.0` (`--min-speedup`).
3. Regressioni: `python3 bench/run_benchmark.py --check-baseline`
   (fallisce sotto il 90% di `bench/baseline.json`); aggiorna il
   baseline solo con `--update-baseline` in un commit dedicato, mai
   insieme a un cambio di PM.
4. Scala reale: `TEST/logs/l0-report.json` (tasso di parità del resolver)
   e `l1-report.json` (0 hard finding attesi). Sono misure di
   comportamento, non di velocità: pubblicali accanto ai secondi, mai al
   posto dei secondi.
5. Riporta sempre, per ogni numero: voce registry + `version`, ops, seed,
   repeat, dataset, macchina. Senza questi cinque dati il benchmark si
   scarta.
