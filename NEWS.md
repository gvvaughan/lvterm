# lvterm NEWS - User visible changes

## Noteworthy changes in release ?.? (????-??-??) [?]

### New Features

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
