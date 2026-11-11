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
   format = string.format,
   pairs = pairs,
   pcall = pcall,
   require = require,
   setmetatable = setmetatable,
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


--- Feed bytes to the terminal, as a program writes them.
-- @function write
-- @string bytes what the terminal receives
-- @treturn Terminal the terminal
local function write(self, bytes)
   self.handle:write(bytes)
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
