#!/usr/bin/env bash
# Run the whole test suite headless.
# Usage: scripts/test.sh [nim flags, e.g. -d:release] [test names, e.g. tbutton]
# Arguments starting with "-" are nim flags; the others select tests (with or
# without the .nim suffix). Without names every test runs.
# Each run builds into its own folder (build/tests/run-<pid>) with its own
# compiler cache, so two runs at the same time cannot clash. Logs of the last
# run are kept there when something fails; the folder is removed when all pass.
set -u
cd "$(dirname "$0")/.."
export SDL_VIDEO_DRIVER="${SDL_VIDEO_DRIVER:-offscreen}" SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-software}"
out="build/tests/run-$$"
mkdir -p "$out"
nimflags=(); names=()
for a in "$@"; do
  case "$a" in -*) nimflags+=("$a");; *) names+=("$(basename "$a" .nim)");; esac
done
flags=(--hints:off --warnings:off ${nimflags[@]+"${nimflags[@]}"} --outdir:"$out" --nimcache:"$out/cache")
fail=0
run() {   # run <test file>
  local name; name=$(basename "$1" .nim)
  if nim c "${flags[@]}" -r "$1" > "$out/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name  (see $out/$name.log)"; fail=1
  fi
}
wanted() {   # wanted <name>: selected, or nothing was selected
  [ ${#names[@]} = 0 ] && return 0
  local n; for n in "${names[@]}"; do [ "$n" = "$1" ] && return 0; done
  return 1
}
for f in tests/t*.nim; do
  name=$(basename "$f" .nim)
  [ "$name" = tformmacro_errors ] && continue    # last: it builds its own cases
  wanted "$name" && run "$f"
done
wanted tformmacro_errors && run tests/tformmacro_errors.nim
if [ $fail = 0 ]; then rm -rf "$out"; fi
exit $fail
