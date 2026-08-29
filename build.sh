#!/bin/sh
# Builds spoticyclint. The generated Wayland bindings and the compiled SPIR-V
# are both committed, so a plain `odin build src -out:spoticyclint` works on its
# own; this script only regenerates them when the tools are around.
set -e
cd "$(dirname "$0")"

WL_XML=/usr/share/wayland/wayland.xml
XDG_XML=/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml
DEC_XML=/usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml

if [ -f "$WL_XML" ] && command -v python3 >/dev/null; then
	python3 tools/wl_gen.py src/wayland/protocol.odin "$WL_XML" "$XDG_XML" "$DEC_XML"
fi

if command -v glslc >/dev/null; then
	glslc -O -fshader-stage=vert src/shaders/ui.vert -o src/shaders/ui.vert.spv
	glslc -O -fshader-stage=frag src/shaders/ui.frag -o src/shaders/ui.frag.spv
fi

odin build src -out:spoticyclint "$@"
echo "built ./spoticyclint"
