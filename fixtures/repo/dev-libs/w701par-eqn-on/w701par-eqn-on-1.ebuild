EAPI=8
DESCRIPTION="fixture package (backlog #701 e): asks for the children with [!w701flag=] while its own w701flag is ON"
SLOT="0"
KEYWORDS="amd64"
IUSE="+w701flag"
RDEPEND="dev-libs/w701flagon[!w701flag=] dev-libs/w701flagoff[!w701flag=]"
