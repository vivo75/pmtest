EAPI=8
DESCRIPTION="fixture package: real inherit()/PORTAGE_ECLASS_LOCATIONS resolution"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

inherit pilotcheck

src_install() {
	pilotcheck_hello > "${T}/eclass-marker.txt" || die
}
