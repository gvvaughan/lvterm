--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--- A virtual terminal, over the handle that a backend makes.
--
-- A backend makes a handle, which has `write`, `resize`, `reset`, `cursor`,
-- `cell` and `output` methods, and nothing else, so that terminals made by
-- any backend behave the same.  The `Terminal` here checks positions, and
-- reads text, once, for all of them.
--
-- @module lvterm.terminal

local Terminal = {}
Terminal.__index = Terminal


-- Raise an error unless ROW and COL are on the screen of the TERMINAL.
local function check(terminal, row, col)
   if row < 0 or row >= terminal.rows or col < 0 or col >= terminal.cols then
      error(string.format('position %d,%d is outside a screen of %d,%d',
                          row, col, terminal.rows, terminal.cols), 3)
   end
end


local M = {}


--- Make a terminal over a handle.
-- @param handle what a backend made, for the given size
-- @int rows height in lines
-- @int cols width in columns
-- @treturn Terminal
function M.new(handle, rows, cols)
   return setmetatable({handle = handle, rows = rows, cols = cols}, Terminal)
end


--- A virtual terminal.
-- Rows and columns are numbered from 0, like the arguments of curses.
-- @type Terminal

--- Feed bytes to the terminal, as a program writes them.
-- @string bytes what the terminal receives
-- @treturn Terminal the terminal
function Terminal:write(bytes)
   self.handle:write(bytes)
   return self
end


--- Change the size of the terminal.
-- @int rows new height in lines
-- @int cols new width in columns
-- @treturn Terminal the terminal
function Terminal:resize(rows, cols)
   self.handle:resize(rows, cols)
   self.rows, self.cols = rows, cols
   return self
end


--- Return the terminal to its initial state.
-- @bool[opt=true] hard also forget the contents of the screen
-- @treturn Terminal the terminal
function Terminal:reset(hard)
   self.handle:reset(hard ~= false)
   return self
end


--- The size of the terminal.
-- @treturn int height in lines
-- @treturn int width in columns
function Terminal:size()
   return self.rows, self.cols
end


--- Where the cursor is.
-- @treturn int row
-- @treturn int column
function Terminal:cursor()
   return self.handle:cursor()
end


--- What one cell of the screen shows.
-- @int row line to read, from 0
-- @int col column to read, from 0
-- @treturn table fields `text` (the characters, a space when the cell is
--   empty, and the empty string for the right half of a wide character),
--   `width` (columns, 1 or 2), `bold`, `italic`, `blink`, `reverse`,
--   `conceal` and `strike` (booleans), `underline` (0 for none, 1 single,
--   2 double, 3 curly), and `fg` and `bg`, each `nil` for the default, an
--   index into the 256 color palette, or a table of `red`, `green` and
--   `blue`
function Terminal:cell(row, col)
   check(self, row, col)
   return self.handle:cell(row, col)
end


--- Some of the text on the screen, from one row.
-- @int row line to read, from 0
-- @int[opt=0] col first column to read, from 0
-- @int[opt] n how many columns to read, to the end of the line by default
-- @treturn string the text, a space for each empty cell, and so exactly
--   as wide as the columns that it was asked for
function Terminal:text(row, col, n)
   col = col or 0
   n = n or self.cols - col
   check(self, row, col)
   if n < 1 or col + n > self.cols then
      error(string.format('%d columns from column %d is outside a screen of %d columns',
                          n, col, self.cols), 2)
   end

   local chars = {}
   for c = col, col + n - 1 do
      chars[#chars + 1] = self.handle:cell(row, c).text
   end
   return table.concat(chars)
end


--- A whole row of the screen.
-- @int row line to read, from 0
-- @treturn string the text, as wide as the screen
function Terminal:row(row)
   return self:text(row)
end


--- Every row of the screen.
-- @treturn {string,...} the rows, from the top
function Terminal:lines()
   local lines = {}
   for row = 0, self.rows - 1 do
      lines[#lines + 1] = self:text(row)
   end
   return lines
end


--- How many lines have scrolled off the top of the screen.
-- Only the main screen scrolls back: the alternate screen does not.
-- @treturn int the number of lines in the scrollback
function Terminal:scrollback_size()
   return self.handle:scrollback_size()
end


--- A line that scrolled off the top of the screen.
-- @int n which line, from 1 for the newest to `scrollback_size` for the oldest
-- @treturn {table,...} a cell for each column of the line as it was, of the
--   kind that `cell` gives
function Terminal:scrollback_line(n)
   local size = self.handle:scrollback_size()
   if type(n) ~= 'number' or n < 1 or n > size or n % 1 ~= 0 then
      error(string.format('line %s is outside a scrollback of %d lines', tostring(n), size), 2)
   end
   return self.handle:scrollback_line(n)
end


--- Forget the scrollback.
-- @treturn Terminal the terminal
function Terminal:scrollback_clear()
   self.handle:scrollback_clear()
   return self
end


--- Whether the program is on the alternate screen.
-- @treturn bool true after it switched to it, and false after it switched back
function Terminal:altscreen()
   return self.handle:altscreen()
end


--- Whether the program has the cursor shown.
-- @treturn bool false after the program hid the cursor, and true after it showed it
function Terminal:cursor_visible()
   return self.handle:cursor_visible()
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


--- Press a key, as the terminal would send it to the program.
-- What is sent depends on the modes that the program has set, such as the
-- cursor keys, and is taken with `output`.
-- @string name `enter`, `tab`, `backspace`, `escape`, `up`, `down`, `left`,
--   `right`, `insert`, `delete`, `home`, `end`, `pageup`, `pagedown`, or `f1` to `f12`
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
function Terminal:key(name, mods)
   local code = type(name) == 'string' and KEYS[name]
   if not code then
      error(string.format('unknown key %s', tostring(name)), 2)
   end
   self.handle:key(code, modifiers(mods))
   return self
end


--- Type a character, as the terminal would send it to the program.
-- @int cp the code point of the character
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
function Terminal:char(cp, mods)
   if type(cp) ~= 'number' or cp < 0 or cp > 0x10FFFF or cp % 1 ~= 0 then
      error(string.format('%s is not a character', tostring(cp)), 2)
   end
   self.handle:char(cp, modifiers(mods))
   return self
end


--- Paste text, as the terminal would send it to the program.
-- The text is sent as it is, between the marks that tell the program where
-- a paste starts and ends if the program asked for them.
-- @string text what is pasted, which may be any bytes
-- @treturn Terminal the terminal
function Terminal:paste(text)
   self.handle:paste(text)
   return self
end


-- The numbers that libvterm gives to the mouse buttons.
local BUTTONS = {left = 1, middle = 2, right = 3, wheelup = 4, wheeldown = 5, wheelleft = 6, wheelright = 7}

-- What the program can ask to be told about the mouse, by the number that libvterm has.
local MOUSE_MODES = {[0] = 'none', 'click', 'drag', 'move'}


--- What the program asked to be told about the mouse.
-- It is turned on by the program with a sequence such as `ESC [ ? 1000 h`, and
-- `mouse_move` and `mouse_button` send nothing until it is.
-- @treturn string `none`, `click` for presses and releases, `drag` for those
--   and moves while a button is down, or `move` for those and all moves
function Terminal:mouse_mode()
   return MOUSE_MODES[self.handle:mouse_mode()]
end


-- The properties that `set_termprop` sets, by the name that libvterm has for each without `VTERM_PROP_`,
-- and the number that it has for it.
local TERMPROPS = {mouse = 8, focusreport = 9}


--- Set a property of the terminal, as `vterm_state_set_termprop` does.
-- A program sets properties with the sequences that it writes, and this sets them
-- as the program would have, which saves a test that stands in for the program from writing them.
-- Only the properties for what the program is told are supported so far.
-- @string name `mouse`, with a value of `none`, `click`, `drag` or `move`, as `mouse_mode`
--   gives, or `focusreport`, with a value of true or false
-- @param value the value of the property
-- @treturn Terminal the terminal
function Terminal:set_termprop(name, value)
   local prop = type(name) == 'string' and TERMPROPS[name]
   if not prop then
      error(string.format('unsupported property %s', tostring(name)), 2)
   end
   local number
   if name == 'mouse' then
      for n, mode in pairs(MOUSE_MODES) do
         if mode == value then
            number = n
         end
      end
      if not number then
         error(string.format('unknown mouse mode %s', tostring(value)), 2)
      end
   else
      if type(value) ~= 'boolean' then
         error(string.format('%s is not true or false', tostring(value)), 2)
      end
      number = value and 1 or 0
   end
   self.handle:set_termprop(prop, number)
   return self
end


--- Whether the program asked to be told when the terminal gains or loses the focus.
-- A program asks with `ESC [ ? 1004 h`, or `set_termprop` can for it, and
-- `focus_in` and `focus_out` send nothing until it has.
-- @treturn bool
function Terminal:focus_reporting()
   return self.handle:focus_reporting()
end


--- Tell the program that the terminal gained the focus, if it asked to be told.
-- What is sent is taken with `output`.
-- @treturn Terminal the terminal
function Terminal:focus_in()
   self.handle:focus_in()
   return self
end


--- Tell the program that the terminal lost the focus, if it asked to be told.
-- What is sent is taken with `output`.
-- @treturn Terminal the terminal
function Terminal:focus_out()
   self.handle:focus_out()
   return self
end


--- Move the mouse, as the terminal would tell the program.
-- What is sent depends on what the program asked for with `mouse_mode`, and
-- how it asked for it to be written, and is taken with `output`.
-- @int row line that the mouse is over, from 0
-- @int col column that the mouse is over, from 0
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
function Terminal:mouse_move(row, col, mods)
   check(self, row, col)
   self.handle:mouse_move(row, col, modifiers(mods))
   return self
end


--- Press or release a mouse button, as the terminal would tell the program.
-- The button is at the place that `mouse_move` last gave, and the program
-- is told at once of a press or release if it asked for them.
-- @string button `left`, `middle`, `right`, `wheelup`, `wheeldown`,
--   `wheelleft` or `wheelright`
-- @bool pressed true for a press, and false for a release, which a wheel does not have
-- @tparam[opt] table mods which modifiers are held, `shift`, `alt` and `ctrl`
-- @treturn Terminal the terminal
function Terminal:mouse_button(button, pressed, mods)
   local code = type(button) == 'string' and BUTTONS[button]
   if not code then
      error(string.format('unknown button %s', tostring(button)), 2)
   end
   self.handle:mouse_button(code, pressed and true or false, modifiers(mods))
   return self
end


--- The title that the program set.
-- It is set by the program with `ESC ] 0 ; title BEL` or `ESC ] 2 ; title BEL`,
-- and is the last whole one, so one that is still being written is not it.
-- @treturn string|nil the title, which is nil if the program has not set one
function Terminal:title()
   return self.handle:title()
end


--- Take how many times the program rang the bell.
-- @treturn int the bells since the last call, which the terminal forgets
function Terminal:bells()
   return self.handle:bells()
end


--- Take what the terminal has to send back to the program.
-- A terminal answers some of the sequences that it is given, such as a
-- request for the position of the cursor, and `key`, `char`, `paste`, `mouse_move`
-- and `mouse_button` events that the program is sent.
-- @treturn string the bytes, which the terminal forgets
function Terminal:output()
   return self.handle:output()
end


return M
