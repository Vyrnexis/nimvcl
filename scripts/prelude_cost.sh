#!/usr/bin/env bash
# Front-end cost of `import nimvcl/prelude`: `nim check` of a tiny program,
# compared with core only and with the whole umbrella (best of N runs, in ms).
# Usage: scripts/prelude_cost.sh [runs]
set -u
cd "$(dirname "$0")/.."
runs=${1:-3}
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
printf 'import nimvcl/core/[control, form, application]\nimport nimvcl/controls/common\nApplication.init()\n' > "$dir/core.nim"
printf 'import nimvcl/prelude\nApplication.init()\n' > "$dir/prelude.nim"
printf 'import nimvcl\nApplication.init()\n' > "$dir/umbrella.nim"
for n in core prelude umbrella; do
  best=999999
  for _ in $(seq "$runs"); do
    s=$(date +%s%N)
    nim check --hints:off --warnings:off --path:src --nimcache:"$dir/nc" "$dir/$n.nim" > /dev/null 2>&1
    e=$(date +%s%N)
    t=$(( (e - s) / 1000000 ))
    [ "$t" -lt "$best" ] && best=$t
  done
  echo "$n: ${best} ms"
done
