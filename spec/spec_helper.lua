--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]

do
   local std = require 'specl.std'

   -- Run the Lua modules from this tree, for coverage, and `lvterm.config`
   -- from the rock that `luarocks make` installed.
   package.path = std.package.normalize(
      './lib/?.lua',
      './lib/?/init.lua',
      package.path
   )
end


-- Both backends, where the host has them, to compare one with the other.
local terminal = require 'lvterm.terminal'
local have_ffi, ffi_backend = pcall(require, 'lvterm.ffi')
local have_core, core_backend = pcall(require, 'lvterm.core')
both_backends = have_ffi and have_core


local function same_color(a, b)
   if type(a) == 'table' and type(b) == 'table' then
      return a.red == b.red and a.green == b.green and a.blue == b.blue
   end
   return a == b
end

local FIELDS = {
   'text', 'width', 'bold', 'italic', 'blink', 'reverse', 'conceal', 'strike',
   'underline',
}


--- What the `ffi` and `core` backends disagree about.
-- Each is made a terminal of the same size, fed the same bytes, then
-- resized, and fed more, and their screens, cursors and replies compared.
-- @string stream what to write to both
-- @int[opt=24] rows height in lines
-- @int[opt=80] cols width in columns
-- @string[opt] more written after resizing to `resize`
-- @tparam[opt] {int,int} resize new height and width, between the writes
-- @treturn {string,...} descriptions of the differences, none if the same
function differences(stream, rows, cols, more, resize)
   rows, cols = rows or 24, cols or 80

   local a = terminal.new(ffi_backend.new(rows, cols), rows, cols)
   local b = terminal.new(core_backend.new(rows, cols), rows, cols)
   a:write(stream)
   b:write(stream)
   if resize then
      a:resize(resize[1], resize[2])
      b:resize(resize[1], resize[2])
      rows, cols = resize[1], resize[2]
   end
   if more then
      a:write(more)
      b:write(more)
   end

   local diffs = {}
   local ar, ac = a:cursor()
   local br, bc = b:cursor()
   if ar ~= br or ac ~= bc then
      diffs[#diffs + 1] = string.format('cursor %d,%d against %d,%d', ar, ac, br, bc)
   end
   if a:output() ~= b:output() then
      diffs[#diffs + 1] = 'output'
   end

   for row = 0, rows - 1 do
      for col = 0, cols - 1 do
         local x, y = a:cell(row, col), b:cell(row, col)
         for _, field in ipairs(FIELDS) do
            if x[field] ~= y[field] then
               diffs[#diffs + 1] = string.format('%d,%d %s', row, col, field)
            end
         end
         for _, field in ipairs {'fg', 'bg'} do
            if not same_color(x[field], y[field]) then
               diffs[#diffs + 1] = string.format('%d,%d %s', row, col, field)
            end
         end
      end
   end
   if a:altscreen() ~= b:altscreen() then
      diffs[#diffs + 1] = 'altscreen'
   end
   if a:cursor_visible() ~= b:cursor_visible() then
      diffs[#diffs + 1] = 'cursor_visible'
   end

   if a:scrollback_size() ~= b:scrollback_size() then
      diffs[#diffs + 1] = string.format('scrollback size %d against %d', a:scrollback_size(), b:scrollback_size())
   else
      for n = 1, a:scrollback_size() do
         local x, y = a:scrollback_line(n), b:scrollback_line(n)
         if #x ~= #y then
            diffs[#diffs + 1] = string.format('scrollback %d width', n)
         else
            for col = 1, #x do
               for _, field in ipairs(FIELDS) do
                  if x[col][field] ~= y[col][field] then
                     diffs[#diffs + 1] = string.format('scrollback %d,%d %s', n, col, field)
                  end
               end
               for _, field in ipairs {'fg', 'bg'} do
                  if not same_color(x[col][field], y[col][field]) then
                     diffs[#diffs + 1] = string.format('scrollback %d,%d %s', n, col, field)
                  end
               end
            end
         end
      end
   end
   return diffs
end


--- What the `ffi` and `core` backends send for the keys, characters and pastes.
-- Each is made a terminal, fed the same bytes, and then asked for every
-- key with every combination of modifiers, and some characters and pastes.
-- @string stream what to write to both first, such as a mode to set
-- @treturn {string,...} descriptions of the differences, none if the same
function input_differences(stream)
   local a = terminal.new(ffi_backend.new(5, 20), 5, 20)
   local b = terminal.new(core_backend.new(5, 20), 5, 20)
   a:write(stream)
   b:write(stream)
   a:output()
   b:output()

   local names = {'enter', 'tab', 'backspace', 'escape', 'up', 'down', 'left', 'right',
                  'insert', 'delete', 'home', 'end', 'pageup', 'pagedown'}
   for n = 1, 12 do
      names[#names + 1] = 'f' .. n
   end

   local diffs = {}
   for _, name in ipairs(names) do
      for mask = 0, 7 do
         local mods = {shift = mask % 2 == 1, alt = math.floor(mask / 2) % 2 == 1,
                       ctrl = math.floor(mask / 4) % 2 == 1}
         a:key(name, mods)
         b:key(name, mods)
         if a:output() ~= b:output() then
            diffs[#diffs + 1] = string.format('key %s %d', name, mask)
         end
      end
   end

   for _, cp in ipairs {0x20, 0x41, 0x61, 0x7a, 0x5b, 0x5c, 0x5d, 0x5e, 0x5f, 0x69, 0x6a, 0x6d,
                        0xe9, 0x4e2d, 0x1f600, 0x31, 0x40} do
      for mask = 0, 7 do
         local mods = {shift = mask % 2 == 1, alt = math.floor(mask / 2) % 2 == 1,
                       ctrl = math.floor(mask / 4) % 2 == 1}
         a:char(cp, mods)
         b:char(cp, mods)
         if a:output() ~= b:output() then
            diffs[#diffs + 1] = string.format('char %x %d', cp, mask)
         end
      end
   end

   for _, text in ipairs {'', 'x', 'hello\nthere', '\0\255\27', string.rep('abcdefghij', 3000)} do
      a:paste(text)
      b:paste(text)
      if a:output() ~= b:output() then
         diffs[#diffs + 1] = string.format('paste of %d bytes', #text)
      end
   end
   return diffs
end


--- A stream of bytes that exercises a terminal, the same every time.
-- @int n how many pieces of output
-- @treturn string
function noise(n)
   local pieces = {
      'hello', ' ', 'x', '\r\n', '\n', '\t', '\b', '\27[H', '\27[2J', '\27[K',
      '\27[1;31m', '\27[0m', '\27[4m', '\27[7m', '\27[38;5;202m',
      '\27[48;2;10;200;30m', '\27[3A', '\27[2B', '\27[5C', '\27[4D',
      '\27[2;7r', '\27[3L', '\27[2M', '\27[3@', '\27[2P', '\27[2X',
      '\27(0lqqk\27(B', '\227\130\162', 'e\204\129', '\228\184\173',
      '\27[?1049h', '\27[?1049l', '\27[s', '\27[u', '\27M', '\27D', '\27E',
      '\27[6n', '\27[c', '\27[?25l', '\27[?25h', '\27[?7l', '\27[?7h',
   }

   local state, out = 12345, {}
   for i = 1, n do
      state = (state * 1103515245 + 12345) % 2147483648
      out[i] = pieces[state % #pieces + 1]
   end
   return table.concat(out)
end
