---
layout: default
---
# LVTERM

[Lvterm][] is a virtual terminal for [Lua][], to test programs that draw
on a terminal.  Feed it the bytes that a program writes, and ask what the
screen shows, and where the cursor is.

 * a screen to read, by cell, by run of text, by row, or all at once
   ([screens](#2-screens))
 * the replies that a real terminal sends back to the program
   ([replies](#3-replies))
 * emulation by [libvterm][], through the FFI of [LuaJIT][] or a thin C
   binding for every Lua from 5.1 to 5.5 ([backends](#4-backends))

The [reference](api/) documents each function.


## 1. Installation

Install libvterm and its headers with your package manager (the package is
usually called `libvterm-dev`, or `libvterm` with Homebrew), then, with
[LuaRocks][]:

    luarocks install lvterm

LuaRocks finds libvterm when it builds the rock, and tells lvterm where.  If
it isn't in a standard place, say where its `lib` directory is:

    luarocks install lvterm VTERM_DIR=/opt/homebrew

The rock is built by [luarocks-build-luke][], which LuaRocks installs for
the build.


## 2. Screens

`lvterm.new` makes a terminal of the given height and width, in rows and
columns, which are 24 and 80 by default.  Write to it what a program
writes, and read the screen:

```lua
local lvterm = require 'lvterm'
local term = lvterm.new(24, 80)

term:write '\27[2;3Hhello\27[1;31m!'
term:text(1, 2, 5)    --> 'hello'
term:cursor()         --> 1, 8
term:cell(1, 7).bold  --> true
term:cell(1, 7).fg    --> 1   (red, in the palette of 256 colors)
```

Rows and columns are numbered from 0, like the arguments of curses, and a
position that is off the screen is an error.

| Method                       | What it gives                                  |
| ---------------------------- | ---------------------------------------------- |
| `term:write(bytes)`          | feeds the terminal, and returns it             |
| `term:text(row, col, n)`     | `n` columns of text from a row, a space for each empty cell |
| `term:row(row)`              | one whole row, as wide as the screen           |
| `term:lines()`               | every row, from the top                        |
| `term:cell(row, col)`        | the text, width and attributes of one cell     |
| `term:cursor()`              | the row and column of the cursor               |
| `term:size()`                | the height and width                           |
| `term:resize(rows, cols)`    | changes the size, and returns the terminal     |
| `term:reset(hard)`           | back to the initial state, forgetting the screen unless `hard` is `false` |

A cell has the fields `text`, `width` (1, or 2 for a wide character),
`bold`, `italic`, `blink`, `reverse`, `conceal` and `strike`, `underline`
(0 for none, 1 single, 2 double, 3 curly), and `fg` and `bg`, each `nil`
for the default color, an index into the palette of 256 colors, or a table
of `red`, `green` and `blue`.


## 3. Replies

A terminal answers some of the sequences that it is given, such as a
request for the position of the cursor.  `term:output()` takes the bytes
that it has to send back to the program, which the terminal then forgets:

```lua
term:write '\27[6n'
term:output()         --> '\27[2;9R'   (the 1-based row and column of the cursor)
```

To test a program that asks its terminal questions, write what the program
sends to the terminal, and send what `term:output()` returns to the program.


## 4. Backends

libvterm emulates the terminal, called directly through the FFI of LuaJIT
where there is one (the `ffi` backend), and otherwise through a thin C
binding (the `core` backend), so lvterm works on Lua 5.1 to 5.5 and LuaJIT.
Both make terminals that behave the same, which the specs check by
comparing one with the other.

`lvterm.backend` is the name of the backend in use.  To test with a
particular backend, set the environment variable `LVTERM_BACKEND` to `ffi`
or `core`: lvterm then uses that one, or fails, and never falls back to the
other.

The `ffi` backend of LuaJIT declares its C types in the one namespace of
the process, so a program cannot load two copies of it.  A program that
needs two copies of lvterm in one process, such as a test runner that has
a copy for itself and tests a copy of lvterm in the tree it runs in, should
use the `core` backend.


[Lua]:      https://www.lua.org
[LuaJIT]:   https://luajit.org
[LuaRocks]: https://luarocks.org
[luarocks-build-luke]: https://luarocks.org/modules/gvvaughan/luarocks-build-luke
[Lvterm]:   https://github.com/gvvaughan/lvterm
[libvterm]: https://www.leonerd.org.uk/code/libvterm/
