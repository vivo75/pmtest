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

1. `PMTEST_PM=<nome> python3 -m pytest pytests-contract-suite -q` — suite fixture-based (seriale, ~8 min). Il comando normale è `scripts/pytest-parallel.sh` (8 worker, ~90 s).
2. `differential-test-bed/run/l0-resolver.sh` e `differential-test-bed/run/l1-merge-from-binpkg.sh` —
   differential su albero reale (serve `localhost/test-portuale:latest`;
   poi `l0-fixture-oracle.sh`, `l2-portuale-builder.sh`,
   `l3-source-parity.sh`). L1: `L1_CONSUME_REINSTALL=1` forza il re-merge
   del set già installato (cella glibc/bash del merge-path safety gate);
   `L1_CONSUME_INSTALL_MASK="<pattern>"` (opt-in, backlog #358) accende
   `INSTALL_MASK` in entrambi i consumer prima del merge così il
   reinstall cancella file veri (solo doc) e il gate vede le
   cancellazioni; la path list dello snapshot include sempre anche i
   path dei `CONTENTS` pre-merge dei pacchetti sostituiti o reinstallati
   (`<run>/<pm>.pre-contents/`). Variante VM (serve `vm/work/golden.qcow2`,
   vedi `differential-test-bed/vm/README.md`):
   `differential-test-bed/run/l0-resolver-vm.sh [atomlist]`
   (report `l0-vm-*`, mai `l0-*`),
   `differential-test-bed/run/l1-merge-from-binpkg-vm.sh [atomlist]`
   (report `l1-vm-*`, pkgcache `_l1-pkgcache-vm`),
   `differential-test-bed/run/l2-portuale-builder-vm.sh [atomlist]`
   (report `l2-vm-*`, pkgcaches `_l2-pkgcache-*-vm`),
   `differential-test-bed/run/l3-source-parity-vm.sh [atomlist]`
   (report `l3-vm-*`, `L3_CONTROL=1` per il noise floor).
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

## Due repo, un progetto

pmtest (`fixtures/`, suite, bed, corpus) e `../portuale` (codice
prodotto, unit test, `docs/`) sono **un solo progetto in due repository**,
affiancati. Le regole sopra che dicono "questo repo" valgono per la
coppia, divise per contenuto, mai duplicate:

- **I branch si aprono insieme, con lo stesso nome.** Prima di iniziare,
  `git checkout -b <nome>` qui *e* in `../portuale` — anche se lo slice
  sembra toccare un lato solo (le fixture aggiunte a metà slice sono la
  norma, non l'eccezione). Un branch che esiste in un solo repo è già
  divergente; se ne trovi uno, segnalalo invece di aggirarlo.
- **I commit sono accoppiati.** Uno slice che tocca entrambi i lati
  produce due commit, uno per repo, sullo stesso branch: prodotto in
  portuale, fixture / celle del bed / pin / corpus bless qui (lo split
  è in `../portuale/AGENTS.md` step 5). I due messaggi si citano a
  vicenda così la coppia resta tracciabile senza altro legame: il commit
  pmtest nomina branch e slice di portuale, quello portuale cita lo sha
  corto pmtest (quindi prima pmtest). Un corpus bless
  (`PORTUALE_CORPUS_BLESS=1`) viaggia sempre nel commit pmtest, drift
  revisionato prima, mai in quello portuale.
- **I commit standalone restano singoli.** Lavoro che tocca davvero un
  solo repo (es. una correzione fixture solo-pmtest) si committa in quel
  repo da solo, su `main` o su un suo branch, senza controparte — ma il
  messaggio lo dice esplicitamente, così il prossimo agente non va a
  caccia della metà mancante.
- **I push vanno insieme.** La richiesta esplicita della regola 9 di
  `../portuale/AGENTS.md` copre entrambi i repo insieme salvo indicazione
  contraria; prima portuale, poi pmtest, riportando entrambi gli sha. Mai
  pushare metà coppia lasciando l'altra in locale.
- Resta F1: i pin qui si aggiornano solo contro un oracle reale, mai per
  far passare un PM — la libertà di re-pinnare a costo zero non è una
  licenza per il bless di massa senza verifica.

## Spazio /tmp

La suite ha ripetutamente riempito `/tmp` (inode, non solo byte: è tmpfs,
RAM-backed, con un tetto FISSO indipendente dalla RAM effettiva). Due
cause distinte, entrambe indipendenti da chi lancia la suite:

- un test di merge chown-a a `root` i path che installa (simula proprietà
  reale; questo container ha sudo passwordless), e la pulizia di pytest
  gira senza privilegi: non può rimuoverli, li rinomina `garbage-<uuid>`
  e li lascia lì per sempre;
- **ogni** invocazione di `emerge`/`ebuild` che esegue fasi reali crea un
  suo overlay `$TMPDIR/portuale-bin.<pid>` (`ebuild_phases.rs::bin_dir()`)
  e non lo rimuove mai — un leak nel PM stesso, non nell'harness; su
  `/tmp` restava invisibile nel rumore generale.

Difese, automatiche, in ordine di quanto costano:

1. **Bonifica a inizio sessione.** `pytests-contract-suite/conftest.py`
   (`pytest_configure`) e `differential-test-bed/run/lib.sh` ripuliscono
   quanto lasciato dalla sessione precedente prima di partire — via
   `sudo -n` per i residui root-owned (silenzioso e mai bloccante se
   sudo non c'è: si limita a non risolvere quel residuo), senza sudo per
   gli overlay `portuale-bin.*`. Verificato: due run pieni consecutivi
   restano piatti (stesso numero di overlay dopo il secondo run di dopo
   il primo, mai la somma).
2. **Preflight spazio/inode.** Prima di collezionare, `pytest_configure`
   legge `statvfs` sulla base tmp: sotto una soglia bassa fallisce con un
   messaggio chiaro invece di una cascata di `OSError` a metà run; sotto
   una soglia più alta avverte soltanto. Soglie in env, non hardcoded:
   `PMTEST_MIN_FREE_INODES`/`_WARN`, `PMTEST_MIN_FREE_BYTES`/`_WARN`.
3. **Disco reale, non tmpfs.** Default `/var/tmp/pmtest` (non `/tmp`):
   disco vero, non RAM, inode non capati indipendentemente dallo spazio.
   Un solo path fisso riusato a ogni run (niente `pytest-N` numerati:
   niente famiglia di `garbage-*` da inseguire). Override: `PMTEST_TMPDIR`
   (vince anche su un `TMPDIR` ambientale); un `--basetemp` esplicito
   sulla riga di comando resta sempre rispettato senza interferenze.

**Non basta impostare `$TMPDIR`** per il punto 3: il capture manager di
pytest crea i propri file per catturare l'IMPORT di `conftest.py` stesso
(così un print/errore durante il caricamento viene catturato anch'esso),
e per farlo chiama `tempfile.gettempdir()` — che mette in cache il
vecchio valore — **prima** che il codice del modulo giri. L'unico aggancio
affidabile è `config.option.basetemp`, letto direttamente da
`TempPathFactory` bypassando `tempfile`. Trappola gemella: `import corpus`
deve avvenire **dopo** aver impostato `TMPDIR`, perché `corpus.py`
fotografa l'ambiente al proprio import (`_HOST_ENV`, per distinguere "solo
ereditato dall'host" da "specifico di questa chiamata") — importarlo
prima rompe ogni confronto col corpus che passa da `fixture_env()`.

L'overlay `portuale-bin.<pid>` resta un bug del PM, non dell'harness: F1
si applica anche qui, non lo si nasconde ripuntando `/tmp` altrove senza
dirlo.

## Cache delle risposte di Portage (#448)

I fixture `*_harness_python` (atom, versions, use_reduce, required_use)
non lanciano più Portage a ogni run: passano da
`python-harness/cached_harness.py <nome> [args...]`, che rispedisce la
risposta registrata (returncode, stdout, stderr) se esiste.

- **Dove**: `python-harness/answers/<nome>.jsonl`, append-only, una riga
  JSON per risposta, committato (un clone fresco è veloce). Per una
  chiave vince l'ultima riga.
- **Chiave**: sha256 di pin Portage (`git rev-parse HEAD` del checkout in
  `3rdparty/portage`; se non è un repo, l'hash di `lib/portage/__init__.py`),
  sha256 dell'harness e del wrapper `_pinned_portage.py`, argv, stdin
  (letto solo in `batch`).
- **Invalidazione**: cambia il pin Portage, o cambia il file dell'harness
  o il wrapper. Un checkout Portage con modifiche locali ai file tracciati
  non ha pin valido: gira sempre live e non registra nulla.
- **Variabili**: `PMTEST_PORTAGE_CACHE=off` bypassa la cache (né lettura
  né scrittura); `PMTEST_REFRESH_PORTAGE=1` ignora i hit, rigira live e
  appende la risposta nuova.
- **Mai per portuale**: la cache avvolge solo il lato riferimento
  (Portage). I binari Rust non passano di qui. Il bench
  (`bench/run_benchmark.py`) e `scripts/primitive_tree_differential.py`
  restano sul percorso live.
- **Ri-registrare** dopo un cambio di pin: un run normale basta (le
  risposte nuove si aggiungono); per riscrivere tutto,
  `PMTEST_REFRESH_PORTAGE=1` sulle suite che usano i fixture.

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
5. Benchmark resolver `@world`-shaped (backlog #461, pmtest-side):
   `python3 bench/world_shaped_benchmark.py` — genera l'input
   deterministico (`bench/gen_world_shaped.py`, seed 461), verifica il
   fingerprint, fa un warmup + 3 run di
   `PORTUALE_PROFILE=1 <pm> emerge -puDN @world` e stampa le mediane
   delle fasi (stesso metodo di
   `portuale:LLM/evidence/2026-10-21-world-profile/`). Dettagli e tagli
   vs il benchmark su host live: `bench/WORLD_SHAPED.md`.

## Suite in parallelo (backlog #449)

`scripts/pytest-parallel.sh [args]` esegue tutta la suite con pytest-xdist
(8 worker; `JOBS=16` per cambiare): ~90 s invece di ~630 s seriale, stessi
4206 test passati. Il venv con xdist sta in `/var/tmp/pxvenv` (si ricrea da
solo). A `-n 16` il guadagno è piccolo (~76 s) e una volta su quattro una run
è uscita con codice 1 senza che il nome del fallimento sia stato catturato:
usare 8. Dopo la run: `sudo rm -rf /var/tmp/pytest-parallel` (un test crea file
di root) e `git clean -fdq fixtures/`.

## Registrazioni del terminale (backlog #443)

`scripts/cast_cells.py [--out DIR]` esegue 8 celle `--pretend` sotto Portage e
portuale in un pty registrato con `asciinema rec --headless` (asciicast v3) e
scrive `report.md` (default `/var/tmp/casts`, mai `/dev/shm`).
`scripts/cast_compare.py A.cast B.cast` confronta due registrazioni: testo,
suddivisione in eventi di output, tempi. I tempi sono solo un rapporto, non
un controllo. Test: `pytests-contract-suite/test_cast_tools.py`.
`--cells long|all` (backlog #452) registra anche merge reali dei pacchetti
`sched*` (keep-going, stop, dipendente rotto, multi, `--resume`, `--ask` con
risposta `n`/`y`) sotto `sudo --preserve-env`, con output limitato da
`--cap-bytes` (default 20000, 0 = off) e una tabella di tempi per
«landmark» (solo report). `--ask` richiede un tty: usa
`cast_record.record_with_answers`. Nel bed `PMTEST_CAST=1` monta
l'`asciinema` dell'host nel guest.
