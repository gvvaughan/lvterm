---
layout: default
---
# LVTERM

[Lvterm][] is a virtual terminal for [Lua][], to test programs that draw
on a terminal.  Feed it the bytes that a program writes, and ask what the
screen shows, and where the cursor is.

 * a screen to read, by cell, by run of text, by row, or all at once
   ([screens](#2-screens))
 * the lines that scroll off the top, and whether the program is on the
   alternate screen or has hidden the cursor ([scrollback](#3-scrollback))
 * the replies that a real terminal sends back to the program, and what it
   sends for the keys that are typed to it, and for a paste
   ([replies and keys](#4-replies-and-keys))
 * emulation by [libvterm][], through the FFI of [LuaJIT][] or a thin C
   binding for every Lua from 5.1 to 5.5 ([backends](#5-backends))

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


## 3. Scrollback

A terminal keeps the lines that scroll off the top of the main screen, as many of
them as there is memory for, unless it was told how many to keep:

```lua
local term = lvterm.new(24, 80, {scrollback = 10000})

term:scrollback_size()       --> how many lines have scrolled off
term:scrollback_line(1)      --> the cells of the newest, as a list
term:scrollback_line(1)[1].text
```

The newest line is number 1, and the oldest is `term:scrollback_size()`.  A line is a
list of cells, one for each column that the screen had when the line scrolled
off, of the kind that `term:cell` gives, with the colors and attributes that
the cells had.  Trailing blank cells are not kept in memory, but are there when the line is
read.  `scrollback = 0` keeps nothing.  A line that is not in the scrollback is an error.

Lines scroll back only from the whole of the main screen: the alternate screen
that full-screen programs switch to does not, and nor does a scroll of part of the screen.
When a terminal is made smaller the lines that go are added to the scrollback, and when
it is made larger the newest lines are taken from it again, cut or padded to the new
width.  `term:scrollback_clear()` forgets the lines, as a program does with `\27[3J`.

| Method                       | What it gives                                  |
| ---------------------------- | ---------------------------------------------- |
| `term:scrollback_size()`     | how many lines are in the scrollback           |
| `term:scrollback_line(n)`    | the cells of the nth line, from the newest     |
| `term:scrollback_clear()`    | forgets the lines, and returns the terminal    |
| `term:altscreen()`           | whether the program is on the alternate screen |
| `term:cursor_visible()`      | `false` after the program hid the cursor       |

libvterm 0.3 switches to the alternate screen for `\27[?1047h` and `\27[?1049h`, but not
for `\27[?47h`, and a reset leaves a terminal on the alternate screen if it was there.  A
program such as a viewer for a terminal uses `term:altscreen()` to decide whether
to show the scrollback.


## 4. Replies and keys

A terminal answers some of the sequences that it is given, such as a
request for the position of the cursor.  `term:output()` takes the bytes
that it has to send back to the program, which the terminal then forgets:

```lua
term:write '\27[6n'
term:output()         --> '\27[2;9R'   (the 1-based row and column of the cursor)
```

To test a program that asks its terminal questions, write what the program
sends to the terminal, and send what `term:output()` returns to the program.

What the terminal sends for the keys that are typed to it is in the same bytes,
which depend on the modes that the program has set, such as whether the cursor
keys are for an application:

```lua
term:key 'up'
term:output()                   --> '\27[A'
term:write '\27[?1h'            -- the program asks for application cursor keys
term:key 'up'
term:output()                   --> '\27OA'
term:key('up', {ctrl = true})
term:output()                   --> '\27[1;5A'
term:char(0x4e2d)               -- a character, as UTF-8
term:paste 'text'               -- the text, between the marks that the program asked for
```

The keys are `enter`, `tab`, `backspace`, `escape`, `up`, `down`, `left`, `right`, `insert`,
`delete`, `home`, `end`, `pageup`, `pagedown` and `f1` to `f12`, and the modifiers
are the fields `shift`, `alt` and `ctrl` of a table.  A key that is not one of those
is an error.  `term:paste` sends the text as it is, which may be any bytes, and
puts the marks of bracketed paste before and after it only if the program set that mode,
with `\27[?2004h`.  All of them return the terminal, and what they send is taken with
`term:output()`, in the order that it was made, along with the replies.


## 5. Backends

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
