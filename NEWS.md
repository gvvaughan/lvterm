# lvterm NEWS - User visible changes

## Noteworthy changes in release ?.? (????-??-??) [?]

### New Features

  - `set_termprop(name, value)` wraps `vterm_state_set_termprop`, so that
    a test that stands in for a program can say what the program would
    have asked for without writing the escape sequences: `'mouse'` takes
    `'none'`, `'click'`, `'drag'` or `'move'`, and `'focusreport'` takes
    `true` or `false`.  How the mouse is written to the program is up to
    the program, as libvterm has no call for it.

  - `focus_in()`, `focus_out()` and `focus_reporting()` wrap
    `vterm_state_focus_in`, `vterm_state_focus_out` and the property that
    says whether the program asked to be told, so `output()` has the
    reports that a terminal sends when it gains or loses the focus.


## Noteworthy changes in release 0.2 (2026-11-10) [stable]

### New Features

  - lvterm can host a program as well as test one.  A terminal keeps
    the lines that scroll off the top: `scrollback_size()`,
    `scrollback_line(n)` (the newest is 1) and `scrollback_clear()`
    read and forget them, and `lvterm.new(rows, cols, {scrollback = n})`
    keeps at most `n` lines, and all of them if it is not given.  Lines
    that a smaller terminal pushes off, and a larger one gets back, are
    kept as a program would see them.

  - `altscreen()` says whether the program is on the alternate screen,
    and `cursor_visible()` whether it has the cursor shown.

  - `key(name, mods)`, `char(cp, mods)` and `paste(text)` put into
    `output()` what a terminal sends to the program for a key, a
    character and a paste, as the modes that the program set, such as
    application cursor keys and bracketed paste, say.

  - `mouse_mode()` returns mouse events requested by the program:
    `'none'`, `'click'`, `'drag'` or `'move'`.  `mouse_move(row, col, mods)`
    and `mouse_button(button, pressed, mods)` put into `output()` what a
    terminal sends for the mouse, in the form that the program asked for,
    and nothing until it asks.

  - `title()` is the title that the program set, or `nil`, and `bells()`
    takes how many times it rang the bell since it was last asked.


## Noteworthy changes in release 0.1 (2026-11-03) [stable]

### New Features

  - Initial release: a virtual terminal for testing programs that draw
    on one.  Feed `lvterm.new()` the bytes that a program writes, then
    ask what each cell of the screen shows and where the cursor is.

  - The terminal is emulated by libvterm 0.3, called directly through the
    FFI of LuaJIT, and through a thin C binding on every other Lua, 5.1
    to 5.5.  LuaRocks finds libvterm and its headers when it builds the
    rock, so `VTERM_DIR` says where they are when they're not in a
    standard place.

  - `LVTERM_BACKEND`, set to `ffi` or `core`, makes lvterm use that
    backend, or fail, instead of using the first that works.
