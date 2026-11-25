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

status=0
for f in "$@"; do
    if reason=$(validate "$f"); then
        echo "OK      $f"
    else
        echo "INVALID $f: $reason"
        status=1
    fi
done
exit "$status"
