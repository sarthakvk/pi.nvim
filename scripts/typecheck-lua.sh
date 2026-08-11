#!/usr/bin/env bash
# Type-checks the Lua sources with lua-language-server, the same server the
# editor runs, reading the same .luarc.json.
#
# VIMRUNTIME is resolved from the Neovim on PATH rather than written into
# .luarc.json, because it is an install-specific path. workspace.library points
# at $VIMRUNTIME/lua, which is where the vim.* and uv.* definitions live; without
# it every vim call reports as an undefined global and the real diagnostics are
# buried in the noise.
#
# Exits non-zero when any diagnostic at --checklevel or above is found.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

server="${LUA_LS:-}"
if [ -z "$server" ]; then
	if command -v lua-language-server >/dev/null 2>&1; then
		server="lua-language-server"
	elif [ -x "$HOME/.local/share/nvim/mason/bin/lua-language-server" ]; then
		server="$HOME/.local/share/nvim/mason/bin/lua-language-server"
	else
		echo "lua-language-server not found; install it or set LUA_LS to its path" >&2
		exit 1
	fi
fi

if ! command -v nvim >/dev/null 2>&1; then
	echo "nvim not found; it is needed to locate the Neovim runtime definitions" >&2
	exit 1
fi

VIMRUNTIME="$(nvim --headless -u NONE -c 'lua io.write(vim.env.VIMRUNTIME)' -c 'q' 2>/dev/null)"
export VIMRUNTIME
if [ -z "$VIMRUNTIME" ]; then
	echo "cannot resolve VIMRUNTIME from nvim" >&2
	exit 1
fi

# --check writes a log per run; keep it out of the working tree.
log="$(mktemp -d)"
trap 'rm -rf "$log"' EXIT

"$server" \
	--check "$root" \
	--configpath "$root/.luarc.json" \
	--checklevel "${LUA_CHECKLEVEL:-Warning}" \
	--logpath "$log"
