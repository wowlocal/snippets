#!/bin/bash
#
# Measures what concurrent writers actually do to the snippet library.
#
# This exists because the claim "unlocked writers lose most of their edits" is the
# entire justification for the locking work, and a number in a commit message that
# nobody can reproduce is not evidence. Every figure quoted in docs/cloud-sync.md
# comes from running this.
#
#   Tests/concurrency-harness.sh <path-to-snippets-cli> [writers]
#
# The CLI under test must honour SNIPPETS_SUPPORT_DIR (added for exactly this
# reason). It is not optional: an earlier version of this experiment tried to
# isolate itself with HOME, which FileManager ignores for the Application Support
# directory, and wrote sixty rows into a live library.

set -u

CLI="${1:-}"
WRITERS="${2:-60}"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/snippets-concurrency.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

if [ -z "$CLI" ] || [ ! -x "$CLI" ]; then
    echo "usage: $0 <path-to-snippets-cli> [writers]" >&2
    echo "  e.g. $0 \"\$(find ~/Library/Developer/Xcode/DerivedData -name snippets-cli -type f | head -1)\"" >&2
    exit 2
fi

# Refuse to run if the CLI ignores the override, rather than discovering that by
# corrupting the real library. This guard is the whole reason the harness is safe.
probe="$SCRATCH/probe"
mkdir -p "$probe"
SNIPPETS_SUPPORT_DIR="$probe" "$CLI" add --keyword probe --name probe --content x >/dev/null 2>&1
if [ ! -f "$probe/snippets.json" ]; then
    echo "ABORT: $CLI did not honour SNIPPETS_SUPPORT_DIR — it would write to the real library." >&2
    exit 1
fi

count() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1]))))" "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------- reference points
#
# Two Python writers stand in for "the shape of the algorithm", so the harness can
# show the unlocked baseline without needing a build of the pre-fix CLI. The gap
# between them is the effect being measured; the real CLI run below is the claim
# that actually matters.

cat > "$SCRATCH/unlocked.py" <<'PY'
import json, sys, os, time
p, i, gap = sys.argv[1], sys.argv[2], float(sys.argv[3])
d = json.load(open(p))
time.sleep(gap)                              # decode + edit + encode window
d.insert(0, {"i": i})
tmp = p + "." + i
open(tmp, "w").write(json.dumps(d))
os.replace(tmp, p)                           # atomic rename, exactly like the old code
PY

cat > "$SCRATCH/locked.py" <<'PY'
import json, sys, os, time, fcntl
p, i, gap, lock = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
fd = os.open(lock, os.O_RDONLY | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
try:
    d = json.load(open(p)); time.sleep(gap)
    d.insert(0, {"i": i})
    tmp = p + "." + i; open(tmp, "w").write(json.dumps(d)); os.replace(tmp, p)
finally:
    fcntl.flock(fd, fcntl.LOCK_UN); os.close(fd)
PY

echo
echo "== algorithm baseline: $WRITERS concurrent writers, varying read-to-write gap =="
printf '%-10s %-26s %-26s\n' "gap" "unlocked" "flock"
for GAP in 0.005 0.010 0.020; do
    d="$SCRATCH/u"; rm -rf "$d"; mkdir -p "$d"; echo '[]' > "$d/snippets.json"
    for i in $(seq 1 "$WRITERS"); do python3 "$SCRATCH/unlocked.py" "$d/snippets.json" "$i" "$GAP" & done; wait
    u=$(count "$d/snippets.json")

    d="$SCRATCH/l"; rm -rf "$d"; mkdir -p "$d"; echo '[]' > "$d/snippets.json"
    for i in $(seq 1 "$WRITERS"); do python3 "$SCRATCH/locked.py" "$d/snippets.json" "$i" "$GAP" "$d/lock" & done; wait
    l=$(count "$d/snippets.json")

    printf '%-10s %-26s %-26s\n' "${GAP}s" "$u/$WRITERS kept" "$l/$WRITERS kept"
done

# ---------------------------------------------------------------- the real binary

echo
echo "== snippets-cli: $WRITERS concurrent \`add\` =="
d="$SCRATCH/cli"; mkdir -p "$d"
errs="$SCRATCH/cli.err"; : > "$errs"
for i in $(seq 1 "$WRITERS"); do
    SNIPPETS_SUPPORT_DIR="$d" "$CLI" add --keyword "kw$i" --name "S$i" --content "b$i" \
        >/dev/null 2>>"$errs" &
done; wait
printf '   kept %s/%s   stderr lines: %s\n' "$(count "$d/snippets.json")" "$WRITERS" "$(wc -l < "$errs" | tr -d ' ')"

echo
echo "== snippets-cli: $WRITERS concurrent \`update --add-tags\` on ONE record =="
d="$SCRATCH/upd"; mkdir -p "$d"
SNIPPETS_SUPPORT_DIR="$d" "$CLI" add --keyword target --name T --content x >/dev/null 2>&1
for i in $(seq 1 "$WRITERS"); do
    SNIPPETS_SUPPORT_DIR="$d" "$CLI" update target --add-tags "t$i" >/dev/null 2>&1 &
done; wait
printf '   tags landed: %s/%s\n' \
    "$(python3 -c "import json;d=json.load(open('$d/snippets.json'));print(len(d[0]['tags']))" 2>/dev/null || echo 0)" \
    "$WRITERS"

echo
echo "== snippets-cli: $WRITERS concurrent \`add\` of the SAME keyword (exactly 1 must win) =="
d="$SCRATCH/dup"; mkdir -p "$d"
for i in $(seq 1 "$WRITERS"); do
    SNIPPETS_SUPPORT_DIR="$d" "$CLI" add --keyword same --name "S$i" --content "b$i" >/dev/null 2>&1 &
done; wait
printf '   records with keyword \"same\": %s (expected 1)\n' "$(count "$d/snippets.json")"

# ---------------------------------------------------------------- the lock's own inode
#
# flock attaches to an inode, not a path. If the lock file is replaced underneath
# the writers — a folder restore, a file-syncing tool, an over-eager cleanup — each
# process ends up holding a lock on a different inode and mutual exclusion silently
# evaporates, with a success receipt for every lost write. This is the regression
# test for that.

echo
echo "== snippets-cli: $WRITERS concurrent \`add\` while the lock file is replaced =="
d="$SCRATCH/relock"; mkdir -p "$d/Sync"
SNIPPETS_SUPPORT_DIR="$d" "$CLI" add --keyword seed --name seed --content x >/dev/null 2>&1
( for _ in $(seq 1 400); do rm -f "$d/Sync/library.lock"; sleep 0.005; done ) &
CHURN=$!
for i in $(seq 1 "$WRITERS"); do
    SNIPPETS_SUPPORT_DIR="$d" "$CLI" add --keyword "kw$i" --name "S$i" --content "b$i" >/dev/null 2>&1 &
done; wait
kill "$CHURN" 2>/dev/null; wait "$CHURN" 2>/dev/null
kept=$(count "$d/snippets.json")
printf '   kept %s/%s (seed + writers = %s expected)\n' "$kept" "$WRITERS" "$((WRITERS + 1))"
[ "$kept" -eq "$((WRITERS + 1))" ] \
    && echo "   PASS — the lock survives its file being replaced" \
    || echo "   FAIL — writes lost; acquire() is not revalidating the locked inode"
echo
