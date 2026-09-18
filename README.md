# pmtest — confronto tra package manager

Repository dedicato a **testare e confrontare tra loro varie versioni e
tipologie di package manager** (portuale, portage reale, altri PM).

Contenuto attuale: **duplicazione dell'infrastruttura di test costruita
per portuale** (estratta da `../2p`, commit `c35b37dcd3b884cb6af333c47aca40713d41d5e7`).
Nessuna logica di PM vive qui: solo harness, fixture e oracoli.

## Layout

| Dir | Origine | Cosa contiene |
|---|---|---|
| `tests/` | `2p/tests/` | contract suite pytest (black-box via CLI): `emerge --pretend`, merge/unmerge, `output_invariants`, corpus, benchmark-gate, musl-smoke |
| `fixtures/` | `2p/fixtures/` | alberi sintetici (`repo/`, `overlay/`, `etc/portage/`, `var/db`, `pkgdir/`, `binhost/`, `distfiles/`) contro cui gira la suite |
| `TEST/` | `2p/TEST/` | differential test bed su container (L0 resolver, L1 merge-from-binpkg, L2 builder, L3 source parity) + `atomlists/`, `compare/`, `layers/`, `images/overlay/porttest/` |
| `bench/` | `2p/bench/` | benchmark harness (batch-mode) + snapshot reale Gentoo (`gentoo_snapshot.json`) |
| `scripts/` | `2p/scripts/` | primitive-tree-differential, repin-review, md5-cache-audit, upstream-resolver-translate |
| `python/` | `2p/python/` | harness Python lato riferimento (`versions`/`atom`/`use_reduce`/`required_use`) |
| `managers/` | nuovo | registry + adapter per ogni PM sotto test (vedi `managers/managers.yaml`) |

Esclusi dalla copia (rigenerabili): `TEST/logs/`, `__pycache__/`,
`.pytest_cache/`, `rust/target/`.

## Uso

```sh
# suite fixture-based contro un PM registrato
python3 -m pytest tests -q

# differential su albero reale (serve podman + image localhost/test-portuale:latest)
TEST/run/l0-resolver.sh
TEST/run/l1-merge-from-binpkg.sh
```

Quale binario viene testato è deciso dal **registry** (`managers/`),
non da path hardcoded: i test puntano a symlink `emerge`/`ebuild`/`mrg`
risolti dal PM attivo (`PMTEST_PM=portage-3.0.82.2 ...`).
Oggi gli adapter contengono solo le due voci seed (`portuale`, `portage`);
la generalizzazione di `tests/conftest.py` (oggi `cargo build -p portuale`
hardcoded) a `managers/` è il prossimo passo.

## Provenienza / sync

Duplicazione pura da `PORTUALE/2p` al commit sopra indicato.
Per re-sincronizzare:

```sh
SRC=../2p; for d in tests fixtures TEST bench scripts python; do \
  rsync -a --delete --exclude '__pycache__/' --exclude '*.pyc' \
    --exclude '.pytest_cache/' --exclude 'logs/' "$SRC/$d/" "$d/"; done
```

Non si modifica l'infrastruttura qui per far passare un PM:
i bug vanno fissati nel PM, le divergenze attese in
`TEST/compare/known-divergences.yaml`.
