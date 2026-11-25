#!/bin/sh
# Backfill OpenMetrics files into Prometheus.
#
# Runs inside the `importer` compose service (prom/prometheus image, as root).
# See README.md "Importing data".

set -u

# validate FILE
# Pre-checks promtool does not do itself. Prints the reason and returns
# non-zero when the file must be rejected:
#   - the last non-empty line is not "# EOF";
#   - a sample timestamp looks like milliseconds (>= 1e11) or lies more than
#     one day in the future (promtool would silently store it at that date).
validate() {
    awk -v now="$(date +%s)" '
        { sub(/\r$/, "") }
        /[^[:space:]]/ { last = $0 }
        /^#/ || !/[^[:space:]]/ { next }
        {
            line = $0
            sub(/ # \{.*$/, "", line)      # drop exemplar
            if (!sub(/^[^{ ]*\{.*\}/, "", line))  # drop name + label set...
                sub(/^[^ ]+/, "", line)            # ...or the bare name
            n = split(line, f, " ")                # left: value [timestamp]
            if (n < 2) next                        # no timestamp: left to promtool
            ts = f[n] + 0
            if (ts >= 1e11) {
                printf "line %d: timestamp %s looks like milliseconds; timestamps must be Unix seconds\n", NR, f[n]
                bad = 1; exit
            }
            if (ts > now + 86400) {
                printf "line %d: timestamp %s is more than one day in the future\n", NR, f[n]
                bad = 1; exit
            }
        }
        END {
            if (bad) exit 1
            sub(/[[:space:]]+$/, "", last)
            if (last != "# EOF") { print "missing \"# EOF\" as the last line"; exit 1 }
        }
    ' "$1"
}

IMPORT_DIR=${IMPORT_DIR:-/import}
DATA_DIR=${DATA_DIR:-/prometheus}
STAGING="$DATA_DIR/.staging"   # not a ULID: Prometheus ignores it
PROM_OWNER=65534:65534         # "nobody", the user the server runs as

# archive FILE DEST_DIR
# Moves FILE into DEST_DIR without overwriting an earlier file of the same name.
archive() {
    name=$(basename "$1")
    target="$2/$name"
    [ -e "$target" ] && target="$2/$(date +%Y%m%dT%H%M%S)-$name"
    mv "$1" "$target"
}

# import_file FILE RUN_DIR
# Converts FILE into blocks under RUN_DIR, then hands them to Prometheus.
# Each block appears in DATA_DIR through a rename within the same volume,
# so Prometheus never sees a half-written block.
import_file() {
    validate "$1" || return 1
    promtool tsdb create-blocks-from openmetrics "$1" "$2" >/dev/null || return 1
    chown -R "$PROM_OWNER" "$2" || return 1
    for block in "$2"/*/; do
        [ -d "$block" ] || continue
        mv "${block%/}" "$DATA_DIR/" || return 1
    done
}

# Leftovers from an interrupted run were never exposed: just drop them.
rm -rf "$STAGING"
mkdir -p "$STAGING"

# processed/ and failed/ belong to the owner of the import folder (the host user).
owner=$(stat -c %u:%g "$IMPORT_DIR")
for d in processed failed; do
    if [ ! -d "$IMPORT_DIR/$d" ]; then
        mkdir -p "$IMPORT_DIR/$d" && chown "$owner" "$IMPORT_DIR/$d"
    fi
done

found=0
imported=0
failed=0
for f in "$IMPORT_DIR"/*.om; do
    [ -f "$f" ] || continue
    found=$((found + 1))
    run="$STAGING/run-$$-$found"
    echo "Importing $(basename "$f")..."
    if err=$(import_file "$f" "$run" 2>&1); then
        archive "$f" "$IMPORT_DIR/processed"
        imported=$((imported + 1))
        echo "  ok -> processed/"
    else
        archive "$f" "$IMPORT_DIR/failed"
        failed=$((failed + 1))
        echo "  FAILED -> failed/" >&2
        printf '%s\n' "$err" | sed 's/^/    /' >&2
    fi
    rm -rf "$run"
done
rm -rf "$STAGING"

if [ "$found" -eq 0 ]; then
    echo "Nothing to import: no .om files in $IMPORT_DIR."
    exit 0
fi

echo "Done: $imported imported, $failed failed."
if [ "$imported" -gt 0 ]; then
    echo "Imported data becomes queryable within about a minute."
fi
[ "$failed" -eq 0 ]
