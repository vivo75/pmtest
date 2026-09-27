EAPI=8
DESCRIPTION="fixture package: a real consumer still linked against libsonamebump.so.1 (backlog #178)"
SLOT="0"
KEYWORDS="amd64"
S="${WORKDIR}"

src_compile() {
	# A throwaway same-sonamed copy to link against (like
	# consumepreservetest): no build-time dependency on the installed
	# library, but a real DT_NEEDED of libsonamebump.so.1 baked in.
	echo 'int sonamebump_value(void) { return 1; }' > "${T}/sonamebump.c" || die
	gcc -shared -fPIC -Wl,-soname,libsonamebump.so.1 \
		-o "${T}"/libsonamebump.so.1 "${T}"/sonamebump.c || die
	ln -sf libsonamebump.so.1 "${T}"/libsonamebump.so || die
	echo 'extern int sonamebump_value(void); int main(void) { return sonamebump_value() == 1 ? 0 : 1; }' \
		> "${T}"/consumesonamebump.c || die
	gcc -o "${T}"/consumesonamebump "${T}"/consumesonamebump.c -L"${T}" -lsonamebump || die
}

src_install() {
	exeinto /usr/bin
	doexe "${T}"/consumesonamebump
}
