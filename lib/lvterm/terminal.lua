--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 A virtual terminal, over the handle that a backend makes.

 A backend makes a handle, which has `write`, `resize`, `reset`, `cursor`,
 `cell` and `output` methods, and nothing else, so that terminals made by
 any backend behave the same.  The `Terminal` here checks positions, and
 reads text, once, for all of them.

 @module lvterm.terminal
]]


local _ENV = require 'lvterm._normalize'.strictness() {
   concat = table.concat,
   error = error,
   find = string.find,
   format = string.format,
   gmatch = string.gmatch,
   ipairs = ipairs,
   pairs = pairs,
   pcall = pcall,
   require = require,
   setmetatable = setmetatable,
   sub = string.sub,
   tostring = tostring,
   type = type,
}


-- Check the types of the arguments of every method, if typecheck is installed.
local argscheck
do
   local ok, typecheck = pcall(require, 'typecheck')
   if ok then
      argscheck = typecheck.argscheck
   else
      argscheck = function(decl, fn)
         return fn
      end
   end
end



--[[ ================= ]]--
--[[ Helper Functions. ]]--
--[[ ================= ]]--


-- Raise an error unless ROW and COL are on the screen of the TERMINAL.
local function check(terminal, row, col)
   if row < 0 or row >= terminal.rows or col < 0 or col >= terminal.cols then
      error(format('position %d,%d is outside a screen of %d,%d',
                   row, col, terminal.rows, terminal.cols), 3)
   end
end


-- The numbers that libvterm gives to the keys, which do not change.
local KEYS = {
   enter = 1, tab = 2, backspace = 3, escape = 4, up = 5, down = 6, left = 7,
   right = 8, insert = 9, delete = 10, home = 11, ['end'] = 12, pageup = 13,
   pagedown = 14,
}
for n = 1, 12 do
   KEYS['f' .. n] = 256 + n
end


-- The mask of the modifiers that are held, in the bits that libvterm uses.
local function modifiers(mods)
   local mask = 0
   if mods then
      mask = (mods.shift and 1 or 0) + (mods.alt and 2 or 0) + (mods.ctrl and 4 or 0)
   end
   return mask
end


-- The numbers that libvterm gives to the mouse buttons.
local BUTTONS = {left = 1, middle = 2, right = 3, wheelup = 4, wheeldown = 5, wheelleft = 6, wheelright = 7}

-- What the program can ask to be told about the mouse, by the number that libvterm has.
local MOUSE_MODES = {[0] = 'none', 'click', 'drag', 'move'}

-- The properties that `set_termprop` sets, by the name that libvterm has for each without `VTERM_PROP_`,
-- and the number that it has for it.
local TERMPROPS = {mouse = 8, focusreport = 9}

-- The modes that libvterm has no call for, so that they are set as a program sets them, by writing a
-- sequence: the number that is in it, for each.
local MODES = {bracketed_paste = 2004, application_cursor_keys = 1}

-- The ways that the reports of the mouse are written, by the number that is in the sequence that asks for
-- each of them, which is false for the old form that is used when none is asked for.
local ENCODINGS = {x10 = false, utf8 = 1005, sgr = 1006, urxvt = 1015}



--[[ ================= ]]--
--[[ Terminal methods. ]]--
--[[ ================= ]]--


--- A virtual terminal.
-- Rows and columns are numbered from 0, like the arguments of curses.
-- @type Terminal


-- How many bytes at the end of some, if any, are the start of a character
-- of UTF-8 whose other bytes are still to come.  A program that writes a
-- character in one piece can have it read in two, and libvterm draws the
-- two parts as characters of their own, and scrolls if they are at the end of
-- the last row, so they are held until the rest arrives, as a terminal does.
local function incomplete(bytes)
   local last = #bytes
   for i = last, last > 3 and last - 3 or 1, -1 do
      local b = bytes:byte(i)
      if b < 0x80 then
         return 0
      elseif b >= 0xC0 then
         local need = b >= 0xF0 and 4 or b >= 0xE0 and 3 or 2
         return last - i + 1 < need and last - i + 1 or 0
      end
   end
   return 0
end


--- Feed bytes to the terminal, as a program writes them.
-- @function write
-- @string bytes what the terminal receives
-- @treturn Terminal the terminal
local function write(self, bytes)
   bytes = (self.held or '') .. bytes
   local held = incomplete(bytes)
   self.held = held > 0 and bytes:sub(-held) or nil
   self.handle:write(held > 0 and bytes:sub(1, -held - 1) or bytes)
   return self
end


--- Change the size of the terminal.
-- @function resize
-- @int rows new height in lines
-- @int cols new width in columns
-- @treturn Terminal the terminal
local function resize(self, rows, cols)
   self.handle:resize(rows, cols)
   self.rows, self.cols = rows, cols
   return self
end


--- Return the terminal to its initial state.
-- @function reset
-- @bool[opt=true] hard also forget the contents of the screen
-- @treturn Terminal the terminal
local function reset(self, hard)
   self.held = nil
   self.handle:reset(hard ~= false)
   return self
end


--- The size of the terminal.
-- @function size
-- @treturn int height in lines
-- @treturn int width in columns
local function size(self)
   return self.rows, self.cols
end


--- Where the cursor is.
-- @function cursor
-- @treturn int row
-- @treturn int column
local function cursor(self)
   return self.handle:cursor()
end


--- What one cell of the screen shows.
-- @function cell
-- @int row line to read, from 0
-- @int col column to read, from 0
-- @treturn table fields `text` (the characters, a space when the cell is
--   empty, and the empty string for the right half of a wide character),
--   `width` (columns, 1 or 2), `bold`, `italic`, `blink`, `reverse`,
--   `conceal` and `strike` (booleans), `underline` (0 for none, 1 single,
--   2 double, 3 curly), and `fg` and `bg`, each `nil` for the default, an
--   index into the 256 color palette, or a table of `red`, `green` and
--   `blue`
local function cell(self, row, col)
   check(self, row, col)
   return self.handle:cell(row, col)
end


--- What one row of the screen shows, as runs of cells that are drawn alike.
-- A program that draws a row, such as the screen of a terminal in an editor,
-- does so a run at a time, which is a call for each run, and not for each
-- cell.
-- @function runs
-- @int row line to read, from 0
-- @treturn {table,...} the runs, from the first column to the last, each
--   with `col` (the first column, from 0), `cols` (how many columns, which
--   add up to the width of the screen), `text` (the text of its cells, as
--   `cell` gives them, so that the right half of a wide character has none),
--   and the fields of `cell` that cells are alike in: `bold`, `italic`,
--   `blink`, `reverse`, `conceal`, `strike`, `underline`, `fg` and `bg`.  The
--   tables are not to be changed, as the `ffi` backend gives the same ones
--   again for a row whose cells have not changed since, so that a program
--   can tell that a row is the same by comparing them.
local function runs(self, row)
   check(self, row, 0)
   return self.handle:runs(row)
end


--- Some of the text on the screen, from one row.
-- @function text
-- @int row line to read, from 0
-- @int[opt=0] col first column to read, from 0
-- @int[opt] n how many columns to read, to the end of the line by default
-- @treturn string the text, a space for each empty cell, and so exactly
--   as wide as the columns that it was asked for
local function text(self, row, col, n)
   col = col or 0
   n = n or self.cols - col
   check(self, row, col)
   if n < 1 or col + n > self.cols then
      error(format('%d columns from column %d is outside a screen of %d columns',
                   n, col, self.cols), 2)
   end

   local chars = {}
   for c = col, col + n - 1 do
      chars[#chars + 1] = self.handle:cell(row, c).text
   end
   return concat(chars)
end


--- A whole row of the screen.
-- @function row
-- @int row line to read, from 0
-- @treturn string the text, as wide as the screen
local function row(self, row)
   return text(self, row)
end


--- Every row of the screen.
-- @function lines
-- @treturn {string,...} the rows, from the top
local function lines(self)
   local rows = {}
   for r = 0, self.rows - 1 do
      rows[#rows + 1] = text(self, r)
   end
   return rows
end


--- How many lines have scrolled off the top of the screen.
-- Only the main screen scrolls back: the alternate screen does not.
-- @function scrollback_size
-- @treturn int the number of lines in the scrollback
local function scrollback_size(self)
   return self.handle:scrollback_size()
end


--- A line that scrolled off the top of the screen.
-- @function scrollback_line
-- @int n which line, from 1 for the newest to `scrollback_size` for the oldest
-- @treturn {table,...} a cell for each column of the line as it was, of the
--   kind that `cell` gives
local function scrollback_line(self, n)
   local count = self.handle:scrollback_size()
   if type(n) ~= 'number' or n < 1 or n > count or n % 1 ~= 0 then
      error(format('line %s is outside a scrollback of %d lines', tostring(n), count), 2)
   end
   return self.handle:scrollback_line(n)
end


--- A line that scrolled off the top of the screen, as runs of cells that are
-- drawn alike.
-- @function scrollback_runs
-- @int n which line, from 1 for the newest to `scrollback_size` for the oldest
-- @treturn {table,...} the runs of the line as it was, of the kind that `runs` gives
local function scrollback_runs(self, n)
   local count = self.handle:scrollback_size()
   if type(n) ~= 'number' or n < 1 or n > count or n % 1 ~= 0 then
      error(format('line %s is outside a scrollback of %d lines', tostring(n), count), 2)
   end
   return self.handle:scrollback_runs(n)
end


--- Forget the scrollback.
-- @function scrollback_clear
-- @treturn Terminal the terminal
local function scrollback_clear(self)
   self.handle:scrollback_clear()
   return self
end


--- Whether the program is on the alternate screen.
-- @function altscreen
-- @treturn bool true after it switched to it, and false after it switched back
local function altscreen(self)
   return self.handle:altscreen()
end


--- Whether the program has the cursor shown.
-- @function cursor_visible
-- @treturn bool false after the program hid the cursor, and true after it showed it
local function cursor_visible(self)
   return self.handle:cursor_visible()
end


--- Press a key, as the terminal would send it to the program.
-- What is sent depends on the modes that the program has set, such as the
-- cursor keys, and is taken with `output`.
-- @function key
-- @string name `enter`, `tab`, `backspace`, `escape`, `up`, `down`, `left`,
--   `right`, `insert`, `delete`, `home`, `end`, `pageup`, `pagedown`, or `f1` to `f12`
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
local function key(self, name, mods)
   local code = type(name) == 'string' and KEYS[name]
   if not code then
      error(format('unknown key %s', tostring(name)), 2)
   end
   self.handle:key(code, modifiers(mods))
   return self
end


--- Type a character, as the terminal would send it to the program.
-- @function char
-- @int cp the code point of the character
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
local function char(self, cp, mods)
   if type(cp) ~= 'number' or cp < 0 or cp > 0x10FFFF or cp % 1 ~= 0 then
      error(format('%s is not a character', tostring(cp)), 2)
   end
   self.handle:char(cp, modifiers(mods))
   return self
end


--- Paste text, as the terminal would send it to the program.
-- The text is sent as it is, between the marks that tell the program where
-- a paste starts and ends if the program asked for them.
-- @function paste
-- @string text what is pasted, which may be any bytes
-- @treturn Terminal the terminal
local function paste(self, text)
   self.handle:paste(text)
   return self
end


--- What the program asked to be told about the mouse.
-- A program asks with a sequence such as `ESC [ ? 1000 h`, and until it does,
-- `mouse_move` and `mouse_button` send nothing.
-- @function mouse_mode
-- @treturn string `none`, `click` for presses and releases, `drag` for those
--   and moves while a button is down, or `move` for those and all moves
local function mouse_mode(self)
   return MOUSE_MODES[self.handle:mouse_mode()]
end


--- Set a property of the terminal, as `vterm_state_set_termprop` does.
-- A program sets properties with the sequences that it writes, and this sets them
-- as the program would have, which saves a test that stands in for the program from writing them.
-- Only the properties for what the program is told are supported so far.
-- @function set_termprop
-- @string name `mouse`, with a value of `none`, `click`, `drag` or `move`, as `mouse_mode`
--   gives, or `focusreport`, with a value of true or false
-- @param value the value of the property
-- @treturn Terminal the terminal
local function set_termprop(self, name, value)
   local prop = type(name) == 'string' and TERMPROPS[name]
   if not prop then
      error(format('unsupported property %s', tostring(name)), 2)
   end
   local number
   if name == 'mouse' then
      for n, mode in pairs(MOUSE_MODES) do
         if mode == value then
            number = n
         end
      end
      if not number then
         error(format('unknown mouse mode %s', tostring(value)), 2)
      end
   else
      if type(value) ~= 'boolean' then
         error(format('%s is not true or false', tostring(value)), 2)
      end
      number = value and 1 or 0
   end
   self.handle:set_termprop(prop, number)
   return self
end


--- Set a mode that libvterm has no call for, as the program would, by writing the sequence that it writes.
-- Unlike `set_termprop`, which wraps a call of libvterm, this is only for a test that stands in for the
-- program not to write the sequences.
-- @function set_mode
-- @string name `bracketed_paste` or `application_cursor_keys`, with a value of true or false, or
--   `mouse_encoding`, with a value of `x10`, `utf8`, `sgr` or `urxvt` for how the reports of the
--   mouse are written, which is `x10` until it is set
-- @param value the value of the mode
-- @treturn Terminal the terminal
local function set_mode(self, name, value)
   if name == 'mouse_encoding' then
      local code = ENCODINGS[value]
      if code == nil then
         error(format('unknown mouse encoding %s', tostring(value)), 2)
      end
      -- Each encoding replaces the one before it, as the last that was asked for is the one that is used.
      self.handle:write('\27[?1005l\27[?1006l\27[?1015l' .. (code and format('\27[?%dh', code) or ''))
   else
      local code = type(name) == 'string' and MODES[name]
      if not code then
         error(format('unknown mode %s', tostring(name)), 2)
      end
      if type(value) ~= 'boolean' then
         error(format('%s is not true or false', tostring(value)), 2)
      end
      self.handle:write(format('\27[?%d%s', code, value and 'h' or 'l'))
   end
   return self
end


--- Whether the program asked to be told when the terminal gains or loses the focus.
-- A program asks with `ESC [ ? 1004 h`, or `set_termprop` can for it, and
-- `focus_in` and `focus_out` send nothing until it has.
-- @function focus_reporting
-- @treturn bool
local function focus_reporting(self)
   return self.handle:focus_reporting()
end


--- Tell the program that the terminal gained the focus, if it asked to be told.
-- What is sent is taken with `output`.
-- @function focus_in
-- @treturn Terminal the terminal
local function focus_in(self)
   self.handle:focus_in()
   return self
end


--- Tell the program that the terminal lost the focus, if it asked to be told.
-- What is sent is taken with `output`.
-- @function focus_out
-- @treturn Terminal the terminal
local function focus_out(self)
   self.handle:focus_out()
   return self
end


--- Move the mouse, as the terminal would tell the program.
-- What is sent depends on what the program asked to hear, which `mouse_mode`
-- says, and on how it asked for the reports to be written. Take it with `output`.
-- @function mouse_move
-- @int row line that the mouse is over, from 0
-- @int col column that the mouse is over, from 0
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
local function mouse_move(self, row, col, mods)
   check(self, row, col)
   self.handle:mouse_move(row, col, modifiers(mods))
   return self
end


--- Press or release a mouse button, as the terminal would tell the program.
-- The press or release happens where `mouse_move` last put the mouse, and the
-- program is told of it if it asked to hear about it.
-- @function mouse_button
-- @string button `left`, `middle`, `right`, `wheelup`, `wheeldown`,
--   `wheelleft` or `wheelright`
-- @bool pressed true for a press, and false for a release, which a wheel does not have
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
local function mouse_button(self, button, pressed, mods)
   local code = type(button) == 'string' and BUTTONS[button]
   if not code then
      error(format('unknown button %s', tostring(button)), 2)
   end
   self.handle:mouse_button(code, pressed and true or false, modifiers(mods))
   return self
end


--- The title that the program set.
-- A program sets the title with `ESC ] 0 ; title BEL` or `ESC ] 2 ; title BEL`.
-- The title is the last complete one: a title that is still being written does
-- not count yet.
-- @function title
-- @treturn string|nil the title, which is nil if the program has not set one
local function title(self)
   return self.handle:title()
end


-- A color that is a table of `red`, `green` and `blue`, each from 0 to 255.
local function check_rgb(color, name)
   if type(color) ~= 'table' then
      error(format('%s is a table of red, green and blue, not %s', name, type(color)), 3)
   end
   for _, field in ipairs {'red', 'green', 'blue'} do
      local n = color[field]
      if type(n) ~= 'number' or n < 0 or n > 255 or n % 1 ~= 0 then
         error(format('%s has %s from 0 to 255', name, field), 3)
      end
   end
end


-- An index into the palette of 256 colors.
local function check_index(index)
   if index < 0 or index > 255 then
      error(format('an index into the palette is from 0 to 255, not %d', index), 3)
   end
end


--- The color that an index of the palette is.
-- The palette is the 256 colors that a program sets cells to with `ESC [ 38 ; 5`, and
-- the colors of a cell that is of one, as `cell` returns them, are an index into it.
-- @function palette_color
-- @int index the index, from 0 to 255
-- @treturn table `red`, `green` and `blue`
local function palette_color(self, index)
   check_index(index)
   return self.handle:palette_color(index)
end


--- Change the color that an index of the palette is.
-- @function set_palette_color
-- @int index the index, from 0 to 255
-- @tparam table color `red`, `green` and `blue`, each from 0 to 255
local function set_palette_color(self, index, color)
   check_index(index)
   check_rgb(color, 'a color')
   self.handle:set_palette_color(index, color)
   return self
end


--- The colors that cells are drawn in when the program has not set them.
-- A cell of those colors has a `fg` or `bg` of nil, as `cell` returns it.
-- @function default_colors
-- @treturn table foreground, with `red`, `green` and `blue`
-- @treturn table background
local function default_colors(self)
   return self.handle:default_colors()
end


--- Change the colors that cells are drawn in when the program has not set them.
-- @function set_default_colors
-- @tparam[opt] table fg foreground, with `red`, `green` and `blue`, which is kept as it is if it is nil
-- @tparam[opt] table bg background, which is kept as it is if it is nil
local function set_default_colors(self, fg, bg)
   local oldfg, oldbg = self.handle:default_colors()
   if fg ~= nil then
      check_rgb(fg, 'the foreground')
   end
   if bg ~= nil then
      check_rgb(bg, 'the background')
   end
   self.handle:set_default_colors(fg or oldfg, bg or oldbg)
   return self
end


--- Whether bold text is drawn in the bright color of its palette index.
-- @function set_bold_highbright
-- @bool on true to draw it so
local function set_bold_highbright(self, on)
   self.handle:set_bold_highbright(on and true or false)
   return self
end


-- The letters that stand for the selections in the sequence for the selection, in the order of the bits of libvterm.
local SELECTIONS = 'cpqs01234567'

-- The letters of a mask of the bits of the selections.
local function letters(mask)
   local out = {}
   for i = 1, #SELECTIONS do
      local bit = 2 ^ (i - 1)
      if mask % (2 * bit) >= bit then
         out[#out + 1] = sub(SELECTIONS, i, i)
      end
   end
   return concat(out)
end

-- The mask of the bits of the selections that the letters stand for.
local function bits(names)
   local mask = 0
   for letter in gmatch(names, '.') do
      local i = find(SELECTIONS, letter, 1, true)
      if not i then
         error(format('a selection is one of the letters `%s`, not `%s`', SELECTIONS, letter), 3)
      end
      mask = mask + 2 ^ (i - 1)
   end
   return mask
end


--- Take the sequences for the selection that the program wrote.
-- A program that copies text to the clipboard of its terminal, or reads what it has (OSC 52), writes
-- sequences that only a terminal that is made with `selections = true` keeps; others discard them.
-- Each is a table with a `kind`, and the `mask` that is the letters of the sequence for the selections,
-- which are `c` for the clipboard, `p` for the primary selection, `q` for the secondary, `s` for the
-- selection, and `0` to `7` for the cut buffers:
--
--  * `'set'`: the program set the selections to `text`.
--  * `'query'`: a sequence that reads what the selections are, which `send_selection` replies to.
--
-- At most 64 are kept until they are taken, and the oldest are dropped after that.
-- @function selections
-- @treturn table the selections, oldest first, which are removed from the terminal
-- @usage
--    local term = lvterm.new(24, 80, {selections = true})
--    term:write '\27]52;c;aGVsbG8=\27\\'
--    term:selections()  --> {{kind = 'set', mask = 'c', text = 'hello'}}
local function selections(self)
   local out = self.handle:selections()
   for _, s in ipairs(out) do
      s.mask = letters(s.mask)
   end
   return out
end


--- Write the reply to a sequence that reads the selection.
-- @function send_selection
-- @string mask the letters of the selections that the reply is for, such as `'c'`
-- @string text what the selection is
local function send_selection(self, mask, text)
   self.handle:send_selection(bits(mask), text)
   return self
end


--- Take the sequences that the program wrote that libvterm does not recognise.
-- A terminal that is made with `unrecognised = true` keeps the control characters, escape sequences
-- and strings that libvterm does not handle, so that a caller can act on those that it handles, such
-- as the one that reports the directory of a shell (OSC 7).  Each is a table with a `kind`:
--
--  * `'control'`: a control character, as `byte`.
--  * `'csi'`: a control sequence, with its `leader`, which is `''` or a character such as `'?'`,
--    its numbers in `args`, which are `false` for one that is left out, a list of booleans in `more`
--    that are true for each that is followed by one that is a part of it, after a colon, its
--    `intermediate` characters and its `command` letter.
--  * `'osc'`: an operating system command, with its `command` number and its `text`.
--  * `'dcs'`: a device control string, with its `command` and its `text`.
--  * `'apc'`, `'pm'` and `'sos'`: those strings, with their `text`.
--
-- At most 256 are kept until they are taken, and the oldest are dropped after that.
-- @function unrecognised
-- @treturn table the sequences, oldest first, which are removed from the terminal
-- @usage
--    local term = lvterm.new(24, 80, {unrecognised = true})
--    term:write '\27]7;file:///tmp\7'
--    term:unrecognised() --> {{kind = 'osc', command = 7, text = 'file:///tmp'}}
local function unrecognised(self)
   return self.handle:unrecognised()
end


--- What the program set the attributes of what it writes next to.
-- This is the pen that draws what is written next, and is not what a cell that is already there is.
-- @function pen
-- @treturn table `bold`, `italic`, `blink`, `reverse`, `conceal` and `strike` as booleans, `underline`
--   as 0 for none, 1 for single, 2 for double and 3 for curly, `font` from 0 to 9, and
--   `fg` and `bg` as a cell has them
local function pen(self)
   return self.handle:pen()
end


--- What a line of the screen is, as a program made it with the sequences for the width of a line.
-- @function line_info
-- @int row the line, from 0
-- @treturn table `doublewidth`, which is true for a line of characters that are twice as wide,
--   `doubleheight`, which is nil, `'top'` or `'bottom'` for the halves of a line of characters
--   that are twice as high, and `continuation`, which is true for a line that is the rest of the line
--   above it, which was too long for the screen
local function line_info(self, row)
   check(self, row, 0)
   return self.handle:line_info(row)
end


--- Whether there is nothing but blanks from a cell to the end of its line.
-- @function is_eol
-- @int row the line, from 0
-- @int col the column, from 0
-- @treturn bool true if there is not
local function is_eol(self, row, col)
   check(self, row, col)
   return self.handle:is_eol(row, col)
end


--- Whether a line that is too long for the screen is made again when its width changes.
-- A terminal that does this joins the lines that were made by the width of the screen, and
-- divides them again for the new one, when it is `resize`d, as many terminals do.
-- @function set_reflow
-- @bool on true to make it again
local function set_reflow(self, on)
   self.handle:set_reflow(on and true or false)
   return self
end


--- Take what has changed on the screen since the last call.
-- A terminal that is made with `changes = true` keeps what a program changes on
-- its screen, in order, until they are taken, so that a program that draws the
-- screen again can leave what is the same as it was.  Each change is a table
-- with a `kind`, and positions that are from 0, like the others:
--
--  * `'damage'`: the cells of the rectangle that begins at `row` and `col`, and
--    is `rows` high and `cols` wide, have changed.
--  * `'move'`: the cells that were at `from_row` and `from_col` are now where
--    the rectangle that begins at `row` and `col`, and is `rows` high and `cols`
--    wide, is, as when the screen scrolls.  Each scroll is one move, and the lines
--    that it made are damaged after it, so that the changes in order, done to a
--    copy of the screen, reproduce the screen.
--  * `'cursor'`: the cursor is at `row` and `col`, which it was at `from_row`
--    and `from_col` when the changes were last taken, and `visible` is whether
--    it is shown.  It is the last, and only if the cursor is not where it was.
--
-- The most that are kept until they are taken is 1024 of damage and moves,
-- after which they are one change of all of the screen.  The size of the terminal being changed, or
-- the terminal being reset, is a change of all of it.
-- @function changes
-- @treturn table the changes, which are removed from the terminal
-- @usage
--    local term = lvterm.new(24, 80, {changes = true})
--    term:write 'hello\n'
--    for _, change in ipairs(term:changes()) do
--       print(change.kind, change.row, change.col)
--    end
local function changes(self)
   return self.handle:changes()
end


--- Take how many times the program rang the bell.
-- @function bells
-- @treturn int the bells since the last call, which the terminal forgets
local function bells(self)
   return self.handle:bells()
end


--- Take what the terminal has to send back to the program.
-- A terminal answers some of the sequences that it is given, such as a
-- request for the position of the cursor, and `key`, `char`, `paste`, `mouse_move`
-- and `mouse_button` events that the program is sent.
-- @function output
-- @treturn string the bytes, which the terminal forgets
local function output(self)
   return self.handle:output()
end



--[[ ================= ]]--
--[[ Public Interface. ]]--
--[[ ================= ]]--


-- The methods of a terminal, whose arguments are checked, if typecheck is
-- installed, with the type of `self` first, as it is the first argument of
-- the function that is wrapped.
local Terminal = {
   write = argscheck('lvterm.terminal.write (table, string)', write),
   resize = argscheck('lvterm.terminal.resize (table, int, int)', resize),
   reset = argscheck('lvterm.terminal.reset (table, <?boolean>)', reset),
   size = argscheck('lvterm.terminal.size (table)', size),
   cursor = argscheck('lvterm.terminal.cursor (table)', cursor),
   cell = argscheck('lvterm.terminal.cell (table, int, int)', cell),
   runs = argscheck('lvterm.terminal.runs (table, int)', runs),
   text = argscheck('lvterm.terminal.text (table, int, <?int>, <?int>)', text),
   row = argscheck('lvterm.terminal.row (table, int)', row),
   lines = argscheck('lvterm.terminal.lines (table)', lines),
   scrollback_size = argscheck('lvterm.terminal.scrollback_size (table)', scrollback_size),
   scrollback_line = argscheck('lvterm.terminal.scrollback_line (table, int)', scrollback_line),
   scrollback_runs = argscheck('lvterm.terminal.scrollback_runs (table, int)', scrollback_runs),
   scrollback_clear = argscheck('lvterm.terminal.scrollback_clear (table)', scrollback_clear),
   altscreen = argscheck('lvterm.terminal.altscreen (table)', altscreen),
   cursor_visible = argscheck('lvterm.terminal.cursor_visible (table)', cursor_visible),
   key = argscheck('lvterm.terminal.key (table, string, <?table>)', key),
   char = argscheck('lvterm.terminal.char (table, int, <?table>)', char),
   paste = argscheck('lvterm.terminal.paste (table, string)', paste),
   mouse_mode = argscheck('lvterm.terminal.mouse_mode (table)', mouse_mode),
   set_termprop = argscheck('lvterm.terminal.set_termprop (table, string, ?any)', set_termprop),
   set_mode = argscheck('lvterm.terminal.set_mode (table, string, ?any)', set_mode),
   focus_reporting = argscheck('lvterm.terminal.focus_reporting (table)', focus_reporting),
   focus_in = argscheck('lvterm.terminal.focus_in (table)', focus_in),
   focus_out = argscheck('lvterm.terminal.focus_out (table)', focus_out),
   mouse_move = argscheck('lvterm.terminal.mouse_move (table, int, int, <?table>)', mouse_move),
   mouse_button = argscheck('lvterm.terminal.mouse_button (table, string, ?boolean, <?table>)', mouse_button),
   title = argscheck('lvterm.terminal.title (table)', title),
   bells = argscheck('lvterm.terminal.bells (table)', bells),
   changes = argscheck('lvterm.terminal.changes (table)', changes),
   selections = argscheck('lvterm.terminal.selections (table)', selections),
   send_selection = argscheck('lvterm.terminal.send_selection (table, string, string)', send_selection),
   unrecognised = argscheck('lvterm.terminal.unrecognised (table)', unrecognised),
   pen = argscheck('lvterm.terminal.pen (table)', pen),
   line_info = argscheck('lvterm.terminal.line_info (table, int)', line_info),
   is_eol = argscheck('lvterm.terminal.is_eol (table, int, int)', is_eol),
   set_reflow = argscheck('lvterm.terminal.set_reflow (table, <?boolean>)', set_reflow),
   palette_color = argscheck('lvterm.terminal.palette_color (table, int)', palette_color),
   set_palette_color = argscheck('lvterm.terminal.set_palette_color (table, int, table)', set_palette_color),
   default_colors = argscheck('lvterm.terminal.default_colors (table)', default_colors),
   set_default_colors = argscheck('lvterm.terminal.set_default_colors (table, <?table>, <?table>)', set_default_colors),
   set_bold_highbright = argscheck('lvterm.terminal.set_bold_highbright (table, <?boolean>)', set_bold_highbright),
   output = argscheck('lvterm.terminal.output (table)', output),
}
Terminal.__index = Terminal


--- Make a terminal over a handle.
-- @function new
-- @param handle what a backend made, for the given size
-- @int rows height in lines
-- @int cols width in columns
-- @treturn Terminal
local function new(handle, rows, cols)
   return setmetatable({handle = handle, rows = rows, cols = cols}, Terminal)
end


--- @export
return {
   new = new,
}
