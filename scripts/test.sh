#!/usr/bin/env bash
# Run the whole test suite headless. Usage: scripts/test.sh [extra nim flags, e.g. -d:release]
set -u
cd "$(dirname "$0")/.."
export SDL_VIDEO_DRIVER=offscreen SDL_RENDER_DRIVER=software
mkdir -p build/tests
fail=0
for f in tests/t*.nim; do
  name=$(basename "$f" .nim)
  [ "$name" = tformmacro_errors ] && continue   # compile-error tests, run separately
  if nim c --hints:off --warnings:off "$@" --outdir:build/tests -r "$f" > "build/tests/$name.log" 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name  (see build/tests/$name.log)"; fail=1
  fi
done
# compile-error tests
if nim c --hints:off --warnings:off "$@" --outdir:build/tests -r tests/tformmacro_errors.nim > build/tests/tformmacro_errors.log 2>&1; then
  echo "ok    tformmacro_errors"
else
  echo "FAIL  tformmacro_errors  (see build/tests/tformmacro_errors.log)"; fail=1
fi
exit $fail
