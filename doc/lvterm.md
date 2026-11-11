---
layout: default
---
# LVTERM

[Lvterm][] is a virtual terminal for [Lua][]. It plays the part of a real
terminal, so that you can test a program that draws on a terminal, or host
one inside a program of your own, such as an editor with a window that runs a
shell.

Using it is a conversation in two directions. Whatever the program would
print goes in with `write`, and you read the screen that results. Whatever the
terminal would send back to the program, such as a reply to a question, a key
that was pressed, or a click of the mouse, comes out of `output`.

```lua
local lvterm = require 'lvterm'
local term = lvterm.new(24, 80)

term:write '\27[2;3Hhello\27[1;31m!'   -- the program draws
term:text(1, 2, 5)                      --> 'hello'
term:key 'up'                           -- the user presses a key
term:output()                           --> '\27[A', which goes to the program
```

This manual follows that conversation:

 * [Installation](#1-installation)
 * [Reading the screen](#2-reading-the-screen)
 * [Scrollback and the alternate screen](#3-scrollback-and-the-alternate-screen)
 * [Sending input to the program](#4-sending-input-to-the-program)
 * [What the program asks for](#5-what-the-program-asks-for): the mouse, the
   focus, bracketed paste, the title and the bell
 * [Backends](#6-backends)

The [reference](api/) documents every function.


## 1. Installation

Install libvterm and its headers with your package manager. The package is
usually called `libvterm-dev`, or `libvterm` with Homebrew. Then, with
[LuaRocks][]:

    luarocks install lvterm

LuaRocks finds libvterm when it builds the rock, and tells lvterm where it
is. If libvterm is not in a standard place, say where its `lib` directory is:

    luarocks install lvterm VTERM_DIR=/opt/homebrew

The rock is built by [luarocks-build-luke][], which LuaRocks installs for
you.

`require 'lvterm'.version` says which version of lvterm is installed.

### Optional modules

Lvterm checks the types of its arguments if [typecheck][] is installed, and if
[std.strict][] is installed, it makes its own modules declare every variable
they use. You don't need either of them, and neither changes what lvterm does
when you use it correctly.


## 2. Reading the screen

`lvterm.new` makes a terminal with the number of rows and columns that you
give it, and 24 by 80 if you give none. Write to it what a program would
write, and read back what the screen shows:

```lua
local term = lvterm.new(24, 80)

term:write '\27[2;3Hhello\27[1;31m!'
term:text(1, 2, 5)    --> 'hello'
term:cursor()         --> 1, 8
term:cell(1, 7).bold  --> true
term:cell(1, 7).fg    --> 1   (red, in the palette of 256 colors)
```

Rows and columns are numbered from 0, like the arguments of curses. Asking
about a position that is not on the screen is an error.

| Method                       | What it does                                   |
| ---------------------------- | ---------------------------------------------- |
| `term:write(bytes)`          | feeds the virtual terminal, and returns itself |
| `term:text(row, col, n)`     | returns `n` columns of text from a row, with spaces for each empty cell |
| `term:row(row)`              | returns one whole row, as wide as the screen   |
| `term:lines()`               | returns every row, from the top                |
| `term:cell(row, col)`        | returns the text, width and attributes of one cell |
| `term:runs(row)`             | returns one row as runs of cells that are drawn alike |
| `term:cursor()`              | returns the row and column of the cursor       |
| `term:size()`                | returns the height and width                   |
| `term:resize(rows, cols)`    | changes the size, and returns the terminal     |
| `term:reset(hard)`           | returns to the initial state, and forgets the screen unless `hard` is `false` |

A cell is a table with these fields:

 * `text` is the character, and `width` is 1, or 2 for a wide character.
 * `bold`, `italic`, `blink`, `reverse`, `conceal` and `strike` are booleans.
 * `underline` is 0 for none, 1 for single, 2 for double, and 3 for curly.
 * `fg` and `bg` are the colors. Each is `nil` for the default color, a
   number for an index into the palette of 256 colors, or a table with the
   fields `red`, `green` and `blue`.

A program that draws a row, which most draw a run of cells at a time, asks
for `term:runs(row)` and makes one call for the row, and not one for each
cell. It is a list of runs, from the first column to the last, which add up to
the width of the screen. A run is a table with `col`, the first column of it
from 0, `cols`, how many columns it covers, and `text`, the text of its cells
as they give it, so that the right half of a wide character adds none. It has
the fields of a cell that the cells of a run are alike in: `bold`, `italic`,
`blink`, `reverse`, `conceal`, `strike`, `underline`, `fg` and `bg`. The right
half of a wide character is in the run of the character, whatever it is drawn
like.


## 3. Scrollback and the alternate screen

When a line scrolls off the top of the main screen, the terminal retains it.
By default it keeps as many lines as there is memory for. To keep fewer, declare
how many when you create the terminal:

```lua
local term = lvterm.new(24, 80, {scrollback = 10000})

term:scrollback_size()       --> how many lines have scrolled off
term:scrollback_line(1)      --> the cells of the newest line, as a list
term:scrollback_line(1)[1].text
```

`scrollback = 0` keeps nothing.

The newest line is number 1, and the oldest is `term:scrollback_size()`.
Requesting a line that is not there is an error. A line is a list with one
cell for each column that the screen had when the line scrolled off, and each
cell is the same kind that `term:cell` gives, including all the colors and
attributes that it had. Blank cells at the end of a line are not kept in memory,
but they are returned when you read that line back.

Only the main screen scrolls back. The alternate screen, which full-screen
programs switch to, does not, and neither does a scroll of only part of the
alternate screen. When you make the terminal smaller, the lines that no longer
fit vertically are added to the scrollback, and when you make it larger, the
newest lines are taken back from the scrollback and cut or padded to the new
width. `term:scrollback_clear()` discards all of the scrollback lines (as a
program does when `\27[3J` is written).

A program that displays the virtual terminal screen, such as an editor with a
terminal window, can request the properties it needs with:

| Method                       | What it does                                    |
| ---------------------------- | ----------------------------------------------- |
| `term:scrollback_size()`     | how many lines are in the scrollback            |
| `term:scrollback_line(n)`    | cells of the nth line (from the newest)         |
| `term:scrollback_runs(n)`    | runs of the nth line, as `term:runs` gives      |
| `term:scrollback_clear()`    | forget all lines, and return the terminal       |
| `term:altscreen()`           | is the virtual terminal on the alternate screen |
| `term:cursor_visible()`      | is the virtual terminal cursor visible          |

Such a program uses `term:altscreen()` to decide whether to offer the
scrollback, because there is none to show on the alternate screen.
Even after a reset, a terminal that was on the alternate screen stays there.

libvterm 0.3 switches to the alternate screen for `\27[?1047h` and
`\27[?1049h`, but not for `\27[?47h`.


## 4. Sending input to the program

If a calling program needs the position of the cursor, for example, the
virtual terminal can answer that. `term:output()` returns all the bytes that
are waiting to go back to the calling program, and then discards them:

```lua
term:write '\27[6n'    -- the program asks where the cursor is
term:output()          --> '\27[2;9R'   (the 1-based row and column)
```

To write a program that asks its terminal questions, `term:write()` what
sequences the program sends to the terminal, and give back to the program
what `term:output()` returns.

The same bytes carry what the user types. `term:key` returns what a key sends,
and the answer depends on the modes that the program has set, such as whether
the application cursor keys are configured for an application:

```lua
term:key 'up'
term:output()                   --> '\27[A'
term:set_mode('application_cursor_keys', true)  -- the program asks for them
term:key 'up'
term:output()                   --> '\27OA'
term:key('up', {ctrl = true})
term:output()                   --> '\27[1;5A'
term:char(0x4e2d)               -- a character, sent as UTF-8
term:paste 'text'               -- some text, pasted
```

Application cursor keys are a mode that the program turns on by writing
`\27[?1h`. libvterm has no call for it, so `term:set_mode` writes the sequence
that the program would, as it does for the other modes that libvterm has no
call for (see section 5).

The key names are `enter`, `tab`, `backspace`, `escape`, `up`, `down`,
`left`, `right`, `insert`, `delete`, `home`, `end`, `pageup`, `pagedown`,
and `f1` through `f12`. Any other name is an error.

The modifiers are the fields `shift`, `alt` and `ctrl` in a table as shown
above.

`term:paste` sends the text exactly as it is, and the text may be any bytes.
If the program asked for bracketed paste, the text is sent between the marks
that tell the program where the paste starts and ends. Section 5 shows an
example.

`key`, `char` and `paste` all return the terminal instance. The sequences
they send back are queued for `term:output()`, in the order they were
requested, together with any replies.


## 5. What the program asks for

A program can ask the terminal about more than just responses to keys, by
writing an escape sequence, and from then on the terminal reports the events
that it asked for. This section covers each kind of request, and then the two
things that a program knows about itself: its title, and the bell.

### The mouse

A program can subscribe to various mouse events with the following
sequences:

| Mode    | Sequence     | What the program is told                       |
| ------- | ------------ | ---------------------------------------------- |
| `click` | `\27[?1000h` | presses and releases                           |
| `drag`  | `\27[?1002h` | the same, and moves while a button is down     |
| `move`  | `\27[?1003h` | the same, and every move                       |

`term:mouse_mode()` remembers which events the program is subscribed to,
or `'none'` after a reset.

A test that stands in for the program does not have to write those sequences.
`term:set_termprop('mouse', mode)` wraps libvterm's `vterm_state_set_termprop`,
and subscribes to the mode as the program would have.

Once the program has subscribed, you send mouse events to the virtual
terminal, and it queues responses for the next `term:output()` call.
For example to set the mouse pointer coordinates, followed by a left
mouse button click:

```lua
term:set_termprop('mouse', 'click')  -- the program asks for presses and releases
term:mouse_move(2, 3)                -- the mouse is over row 2 and column 3
term:mouse_button('left', true)      -- a press, where the mouse is
term:output()                        --> '\27[M $#'
```

The buttons are `left`, `middle`, `right`, `wheelup`, `wheeldown`,
`wheelleft` and `wheelright`. A wheel turn has no release event. The modifiers
are the same as for a key, and a position that is not on the screen is an error.
Until the program has written some events into the virtual terminal, nothing is
output back. libvterm also remembers which buttons are down, even when the program
has not asked, so pressing a button that is already down is ignored.

Unless the program asks for another form, the reports are written in the old
X10 form, which can only name positions a short way across and down. A program
that wants the SGR form, which has no limit on the size of the screen, writes
`\27[?1006h`. libvterm has no suitable api call to choose the form, so
`term:set_mode('mouse_encoding', form)` writes the sequence for you. The forms
are `x10`, `utf8`, `sgr` and `urxvt`, and the last one that was set is used:

```lua
local term = lvterm.new(24, 80)
term:set_termprop('mouse', 'click')
term:set_mode('mouse_encoding', 'sgr')  -- the program asks for the SGR form
term:mouse_move(2, 3)
term:mouse_button('left', true)
term:output()                        --> '\27[<0;4;3M'   (1-based; `m` ends it for a release)
```

### The focus

A program can also subscribe to focus events with `\27[?1004h`.
`term:focus_reporting()` reports whether it has subscribed.
When the window that shows the terminal gains or loses the focus, tell the
terminal, and it sends the program the report if subscribed:

```lua
term:set_termprop('focusreport', true)   -- the same as the program writing \27[?1004h
term:focus_in()
term:output()                            --> '\27[I'
term:focus_out()
term:output()                            --> '\27[O'
```

### Bracketed paste

A program that asks for bracketed paste with `\27[?2004h` gets pasted text
between two marks, so that it can tell a huge paste event from actual typing.
Then `term:paste` adds the marks, and without the request it sends the text
alone. libvterm has no call to turn this mode on, so the program writes the
sequence, and a test that stands in for it uses `term:set_mode`:

```lua
term:set_mode('bracketed_paste', true)
term:paste 'hi'
term:output()                   --> '\27[200~hi\27[201~'
```

### The title and the bell

A program sets the title of its window by writing `\27]0;title\7` or
`\27]2;title\7`. `term:title()` is the last title that was complete, or `nil`
if there has been none. A title that is only half written is not a title yet.
The program rings the bell by writing `\7`, and `term:bells()` says how many
times it rang since you last asked, and then starts counting again from none.

| Method                                     | What it does                                  |
| ------------------------------------------ | --------------------------------------------- |
| `term:mouse_mode()`                        | what mouse events are subscribed to?          |
| `term:mouse_move(row, col, mods)`          | moves the mouse, and returns the terminal     |
| `term:mouse_button(button, pressed, mods)` | presses or releases a button                  |
| `term:focus_reporting()`                   | are focus events subscribed to?               |
| `term:focus_in()`, `term:focus_out()`      | tell the virtual terminal that focus was gained or lost |
| `term:set_termprop(name, value)`           | sets `'mouse'` or `'focusreport'` as the program would |
| `term:set_mode(name, value)`               | sets `'bracketed_paste'`, `'application_cursor_keys'` or `'mouse_encoding'` as the program would |
| `term:title()`                             | the title that the program set, or `nil` |
| `term:bells()`                             | how many times did the bell ring since prior call |


## 6. Backends

libvterm does the work of emulating the terminal. Lvterm reaches it in one of
two backends. Where there is a LuaJIT FFI, the `ffi` backend calls libvterm
directly. Everywhere else, the `core` backend calls it through a thin C binding,
so lvterm works well on Lua 5.1 to 5.5 and on LuaJIT. Both backends behave the
same.

`lvterm.backend` is the name of the backend in use. To test with a particular
backend, set the environment variable `LVTERM_BACKEND` to `ffi` or `core`.
Lvterm then uses that one, or fails, and never falls back to the other.

The `ffi` backend declares its C types in the one namespace that LuaJIT has
for the whole process, so a program cannot load two copies of it. A program
that needs two copies of lvterm in one process should use the `core`
backend, a test runner for example.


[Lua]:      https://www.lua.org
[LuaJIT]:   https://luajit.org
[LuaRocks]: https://luarocks.org
[luarocks-build-luke]: https://luarocks.org/modules/gvvaughan/luarocks-build-luke
[std.strict]: https://github.com/lua-stdlib/strict
[typecheck]: https://github.com/gvvaughan/typecheck
[Lvterm]:   https://github.com/gvvaughan/lvterm
[libvterm]: https://www.leonerd.org.uk/code/libvterm/
