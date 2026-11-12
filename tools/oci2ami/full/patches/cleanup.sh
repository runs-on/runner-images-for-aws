# journald does not run in a build.
edit 's/^\( *\)journalctl --rotate$/\1journalctl --rotate || true/' 'journalctl --rotate || true'
edit 's/^\( *\)journalctl --vacuum-time=1s$/\1journalctl --vacuum-time=1s || true/' 'journalctl --vacuum-time=1s || true'
