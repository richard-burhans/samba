# smart1-nss32

Local stopgap for a SmartOS zone (smart1) whose pkgsrc samba was upgraded
from 4.13 to 4.24 in the 64-bit tree only. The 32-bit nscd and nfsmapid
load a 32-bit 4.13 `nss_winbind` from `/opt/i386/opt/local/lib`, which
speaks winbind interface version 31 and refuses the 4.24 winbindd
(version 33), so AD users do not resolve and NFS id mapping fails.

`nss32.sh` builds a 32-bit `nss_winbind.so.1` from the Samba 4.24.1
release tarball (`nsswitch/wb_common.c`, `winbind_nss_linux.c`,
`winbind_nss_solaris.c`) with a minimal stand-in for `lib/replace`,
using the same feature defines Samba's configure sets on illumos.

    ./nss32.sh build        # download, verify, compile
    ./nss32.sh test [user]  # try it without installing
    ./nss32.sh install      # repoint nss_winbind.so.1, restart nscd/mapid
    ./nss32.sh rollback     # restore the previous module

Not part of Samba; not for upstream submission.
