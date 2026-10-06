#!/bin/bash
#
# Build a 32-bit Samba 4.24 winbind NSS module for the 32-bit nscd and
# nfsmapid on a SmartOS zone whose 64-bit winbindd is 4.24 (winbind
# interface version 33). The 32-bit module in /opt/i386 is from 4.13
# (interface 31) and refuses to talk to it.
#
# Offline: expects the sources unpacked in /var/tmp/nss32/src.
#
# Usage: nss32.sh build | test [user] | install | rollback
#
set -eu
PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/usr/sbin:/sbin

V=4.24.1
W=/var/tmp/nss32
OUT=$W/out
L32=/opt/i386/opt/local/lib
LINK=$L32/nss_winbind.so.1
NEW=$L32/nss_winbind-$V.so.1
SAVED=$W/saved-link-target

die() { echo "ERROR: $*" >&2; exit 1; }

build() {
	[ -f $W/src/nsswitch/wb_common.c ] ||
	    die "sources not found in $W/src (unpack the bundle first)"
	rm -rf $OUT
	mkdir -p $OUT
	(cd $W/src && digest -a sha256 -v $(find . -type f | sort)) \
	    > $W/src-sha256.txt
	echo "source checksums written to $W/src-sha256.txt"

	sockdir=$(testparm -s --parameter-name='winbindd socket directory' \
	    2>/dev/null)
	[ -n "$sockdir" ] || die "could not read winbindd socket directory"
	[ -S "$sockdir/pipe" ] || die "no winbindd socket at $sockdir/pipe"
	echo "winbindd socket directory: $sockdir"

	cd $W/src
	gcc -m32 -O2 -fPIC -shared -Wall \
	    -Werror=implicit-function-declaration -Werror=int-conversion \
	    -I. -Insswitch \
	    -D_REENTRANT -D__EXTENSIONS__ \
	    -DHAVE_NSS_COMMON_H -DHAVE_NSSWITCH_H \
	    -DHAVE_UNIXSOCKET -DHAVE_DESTRUCTOR_ATTRIBUTE \
	    -DHAVE_PASSWD_PW_COMMENT -DHAVE_PASSWD_PW_AGE \
	    -DHAVE_NSS_XBYY_KEY_IPNODE \
	    -DWINBINDD_SOCKET_DIR="\"$sockdir\"" \
	    -Wl,-h,nss_winbind.so.1 \
	    -o $OUT/nss_winbind.so.1 \
	    nsswitch/wb_common.c \
	    nsswitch/winbind_nss_linux.c \
	    nsswitch/winbind_nss_solaris.c \
	    -lsocket -lnsl -lpthread

	file $OUT/nss_winbind.so.1
	for s in _nss_winbind_passwd_constr _nss_winbind_group_constr \
	    winbindd_request_response; do
		nm -D $OUT/nss_winbind.so.1 | grep -q " T $s\$" ||
		    die "symbol $s missing from module"
	done
	echo "unresolved symbols (should all be from libc/libsocket/libnsl):"
	ldd -r $OUT/nss_winbind.so.1 || true
	echo "BUILD OK: $OUT/nss_winbind.so.1"
}

nscd_off() { svcadm disable -t svc:/system/name-service-cache:default; sleep 2; }
nscd_on() { svcadm enable svc:/system/name-service-cache:default; sleep 2; }

test_module() {
	u=${1:-rcb112}
	[ -f $OUT/nss_winbind.so.1 ] || die "run build first"
	echo "== old module (via nscd)"
	/usr/bin/getent passwd "$u" || echo "(not found)"
	echo "== new module, 32-bit getent/id, nscd briefly off"
	trap nscd_on EXIT
	nscd_off
	LD_LIBRARY_PATH_32=$OUT /usr/bin/getent passwd "$u" ||
	    echo "(not found)"
	LD_LIBRARY_PATH_32=$OUT /usr/bin/id "$u" || true
	nscd_on
	trap - EXIT
	svcs svc:/system/name-service-cache:default
}

install_module() {
	[ -f $OUT/nss_winbind.so.1 ] || die "run build first"
	[ -L $LINK ] || die "$LINK is not a symlink; not touching it"
	if [ ! -f $SAVED ]; then
		readlink $LINK > $SAVED
	fi
	echo "old $LINK -> $(cat $SAVED)"
	cp $OUT/nss_winbind.so.1 $NEW
	chmod 755 $NEW
	ln -sf "$(basename $NEW)" $LINK
	echo "new $LINK -> $(readlink $LINK)"
	svcadm restart svc:/system/name-service-cache:default
	svcadm restart svc:/network/nfs/mapid:default
	sleep 3
	svcs svc:/system/name-service-cache:default \
	    svc:/network/nfs/mapid:default
	/usr/bin/getent passwd rcb112 || echo "(not found)"
	/usr/bin/id rcb112 || true
}

rollback() {
	[ -f $SAVED ] || die "nothing saved; was install run?"
	ln -sf "$(cat $SAVED)" $LINK
	echo "restored $LINK -> $(readlink $LINK)"
	svcadm restart svc:/system/name-service-cache:default
	svcadm restart svc:/network/nfs/mapid:default
}

case "${1:-}" in
build) build ;;
test) test_module "${2:-}" ;;
install) install_module ;;
rollback) rollback ;;
*) echo "usage: $0 build | test [user] | install | rollback" >&2; exit 2 ;;
esac
