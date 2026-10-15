EAPI=8
DESCRIPTION="fixture package: #34 S5 G2 round 2 taken-branch parent (not installed; the || takes installed pg34-zlib[mz], whose USE the installed instance does not satisfy); regressed = skipping all || groups drops the R zlib row"
SLOT="0"
KEYWORDS="amd64"
RDEPEND="|| ( dev-libs/pg34-zlib[mz] dev-libs/pg34-zalt )"
