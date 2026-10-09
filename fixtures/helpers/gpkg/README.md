# gpkg compress oracles (plan #326 S4, decisions D3/D4)

Expected values for the native `gpkg compress` writer, produced by RUNNING
the real `3rdparty/portage/bin/gpkg-helper.py compress <basename>
<binpkg_path> <metadata_dir> <image_dir>` with `/usr/bin/python`
(`../generate-gpkg.sh`). Rust tests read them through portuale's `fixtures`
symlink. Compare **fields, not raw header bytes** (D3).

## Layout

- `metadata/` -- the shared metadata dir handed to every run: the 25
  `build-info` members of the real porttest build `phases-1.0-1`
  (`differential-test-bed/logs/_l31-s0-pkgcache/porttest/phases/phases-1.0-1.gpkg.tar`,
  built by real Portage 3.0.82.2), extracted verbatim. The generator copies
  it in sorted name order onto tmpfs, so the raw `os.walk` order the helper
  sees (and `out.fields` records) is reproducible; **that order is
  filesystem-dependent** (zfs: per-directory hash order), so a consumer must
  stage the metadata the same way (tmpfs, sorted creation) to compare member
  order, or compare the metadata members as a set.
- `<case>/image.manifest` -- the image tree (checked in; owners, setuid bits,
  hardlinks and long names do not survive git). `<case>/NOTE` -- what the
  case isolates and its regression signature; `<case>/README` -- NOTE plus
  provenance (Portage pin, Python, compressor versions, MAKEOPTS, flags,
  passwd/group lines, staging fs), regenerated.
- `<case>/<comp>/` -- `args` (helper argv; `@OUT@ @METADATA@ @IMAGE@` are
  scratch paths), `env` (every setting real reads from `portage.settings`:
  `BINPKG_COMPRESS`, `MAKEOPTS`, `PORTAGE_BZIP2_COMMAND`, `FEATURES`,
  `BINPKG_GPG_*`; `BINPKG_COMPRESS_FLAGS[_<NAME>]` are unset), `out.gpkg.tar`
  (the real artifact), `out.fields`, `stderr.txt`, `rc.txt`, and, when the
  run as root differs from the run as the invoking user, `out.root.gpkg.tar`
  / `out.root.fields` / `stderr.root.txt` / `rc.root.txt` (owners and
  uname/gname: root run = manifest owners, `root` names).
- `materialise.py` re-creates an `image.manifest` on disk (format in its
  docstring); `dump_fields.py` writes `out.fields`; `locale-a.txt` is
  `locale -a` of the generating host. Signing uses `../gpg-keyring/`.

| case | compressors | isolates |
|---|---|---|
| plain | zstd xz bzip2 gzip | baseline member order, USTAR, padding, Manifest |
| special | zstd xz bzip2 gzip | symlinks, hardlink, setuid/setgid/sticky, UTF-8 name, >100-byte path (prefix split), owners incl. an unknown uid |
| empty | zstd xz bzip2 gzip | image with no entries |
| longname | zstd | 120-byte name + 110-byte link: image tar GNU (`L`/`K`) |
| long-basename | zstd | 154-char basename: container GNU switch |
| basename-153 | zstd | 153-char basename: stays USTAR |
| non-utf8 | zstd | real refuses a non-UTF-8 name (rc 1, no artifact) |
| signed | zstd | `FEATURES=binpkg-signing`, test keyring, `.sig` members |

## `out.fields` format (v1)

Pure ASCII, one record per line, in archive order. Names, linknames, unames
and gnames are `%XX`-escaped outside `[A-Za-z0-9._/+-]`; an empty
linkname is `-`. **mtime is never printed.** Vocabulary follows
`differential-test-bed/compare/gpkg_diff.py`'s buckets (outer-layout,
metadata, image, manifest) but carries every tarinfo field.

```
container.archive size=~ mod10240=<n>
container.member name=<> fmt=USTAR|GNU pre=<flags|-> type=<c> mode=<octal4> uid gid uname gname linkname devmajor devminor size=<n|~>
<metadata|image>.archive size=<decompressed bytes> mod10240=<n>      (0 = padded to a 10240 record)
<metadata|image>.member name=<> type=<c> fmt= pre= mode uid gid uname gname size linkname devmajor devminor [sha256=<payload>]
manifest.data name=<> volatile=none|compressor|mtime|signature [size=<n> ALGO=<hex>...|algos=ALGO:<len>hex,...]
manifest.pgp-armor|pgp-signature|pgp-base64|pgp-crc|other ...        (signed Manifest only / stray lines)
```

- `fmt` is read from the member's final header magic (`ustar\0` + `00` =
  USTAR, `ustar  \0` = GNU); `pre` lists the typeflags of extension
  headers in front of the member (`L` longname, `K` longlink, `x`/`g` PAX;
  `-` = none).
- Directory names carry the trailing `/` the writer emits (`tarfile` strips
  it on read; the dump puts it back and asserts it on plain headers).
- `~` marks values that depend on `datetime.now()`, the compressor build or
  the signature: container member sizes of compressed members and
  Manifest (never `gpkg-1`). Manifest `DATA` lines are kept, marked:
  `volatile=mtime` (metadata member: header mtimes are `now()`; digests
  elided to their algorithm/length), `volatile=compressor` (image member:
  stable on one host, changes with compressor version / MAKEOPTS; digests
  printed), `volatile=signature` (`.sig` members and the PGP block),
  `volatile=none` (`gpkg-1`).
- Real emits the checksum algorithms of a `DATA` line in set-iteration
  order (PYTHONHASHSEED-dependent, differs run to run); the dump sorts the
  `(ALGO, digest)` pairs by algorithm name.

## Reproducibility

`../generate-gpkg.sh` twice leaves every `out.fields`, `args`, `env`,
`rc*.txt`, `stderr*.txt` byte-identical. `out.gpkg.tar` differs between runs
only in `datetime.now()`-derived bytes: the mtime fields of the container
and metadata-tar headers and everything derived from them (header
checksums, the metadata member's compressed bytes, its Manifest digests,
the Manifest member). The image member (`image.tar.<ext>`) is identical
byte for byte: the materialiser pins every mtime to 1700000000.
