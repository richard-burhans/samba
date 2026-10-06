#!/bin/bash
#
# Build a 32-bit Samba 4.24 winbind NSS module for the 32-bit nscd and
# nfsmapid on a SmartOS zone whose 64-bit winbindd is 4.24 (winbind
# interface version 33). The 32-bit module in /opt/i386 is from 4.13
# (interface 31) and refuses to talk to it.
#
# Usage: nss32.sh build | test [user] | install | rollback
#
set -eu
PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/usr/sbin:/sbin

V=4.24.1
SHA512=419653355fd609443b1cd321986e7e83c6479a52d7a998e1197846cdb591305b1173b77022a65cf643c46a3a8810de05499a9eba903b839a87fac7a270ebc85f
URL=https://download.samba.org/pub/samba/stable/samba-$V.tar.gz
W=/var/tmp/nss32
OUT=$W/out
L32=/opt/i386/opt/local/lib
LINK=$L32/nss_winbind.so.1
NEW=$L32/nss_winbind-$V.so.1
SAVED=$W/saved-link-target

die() { echo "ERROR: $*" >&2; exit 1; }

build() {
	rm -rf $W/src $OUT
	mkdir -p $W/src/system $W/src/replace $OUT
	cd $W
	if [ ! -f samba-$V.tar.gz ]; then
		curl -fsSLO $URL
	fi
	got=$(digest -a sha512 samba-$V.tar.gz)
	[ "$got" = "$SHA512" ] || die "checksum mismatch for samba-$V.tar.gz"
	echo "checksum OK"

	gzip -dc samba-$V.tar.gz | (cd $W/src && tar -xf - \
	    samba-$V/nsswitch samba-$V/lib/util/dlinklist.h)
	mv $W/src/samba-$V/nsswitch $W/src/nsswitch
	mkdir -p $W/src/lib/util
	mv $W/src/samba-$V/lib/util/dlinklist.h $W/src/lib/util/
	rm -rf $W/src/samba-$V

	write_replace_h > $W/src/replace.h
	echo '#include "../replace.h"' > $W/src/replace/replace.h
	for h in select filesys network passwd; do
		echo '#include "replace.h"' > $W/src/system/$h.h
	done

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

write_replace_h() {
	cat <<'REPLACE_H'
/*
 * Minimal stand-in for Samba's lib/replace/replace.h, just enough to
 * build the winbind NSS client (wb_common.c, winbind_nss_linux.c,
 * winbind_nss_solaris.c) outside the Samba build system.
 */
#ifndef _MINI_REPLACE_H
#define _MINI_REPLACE_H

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/time.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <pwd.h>
#include <grp.h>
#include <pthread.h>

#define HAVE_PTHREAD 1
#define HAVE_PTHREAD_H 1

#ifndef _PUBLIC_
#define _PUBLIC_ __attribute__((visibility("default")))
#endif
#ifndef _PRIVATE_
#define _PRIVATE_ __attribute__((visibility("hidden")))
#endif
#ifndef _PUBLIC_ON_LINUX_
#define _PUBLIC_ON_LINUX_
#endif
#ifndef PRINTF_ATTRIBUTE
#define PRINTF_ATTRIBUTE(a, b) __attribute__((format(__printf__, a, b)))
#endif
#ifndef MIN
#define MIN(a, b) ((a) < (b) ? (a) : (b))
#endif
#ifndef MAX
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
#ifndef ZERO_STRUCT
#define ZERO_STRUCT(x) memset((char *)&(x), 0, sizeof(x))
#endif
#ifndef ZERO_STRUCTP
#define ZERO_STRUCTP(x) do { if ((x) != NULL) memset((char *)(x), 0, sizeof(*(x))); } while (0)
#endif
#ifndef discard_const
#define discard_const(ptr) ((void *)((uintptr_t)(ptr)))
#endif
#ifndef discard_const_p
#define discard_const_p(type, ptr) ((type *)discard_const(ptr))
#endif
#ifndef ARRAY_SIZE
#define ARRAY_SIZE(a) (sizeof(a) / sizeof(a[0]))
#endif

/*
 * Samba's replace.h probes for the cwrap test wrappers; a production
 * build never runs under them.
 */
static inline bool nss_wrapper_enabled(void) { return false; }
static inline bool uid_wrapper_enabled(void) { return false; }

#endif /* _MINI_REPLACE_H */
REPLACE_H
}

case "${1:-}" in
build) build ;;
test) test_module "${2:-}" ;;
install) install_module ;;
rollback) rollback ;;
*) echo "usage: $0 build | test [user] | install | rollback" >&2; exit 2 ;;
esac
