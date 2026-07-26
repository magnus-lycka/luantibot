#!/bin/sh
# Source this to put the project-local Lua 5.1 toolchain on PATH.
#
# Luanti embeds LuaJIT (Lua 5.1). Homebrew's `lua` is 5.5, which differs in ways
# that matter for the code we unit test -- integer/float division, `//`,
# `unpack` vs `table.unpack`. So busted and luacheck are installed against
# LuaJIT into a project-local rocks tree rather than the system one.
#
# Bootstrap (once):
#   brew install luajit luarocks stylua
#   luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
#            --tree=.luarocks install busted
#   luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
#            --tree=.luarocks install luacheck

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
export REPO_ROOT

eval "$(luarocks --lua-version=5.1 --lua-dir="$(brew --prefix luajit)" \
        --tree="$REPO_ROOT/.luarocks" path)"
PATH="$REPO_ROOT/.luarocks/bin:$PATH"
export PATH
