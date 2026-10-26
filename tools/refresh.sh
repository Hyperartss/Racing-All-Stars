#!/usr/bin/env bash
# Refresh Godot's import + global class cache without opening the editor UI.
# Needed after adding or renaming any `class_name` script.
set -euo pipefail
GODOT=/tmp/opencode/Godot_v4.7.2-stable_linux.x86_64
PROJ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJ"
"$GODOT" --headless --path "$PROJ" --editor --quit-after 120 >/dev/null 2>&1 || true
echo "class cache refreshed"
