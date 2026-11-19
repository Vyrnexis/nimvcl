#!/usr/bin/env bash
# Run the whole test suite headless.
# Usage: scripts/test.sh [extra nim flags, e.g. -d:release]
# Each run builds into its own folder (build/tests/run-<pid>) with its own
# compiler cache, so two runs at the same time cannot clash. Logs of the last
# run are kept there when something fails; the folder is removed when all pass.
set -u
cd "$(dirname "$0")/.."
export SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-offscreen}" SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
out="build/tests/run-$$"
mkdir -p "$out"
flags=(--hints:off --warnings:off "$@" --outdir:"$out" --nimcache:"$out/cache")
fail=0
run() {   # run <test file>
  local name; name=$(basename "$1" .nim)
  if nim c "${flags[@]}" -r "$1" > "$out/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name  (see $out/$name.log)"; fail=1
  fi
}
for f in tests/t*.nim; do
  [ "$(basename "$f")" = tformmacro_errors.nim ] && continue
  run "$f"
done
run tests/tformmacro_errors.nim   # compile-error tests (they build their own cases)
if [ $fail = 0 ]; then rm -rf "$out"; fi
exit $fail
