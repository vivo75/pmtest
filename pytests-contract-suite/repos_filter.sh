#!/bin/bash
# Backlog #564: deterministic `repos.conf` filter for the contract suite.
#
# Portage merges the installed system repos.conf
# (`/usr/share/portage/config/repos.conf`, declaring the host `gentoo`
# repo) with every run's `$PORTAGE_CONFIGROOT` one
# (`repository/config.py::load_repository_config`), so without this
# filter every suite run's repo set depends on the host: ~19k host cps
# join fixture runs where the host tree exists, and a `Section 'gentoo'
# ... nonexistent directory` error line prints where it does not.
#
# Usage: repos_filter.sh <real-binary> <argv0> <args...>
#
# Hides the host file behind a per-invocation mount-namespace bind of
# `$PMTEST_REPOS_FILTER_SRC` (a comments-only fixture file written by
# conftest.py: neither manager sees the host `gentoo`). The outer user
# namespace allows the bind; the nested one restores the real uid (file
# ownership and the privilege gate behave as unfiltered) with the portage
# group as the primary gid (ebuild phases `chgrp` to it; see below). The
# bind lives in a private mount namespace (`--propagation private`), so
# parallel xdist workers do not see each other's mounts. The real binary
# is exec'd with `<argv0>` (the applet launcher's path) via `exec -a`,
# preserving the argv[0]-dispatch the suite's launchers rely on.
#
# The plain `unshare --map-current-user` + mount fails in this LXC
# (EPERM), hence the nesting. Files owned by other uids show as
# `nobody` inside (irrelevant for this non-root suite).
#
# Bypass: `PMTEST_REPOS_FILTER=off` execs the real binary directly (the
# sudo/real-root tests use this; `sudo` does not work inside the user
# namespace). When the host file is absent there is nothing to hide and
# the real binary runs directly too.
set -u
SELF=$0

if [ "${1:-}" = "--inner" ]; then
    # Running as root in the outer namespace: bind, then re-exec into
    # the id-restoring namespace.
    SRC=$2; U=$3; G=$4; NAME=$5; REAL=$6; shift 6
    /usr/bin/mount --bind "$SRC" /usr/share/portage/config/repos.conf || exit 99
    exec /usr/bin/unshare --user --map-user="$U" --map-group="$G" -- \
        "$SELF" --exec "$NAME" "$REAL" "$@"
fi

if [ "${1:-}" = "--exec" ]; then
    # Final stage, ids restored: exec with the launcher's argv[0]. The
    # shell resets `$PWD` at startup when it names a nonexistent dir;
    # restore the caller's value (carried in `_PMTEST_SAVED_PWD` by the
    # Python launcher, which preserves the environment byte for byte)
    # and drop the carrier so the child's environment is unchanged.
    NAME=$2; REAL=$3; shift 3
    export PWD="${_PMTEST_SAVED_PWD:-$PWD}"; unset _PMTEST_SAVED_PWD
    exec -a "$NAME" "$REAL" "$@"
fi

REAL=${1:?usage: repos_filter.sh <real-binary> <argv0> <args...>}; NAME=$2; shift 2
if [ "${PMTEST_REPOS_FILTER:-on}" = "off" ]; then
    export PWD="${_PMTEST_SAVED_PWD:-$PWD}"; unset _PMTEST_SAVED_PWD
    exec -a "$NAME" "$REAL" "$@"
fi
if [ ! -e /usr/share/portage/config/repos.conf ]; then
    export PWD="${_PMTEST_SAVED_PWD:-$PWD}"; unset _PMTEST_SAVED_PWD
    exec -a "$NAME" "$REAL" "$@"
fi
SRC=${PMTEST_REPOS_FILTER_SRC:?repos_filter.sh: PMTEST_REPOS_FILTER_SRC is not set}
ME_U=$(/usr/bin/id -u); ME_G=$(/usr/bin/id -g)
# Ebuild phases `chgrp` to the portage group (Portage's own `ebuild.sh`
# helpers do); inside an unprivileged user namespace an unmapped target
# gid fails with EINVAL even though the phase continues, polluting
# exact-output pins. Map the inner primary group to the portage gid so
# the call succeeds silently exactly like outside, keeping the real uid
# (file ownership and the privilege gate behave as unfiltered). Note the
# mapping is outer-current-gid -> portage-gid, so host-side the files
# stay in the caller's own group (no host-visible ownership change);
# only the in-namespace view -- which is what the phases see -- carries
# `portage`. Falls back to the current gid where no portage group
# exists -- there the unfiltered `chgrp` fails identically, so parity
# holds either way.
ME_GIDMAP=$(/usr/bin/getent group portage | cut -d: -f3)
ME_GIDMAP=${ME_GIDMAP:-$ME_G}
exec /usr/bin/unshare -r --mount --propagation private -- \
    "$SELF" --inner "$SRC" "$ME_U" "$ME_GIDMAP" "$NAME" "$REAL" "$@"
