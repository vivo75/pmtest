#!/bin/bash
# 328-quickpkg-makeopts.sh -- portuale #328 oracle: the gpkg compressor of
# an unmerge-backup quickpkg takes {JOBS} from make.conf MAKEOPTS (real
# gpkg._get_binary_cmd: makeopts_to_job_count(settings["MAKEOPTS"])).
# Runs inside the bed image as root with either PM:
#
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     localhost/test-portuale:latest /o/328-quickpkg-makeopts.sh /usr/bin/emerge
#   podman run --rm --entrypoint /bin/bash -v $PWD/scripts:/o:ro \
#     -v <portuale>/rust/target/release:/pm:ro \
#     localhost/test-portuale:latest /o/328-quickpkg-makeopts.sh "/pm/portuale emerge"
#
# Prints the argv of every zstd call made during `emerge -C`.
set -u
EMERGE=$1
R=/var/db/repos/qp
mkdir -p $R/metadata $R/profiles $R/qp/q
echo qp > $R/profiles/repo_name; echo qp > $R/profiles/categories
printf 'masters = gentoo\nthin-manifests = true\nsign-manifests = false\n' > $R/metadata/layout.conf
printf '[qp]\nlocation = %s\n' $R > /etc/portage/repos.conf/qp.conf
cat > $R/qp/q/q-1.ebuild <<'EOF'
EAPI=8
DESCRIPTION="one file to back up on unmerge"
SLOT=0
KEYWORDS="~amd64 amd64"
S=${WORKDIR}
src_install() { insinto /usr/share/qp; newins - f <<<'payload'; }
EOF
F="-sandbox -usersandbox -ipc-sandbox -network-sandbox -pid-sandbox -mount-sandbox"
run() { env -i PATH=/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root TERM=dumb FEATURES="$F $1" $EMERGE "${@:2}" > /tmp/emerge.log 2>&1; echo "emerge ${*:2} rc=$?"; }
run "" -1 --quiet-build=y qp/q
cat >> /etc/portage/make.conf <<'EOF'
MAKEOPTS="-j5"
BINPKG_FORMAT="gpkg"
BINPKG_COMPRESS="zstd"
EOF
cat > /usr/local/bin/zstd <<'EOF'
#!/bin/sh
echo "zstd $*" >> /tmp/zstd.argv
exec /usr/bin/zstd "$@"
EOF
chmod +x /usr/local/bin/zstd
run "unmerge-backup" -C qp/q
tail -3 /tmp/emerge.log
cat /tmp/zstd.argv 2>/dev/null || echo "<no zstd call>"
find /var/cache/binpkgs -path "*qp*" | sort; grep -E "^(CPV|PATH|BUILD_ID)" /var/cache/binpkgs/Packages 2>/dev/null
