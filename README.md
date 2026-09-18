# pmtest — confronto tra package manager

Repository dedicato a **testare e confrontare tra loro varie versioni e
tipologie di package manager** (portuale, portage reale, altri PM).

Contenuto attuale: **duplicazione dell'infrastruttura di test costruita
per portuale** (estratta da `../portuale`, commit
`f8c2142508cf1ec942d0902c6689d6fc0cfeec5e`).
Nessuna logica di PM vive qui: solo harness, fixture e oracoli.
(`../2p` era solo un clone temporaneo di lavoro, non è più sorgente.)

## Layout

| Dir | Origine | Cosa contiene |
|---|---|---|
| `pytests-contract-suite/` | `portuale/tests/` | contract suite pytest (black-box via CLI): `emerge --pretend`, merge/unmerge, `output_invariants`, corpus, benchmark-gate, musl-smoke |
| `fixtures/` | `portuale/fixtures/` | alberi sintetici (`repo/`, `overlay/`, `etc/portage/`, `var/db`, `pkgdir/`, `binhost/`, `distfiles/`) contro cui gira la suite |
| `differential-test-bed/` | `portuale/TEST/` | differential test bed su container (L0 resolver, L1 merge-from-binpkg, L2 builder, L3 source parity) + `atomlists/`, `compare/`, `layers/`, `images/overlay/porttest/`, `create-container.bash` |
| `bench/` | `portuale/bench/` | benchmark harness (batch-mode) + snapshot reale Gentoo (`gentoo_snapshot.json`) |
| `scripts/` | `portuale/scripts/` | primitive-tree-differential, repin-review, md5-cache-audit, upstream-resolver-translate |
| `python-harness/` | `portuale/python/` | harness Python lato riferimento (`versions`/`atom`/`use_reduce`/`required_use`) |
| `managers/` | nuovo | registry + adapter per ogni PM sotto test (vedi `managers/README.md`) |
| `3rdparty` | symlink → `../portuale/3rdparty` | checkout pinned upstream (portage per gli harness/reference, chiavi gpg di test); materiale del PM, mai committato dentro pmtest — il symlink sì. Richiede `../portuale` con `3rdparty/` popolato (vedi `setup.sh` lì). |

Esclusi dalla copia (rigenerabili / scratch host-specifico): `differential-test-bed/logs/`,
`differential-test-bed/WORKDIR/`, `differential-test-bed/repos/`, `differential-test-bed/stage3-*.tar.xz`,
`fixtures/var/cache/`, `__pycache__/`, `.pytest_cache/`, `rust/target/`.

## Uso

```sh
# suite fixture-based contro il PM attivo (vedi managers/)
python3 -m pytest pytests-contract-suite -q
PMTEST_PM=portage python3 -m pytest pytests-contract-suite -q

# differential su albero reale (serve l'immagine del § sotto)
differential-test-bed/run/l0-resolver.sh
differential-test-bed/run/l1-merge-from-binpkg.sh
```

Quale binario viene testato è deciso dal **registry** (`managers/`),
non da path hardcoded: i test puntano a symlink `emerge`/`ebuild`/`mrg`
risolti dal PM attivo. Come aggiungere o modificare un PM è spiegato in
[`managers/README.md`](managers/README.md).

## Creare l'immagine container (`localhost/test-portuale:latest`)

Tutto il codice necessario è già in `differential-test-bed/`: `create-container.bash`,
`init.c` (il PID 1 che esegue `differential-test-bed/scripts/` in ordine lessicografico),
`images/overlay/porttest/` (l'overlay sintetico per L1/L2) e `net/`.
L'immagine non contiene i binari del PM: vengono montati a run-time da
`differential-test-bed/run/lib.sh`. Da fornire sull'host (mai committati, cfr.
`differential-test-bed/.gitignore`):

- `podman` + `buildah`, `gcc`, `python3` + `PyYAML`;
- i mirror git locali in `differential-test-bed/repos/{gentoo,buildovl}` — lo script li
  usa come remote `file://` e fa `git fetch --shallow-since=<data>
  <LAST_COMMIT>` ai pin dichiarati in testa allo script; in pratica
  symlink ai checkout già sincronizzati dell'host;
- lo stage3 (`stage3-amd64-systemd-<ts>.tar.xz`): se manca in `differential-test-bed/`,
  lo script lo scarica da `distfiles.gentoo.org`.

Comando (deve girare come root; dentro usa `sudo -su vivo` per
podman/buildah, con subuid/subgid configurati):

```sh
sudo differential-test-bed/create-container.bash
```

Lo script: compila `init`, scompatta lo stage3 in `WORKDIR/`, clona i
repo ai pin, copia l'overlay `porttest` (commit automatico), scrive
`resolv.conf`/`make.conf`/`repos.conf`, rimappa gli uid per il
userpriv-container e committa l'immagine `localhost/test-portuale:latest`
con entrypoint `/init`. Verifica con `podman images` e, se serve,
con i comandi commentati in fondo allo script.

## Provenienza / sync

Duplicazione pura da `PORTUALE/portuale` al commit sopra indicato.
Per re-sincronizzare (la sorgente è `../portuale`, mai `../2p`):

```sh
SRC=../portuale
for pair in "tests:pytests-contract-suite" "fixtures:fixtures" \
    "TEST:differential-test-bed" "bench:bench" "scripts:scripts" \
    "python:python-harness"; do
  src=${pair%%:*}; dst=${pair##*:}
  rsync -a --delete --exclude '__pycache__/' --exclude '*.pyc' \
    --exclude '.pytest_cache/' --exclude 'logs/' --exclude 'WORKDIR/' \
    --exclude 'repos/' --exclude 'stage3-*.tar.xz' --exclude 'var/cache/' \
    "$SRC/$src/" "$dst/"
done
```
I nomi locali restano (`pytests-contract-suite`, `differential-test-bed`,
`python-harness`): dopo il sync riesegui la ridenominazione solo se la
sorgente ha aggiunto file con riferimenti ai vecchi nomi.

Non si modifica l'infrastruttura qui per far passare un PM:
i bug vanno fissati nel PM, le divergenze attese in
`differential-test-bed/compare/known-divergences.yaml`.
