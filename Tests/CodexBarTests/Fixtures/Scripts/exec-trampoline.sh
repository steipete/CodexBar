#!/bin/sh
# Execution target for tests that need a fake CLI on disk.
#
# Tests symlink this file into a temporary directory and write the real script
# body beside the symlink as "<name>.sh". Only this checked-in file is ever
# handed to execve, so a fork in a concurrently running test cannot inherit a
# write descriptor on the target and fail the launch with ETXTBSY.
#
# "$0" is the symlink path the caller executed, not this file, on both Linux
# and macOS. That is what lets "$0.sh" resolve per test.
exec /bin/sh "$0.sh" "$@"
