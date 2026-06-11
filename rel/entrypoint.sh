#!/bin/sh
set -e

# Run pending Ecto migrations (creates the SQLite DB on first boot), then exec
# the release with whatever command was passed (defaults to `start`).
/app/bin/chronodivexd eval "Chronodivexd.Release.migrate()"

exec /app/bin/chronodivexd "$@"
