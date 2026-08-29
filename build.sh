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

odin build src -out:spoticyclint ${BUILD_FLAGS:-}
echo "built ./spoticyclint"

# `./build.sh --install` puts a launcher entry and icon in the user's session.
case " $* " in
	*" --install "*)
		apps="$HOME/.local/share/applications"
		icons="$HOME/.local/share/icons/hicolor/scalable/apps"
		mkdir -p "$apps" "$icons"
		sed "s|@BINARY@|$PWD/spoticyclint|" spoticyclint.desktop.in > "$apps/spoticyclint.desktop"
		cp spoticyclint.svg "$icons/spoticyclint.svg"
		update-desktop-database "$apps" 2>/dev/null || true
		gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
		echo "installed $apps/spoticyclint.desktop"
		;;
esac
