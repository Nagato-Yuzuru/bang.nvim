#!/bin/sh
# Stand-in for 'shell' used by the D6.1 test.
#
# Records, in $BANG_TEST_LOG, every argument it was invoked with and the exact
# bytes it received on stdin, then writes one fixed line to stdout so the
# write-back path still runs. The log format is:
#
#   cwd<TAB><working directory>
#   argv<TAB><argument>      (one line per argument, in order)
#   --stdin--
#   <stdin, byte for byte, to the end of the file>

log=${BANG_TEST_LOG:-/dev/null}
: >"$log"
printf 'cwd\t%s\n' "$(pwd -P)" >>"$log"
for arg in "$@"; do
  printf 'argv\t%s\n' "$arg" >>"$log"
done
printf -- '--stdin--\n' >>"$log"
cat >>"$log"
printf 'REPLACED\n'
