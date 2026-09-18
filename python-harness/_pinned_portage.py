"""Put the *pinned* real-Portage checkout on `sys.path`, or refuse to run.

Every harness in this directory is the reference side of a primitive
contract: its answers are real Portage's answers, and which Portage
answered is part of the result. The checkout is `3rdparty/portage`
(a symlink to the PM tree's sibling checkout, pinned in
`3rdparty/repos.toml`), overridable with `$PORTUALE_PORTAGE_CHECKOUT`.

If that directory is absent, `import portage` finds whatever Portage the
host happens to have installed and the whole suite silently grades
against an unpinned reference -- the numbers stay green while meaning
something else. So a missing checkout is a hard error here, never a
fallback.
"""

import os
import sys

CHECKOUT_ENV = "PORTUALE_PORTAGE_CHECKOUT"


def checkout_dir():
    """The Portage checkout this harness must import from."""
    override = os.environ.get(CHECKOUT_ENV)
    if override:
        return os.path.abspath(override)
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.abspath(os.path.join(here, "..", "3rdparty", "portage"))


def use_pinned_portage():
    """Prepend the pinned checkout's `lib/`; exit 2 if it is not there."""
    root = checkout_dir()
    lib = os.path.join(root, "lib")
    if not os.path.isdir(os.path.join(lib, "portage")):
        sys.exit(
            f"!!! {os.path.basename(sys.argv[0])}: no Portage checkout at {root}\n"
            f"    The Python harnesses are the pinned reference: refusing to fall "
            f"back to the host's installed portage.\n"
            f"    Bootstrap `3rdparty/` (see README.md) or point {CHECKOUT_ENV} at "
            f"the checkout."
        )
    sys.path.insert(0, lib)
