# lvterm NEWS - User visible changes

## Noteworthy changes in release ?.? (????-??-??) [?]

### New Features

  - Initial release: a virtual terminal for testing programs that draw
    on one.  Feed `lvterm.new()` the bytes that a program writes, then
    ask what each cell of the screen shows and where the cursor is.

  - The terminal is emulated by libvterm 0.3, called directly through the
    FFI of LuaJIT.  LuaRocks finds libvterm when it builds the rock, so
    `VTERM_DIR` says where it is when it's not in a standard place.
