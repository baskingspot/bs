#!/bin/sh
# A C compiler for bs's native libc detection: it lists its include
# search path as GCC's `-E -Wp,-v` does, with a stand-in libc last, and
# names the runtime objects upstream's detection asks for.
case "$1" in
-print-file-name=*) echo "/nonexistent/lib/${1#-print-file-name=}" ;;
*) printf '#include <...> search starts here:\n /nonexistent/include\n test/link_input/tc_libc/inc\nEnd of search list.\n' >&2 ;;
esac
