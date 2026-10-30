lvterm
======

Copyright (C) 2026 Gary V. Vaughan

[![License](https://img.shields.io/:license-mit-blue.svg)](https://mit-license.org)
[![workflow status](https://github.com/gvvaughan/lvterm/actions/workflows/spec.yml/badge.svg?branch=master)](https://github.com/gvvaughan/lvterm/actions)
[![codecov.io](https://codecov.io/github/gvvaughan/lvterm/coverage.svg?branch=master)](https://codecov.io/github/gvvaughan/lvterm?branch=master)

A virtual terminal for [Lua][], to test programs that draw on a terminal.
Feed it the bytes that a program writes, and ask what the screen shows, and
where the cursor is:

```lua
local lvterm = require 'lvterm'
local term = lvterm.new(24, 80)

term:write '\27[2;3Hhello\27[1;31m!'
term:text(1, 2, 5)    --> 'hello'
term:cursor()         --> 1, 8
term:cell(1, 7).bold  --> true
term:cell(1, 7).fg    --> 1   (red, in the palette of 256 colors)
```

Rows and columns are numbered from 0, like the arguments of curses.

The terminal is emulated by [libvterm][], which also does the work for
Neovim.  [LuaJIT][] calls it directly through its FFI, and every other
Lua version through a thin C binding, so lvterm works on Lua 5.1 to 5.5
and LuaJIT.  Both backends make terminals that behave the same, which the
specs check by comparing one with the other.

To test with a particular backend, set `LVTERM_BACKEND` to `ffi` or `core`:
`lvterm` then uses that one, or fails, and never falls back to the other.


Installation
------------

If you use [LuaRocks][], install libvterm and its headers with your
package manager (the package is usually called `libvterm-dev`, or
`libvterm` with Homebrew), then:

    luarocks install lvterm

LuaRocks finds libvterm when it builds the rock, and tells lvterm where.
If it isn't in a standard place, say where its `lib` directory is:

    luarocks install lvterm VTERM_DIR=/opt/homebrew

To install current git master (for testing):

    luarocks install https://raw.githubusercontent.com/gvvaughan/lvterm/master/lvterm-dev-1.rockspec

To install into a tree of your own from a clone of the [repository][lvterm],
and run the specs:

```sh
cd lvterm
luarocks --tree LVTERM-INSTALL-TREE make lvterm-dev-1.rockspec VTERM_DIR=LIBVTERM-INSTALL-PREFIX
luarocks --tree LVTERM-INSTALL-TREE test
```

LuaRocks builds lvterm with [luarocks-build-luke][], which it installs for
the build.


Bug reports and code contributions
----------------------------------

Please make bug reports and suggestions as [GitHub Issues][issues].
Pull requests are especially appreciated.

There is no strict coding style, but please follow the existing code:
3-character indentation using SPACES in Lua sources, and single-quote
delimiters for simple strings.


[issues]:   https://github.com/gvvaughan/lvterm/issues
[libvterm]: https://www.leonerd.org.uk/code/libvterm/
[lua]:      https://www.lua.org
[luajit]:   https://luajit.org
[luarocks]: https://luarocks.org
[luarocks-build-luke]: https://luarocks.org/modules/gvvaughan/luarocks-build-luke
[lvterm]:   https://github.com/gvvaughan/lvterm
