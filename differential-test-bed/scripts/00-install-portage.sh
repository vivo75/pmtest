#!/bin/bash
# The container image ships STABLE portage, but portuale
# is ported against ~amd64 =sys-apps/portage-3.0.83-r1. Install that first
# so every later script's Portage `emerge` matches the version whose source
# portuale mirrors.
export ACCEPT_KEYWORDS=~amd64
/usr/bin/emerge -tv =sys-apps/portage-3.0.83-r1
