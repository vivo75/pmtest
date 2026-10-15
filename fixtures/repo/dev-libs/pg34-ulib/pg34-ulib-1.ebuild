EAPI=8
DESCRIPTION="fixture package: #34 S3 deep-USE installed dep (installed USE empty, IUSE x, optional dep on pg34-uextra, package.use enables x); regressed = -pvuD plans pg34-uextra from config USE instead of the vdb USE"
SLOT="0"
KEYWORDS="amd64"
IUSE="x"
RDEPEND="x? ( dev-libs/pg34-uextra )"
