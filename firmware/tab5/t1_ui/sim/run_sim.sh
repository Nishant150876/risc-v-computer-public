#!/usr/bin/env bash
# Builds and runs the T1 desktop checks: state/backend unit tests, then the
# LVGL simulator in landscape (1280x720) and portrait (720x1280).
# Screenshots go to build-sim/shots/ (PNG if Python Pillow is installed).
# Works on Linux or WSL with gcc, cmake and git.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${T1_SIM_BUILD_DIR:-$here/../build-sim}"
lvgl="${LVGL_DIR:-$build/lvgl}"
mkdir -p "$build/shots"

if [ ! -f "$lvgl/lvgl.h" ]; then
    git clone --depth 1 --branch v9.5.0 https://github.com/lvgl/lvgl.git "$lvgl"
fi

cmake -S "$here" -B "$build/cmake" -DLVGL_DIR="$lvgl" -DCMAKE_BUILD_TYPE=Debug > /dev/null
cmake --build "$build/cmake" -j"$(nproc)" > "$build/build.log" 2>&1 || { grep -E "error|warning" -A3 "$build/build.log" | head -80; exit 1; }

status=0
"$build/cmake/test_state" || status=1
"$build/cmake/test_link_device" || status=1
"$build/cmake/t1_sim" "$build/shots" || status=1
"$build/cmake/t1_sim" "$build/shots" --portrait || status=1
"$build/cmake/t1_sim" "$build/shots" --packet-fixture || status=1
"$build/cmake/t1_sim" "$build/shots" --portrait --packet-fixture || status=1

if python3 -c "import PIL" 2>/dev/null; then
    python3 - "$build/shots" <<'PY'
import pathlib, sys
from PIL import Image
for p in pathlib.Path(sys.argv[1]).glob("*.ppm"):
    Image.open(p).save(p.with_suffix(".png"))
    p.unlink()
PY
fi
echo "screenshots: $build/shots"
exit $status
