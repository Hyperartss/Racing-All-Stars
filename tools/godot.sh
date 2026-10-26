#!/usr/bin/env bash
# Local helper: run Godot 4.7.2 headless or with a virtual display for renders.
G=${GODOT:-godot}
if [ "$1" = "--render" ]; then shift; exec xvfb-run -a "$G" --rendering-driver opengl3 --path "$(dirname "$0")/.." "$@"; fi
exec "$G" --headless --path "$(dirname "$0")/.." "$@"
