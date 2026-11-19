--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]

do
   local std = require 'specl.std'

   -- Run the Lua modules from this tree, for coverage, and `lvterm.core`
   -- from the rock that `luarocks make` installed.
   package.path = std.package.normalize(
      './lib/?.lua',
      './lib/?/init.lua',
      package.path
   )
end


-- Argument checks need typecheck, so skip their examples without it.  Specl
-- gives the example environment to badargs.diagnose, so pass it on to the real
-- diagnose, which defines its examples there.
local have_typecheck = pcall(require, 'typecheck')
badargs = require 'specl.badargs'

local _diagnose = badargs.diagnose
local function diagnose(...)
   if have_typecheck then
      setfenv(_diagnose, getfenv(diagnose))
      return _diagnose(...)
   end
end
badargs.diagnose = diagnose


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


-- What two lists of runs disagree about.
local function run_differences(x, y)
   local diffs = {}
   if #x ~= #y then
      diffs[#diffs + 1] = string.format('count %d against %d', #x, #y)
      return diffs
   end
   for i = 1, #x do
      for _, field in ipairs {'col', 'cols', 'text', 'bold', 'italic', 'blink', 'reverse', 'conceal',
                              'strike', 'underline'} do
         if x[i][field] ~= y[i][field] then
            diffs[#diffs + 1] = string.format('run %d %s', i, field)
         end
      end
      for _, field in ipairs {'fg', 'bg'} do
         if not same_color(x[i][field], y[i][field]) then
            diffs[#diffs + 1] = string.format('run %d %s', i, field)
         end
      end
   end
   return diffs
end


-- The changes that a terminal has kept, as text that can be compared, one for each change.
local function described(term)
   local out = {}
   for i, c in ipairs(term:changes()) do
      out[i] = string.format('%s %s,%s %sx%s from %s,%s %s', c.kind, c.row, c.col, c.rows, c.cols, c.from_row, c.from_col,
                             tostring(c.visible))
   end
   return out
end


--- What the `ffi` and `core` backends disagree about the sequences that libvterm does not recognise.
-- Each is made a terminal that keeps them, fed the same bytes, and what each has is compared.
-- @string stream what to write to both
-- @treturn {string,...} descriptions of the differences, none if the same
function unrecognised_differences(stream)
   local a = terminal.new(ffi_backend.new(3, 20, {unrecognised = true}), 3, 20)
   local b = terminal.new(core_backend.new(3, 20, {unrecognised = true}), 3, 20)
   a:write(stream)
   b:write(stream)
   local function flat(v)
      if type(v) ~= 'table' then
         return tostring(v)
      end
      local keys = {}
      for k in pairs(v) do
         keys[#keys + 1] = tostring(k)
      end
      table.sort(keys)
      local out = {}
      for _, k in ipairs(keys) do
         local value = v[k] ~= nil and v[k] or v[tonumber(k)]
         out[#out + 1] = k .. '=' .. flat(value)
      end
      return '{' .. table.concat(out, ',') .. '}'
   end
   local diffs = {}
   local x, y = a:unrecognised(), b:unrecognised()
   if #x ~= #y then
      diffs[#diffs + 1] = string.format('%d sequences against %d', #x, #y)
   end
   for i = 1, math.min(#x, #y) do
      if flat(x[i]) ~= flat(y[i]) then
         diffs[#diffs + 1] = 'sequence ' .. i
      end
   end
   return diffs
end


--- What the `ffi` and `core` backends disagree about the state of a terminal.
-- Each is made a terminal, fed the same bytes, with reflow on or off, and then resized,
-- and the pen, the information of each line and where each line ends compared.
-- @string stream what to write to both
-- @int[opt=6] rows height in lines
-- @int[opt=20] cols width in columns
-- @bool[opt] reflow whether lines are made again when the width changes
-- @tparam[opt] {int,int} resize new height and width, after the stream
-- @treturn {string,...} descriptions of the differences, none if the same
function state_differences(stream, rows, cols, reflow, resize)
   rows, cols = rows or 6, cols or 20
   local a = terminal.new(ffi_backend.new(rows, cols), rows, cols)
   local b = terminal.new(core_backend.new(rows, cols), rows, cols)
   for _, t in ipairs {a, b} do
      t:set_reflow(reflow or false)
      t:write(stream)
      if resize then
         t:resize(resize[1], resize[2])
      end
   end
   if resize then
      rows, cols = resize[1], resize[2]
   end
   local diffs = {}
   local x, y = a:pen(), b:pen()
   for _, field in ipairs {'bold', 'underline', 'italic', 'blink', 'reverse', 'conceal', 'strike', 'font'} do
      if x[field] ~= y[field] then
         diffs[#diffs + 1] = 'pen ' .. field
      end
   end
   for _, field in ipairs {'fg', 'bg'} do
      if not same_color(x[field], y[field]) then
         diffs[#diffs + 1] = 'pen ' .. field
      end
   end
   for row = 0, rows - 1 do
      local i, j = a:line_info(row), b:line_info(row)
      for _, field in ipairs {'doublewidth', 'doubleheight', 'continuation'} do
         if i[field] ~= j[field] then
            diffs[#diffs + 1] = string.format('line %d %s', row, field)
         end
      end
      for col = 0, cols - 1 do
         if a:is_eol(row, col) ~= b:is_eol(row, col) then
            diffs[#diffs + 1] = string.format('end of line at %d,%d', row, col)
         end
      end
   end
   return diffs
end


--- What the `ffi` and `core` backends disagree about the selections of a program.
-- Each is made a terminal that keeps them, fed the same bytes, then replies to
-- the query that there is, and what is taken and sent back is compared.
-- @string stream what to write to both
-- @treturn {string,...} descriptions of the differences, none if the same
function selection_differences(stream)
   local a = terminal.new(ffi_backend.new(3, 20, {selections = true}), 3, 20)
   local b = terminal.new(core_backend.new(3, 20, {selections = true}), 3, 20)
   a:write(stream)
   b:write(stream)
   local diffs = {}
   local x, y = a:selections(), b:selections()
   if #x ~= #y then
      diffs[#diffs + 1] = string.format('%d selections against %d', #x, #y)
   end
   for i = 1, math.min(#x, #y) do
      if x[i].kind ~= y[i].kind or x[i].mask ~= y[i].mask or x[i].text ~= y[i].text then
         diffs[#diffs + 1] = 'selection ' .. i
      end
   end
   a:send_selection('cp', 'answer')
   b:send_selection('cp', 'answer')
   if a:output() ~= b:output() then
      diffs[#diffs + 1] = 'the reply'
   end
   return diffs
end


--- What the `ffi` and `core` backends disagree about the colors of a terminal.
-- Each is made a terminal, which has some of its colors changed, and then
-- fed bytes that use them, and the palette, the defaults and the cells compared.
-- @string stream what to write to both
-- @treturn {string,...} descriptions of the differences, none if the same
function color_differences(stream)
   local a = terminal.new(ffi_backend.new(3, 20), 3, 20)
   local b = terminal.new(core_backend.new(3, 20), 3, 20)
   local diffs = {}
   local function same(x, y)
      return x.red == y.red and x.green == y.green and x.blue == y.blue
   end
   for _, t in ipairs {a, b} do
      t:set_palette_color(9, {red = 1, green = 2, blue = 3})
      t:set_default_colors({red = 4, green = 5, blue = 6}, {red = 7, green = 8, blue = 9})
      t:set_bold_highbright(true)
      t:write(stream)
   end
   for i = 0, 255 do
      if not same(a:palette_color(i), b:palette_color(i)) then
         diffs[#diffs + 1] = 'palette ' .. i
      end
   end
   local afg, abg = a:default_colors()
   local bfg, bbg = b:default_colors()
   if not (same(afg, bfg) and same(abg, bbg)) then
      diffs[#diffs + 1] = 'default colors'
   end
   for col = 0, 19 do
      local x, y = a:cell(0, col), b:cell(0, col)
      if x.fg ~= y.fg and not (type(x.fg) == 'table' and type(y.fg) == 'table' and same(x.fg, y.fg)) then
         diffs[#diffs + 1] = 'fg at ' .. col
      end
   end
   return diffs
end


--- What the `ffi` and `core` backends disagree about the changes of the screen.
-- Each is made a terminal that keeps its changes, fed the same bytes, then resized,
-- and fed more, and the changes that each has are compared after every step.
-- @string stream what to write to both
-- @int[opt=24] rows height in lines
-- @int[opt=80] cols width in columns
-- @string[opt] more written after resizing to `resize`
-- @tparam[opt] {int,int} resize new height and width, between the writes
-- @treturn {string,...} descriptions of the differences, none if the same
function change_differences(stream, rows, cols, more, resize)
   rows, cols = rows or 24, cols or 80

   local a = terminal.new(ffi_backend.new(rows, cols, {changes = true}), rows, cols)
   local b = terminal.new(core_backend.new(rows, cols, {changes = true}), rows, cols)
   local diffs = {}
   local function compare(step)
      local x, y = described(a), described(b)
      if #x ~= #y then
         diffs[#diffs + 1] = string.format('%s: %d changes against %d', step, #x, #y)
      end
      for i = 1, math.min(#x, #y) do
         if x[i] ~= y[i] then
            diffs[#diffs + 1] = string.format('%s, change %d: %s against %s', step, i, x[i], y[i])
         end
      end
   end

   a:write(stream)
   b:write(stream)
   compare 'the stream'
   if resize then
      a:resize(resize[1], resize[2])
      b:resize(resize[1], resize[2])
      compare 'the resize'
   end
   if more then
      a:write(more)
      b:write(more)
      compare 'the rest'
   end
   return diffs
end


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
      for _, d in ipairs(run_differences(a:runs(row), b:runs(row))) do
         diffs[#diffs + 1] = string.format('runs of row %d %s', row, d)
      end
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
   if a:title() ~= b:title() then
      diffs[#diffs + 1] = 'title'
   end
   if a:mouse_mode() ~= b:mouse_mode() then
      diffs[#diffs + 1] = 'mouse_mode'
   end
   if a:focus_reporting() ~= b:focus_reporting() then
      diffs[#diffs + 1] = 'focus_reporting'
   end
   if a:bells() ~= b:bells() then
      diffs[#diffs + 1] = 'bells'
   end

   if a:scrollback_size() ~= b:scrollback_size() then
      diffs[#diffs + 1] = string.format('scrollback size %d against %d', a:scrollback_size(), b:scrollback_size())
   else
      for n = 1, a:scrollback_size() do
         for _, d in ipairs(run_differences(a:scrollback_runs(n), b:scrollback_runs(n))) do
            diffs[#diffs + 1] = string.format('runs of scrollback %d %s', n, d)
         end
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
-- @tparam[opt] function setup what to call on both after that, with the terminal
-- @treturn {string,...} descriptions of the differences, none if the same
function input_differences(stream, setup)
   local a = terminal.new(ffi_backend.new(5, 20), 5, 20)
   local b = terminal.new(core_backend.new(5, 20), 5, 20)
   a:write(stream)
   b:write(stream)
   if setup then
      setup(a)
      setup(b)
   end
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

   for _, button in ipairs {'left', 'middle', 'right', 'wheelup', 'wheeldown', 'wheelleft', 'wheelright'} do
      for mask = 0, 7 do
         local mods = {shift = mask % 2 == 1, alt = math.floor(mask / 2) % 2 == 1,
                       ctrl = math.floor(mask / 4) % 2 == 1}
         for _, place in ipairs {{0, 0}, {2, 7}, {4, 19}} do
            for _, pressed in ipairs {true, false} do
               a:mouse_move(place[1], place[2], mods)
               b:mouse_move(place[1], place[2], mods)
               a:mouse_button(button, pressed, mods)
               b:mouse_button(button, pressed, mods)
               if a:output() ~= b:output() then
                  diffs[#diffs + 1] = string.format('mouse %s %d %d,%d %s', button, mask,
                                                    place[1], place[2], tostring(pressed))
               end
            end
         end
      end
   end

   for _, gained in ipairs {true, false, true} do
      a[gained and 'focus_in' or 'focus_out'](a)
      b[gained and 'focus_in' or 'focus_out'](b)
      if a:output() ~= b:output() then
         diffs[#diffs + 1] = string.format('focus %s', gained and 'in' or 'out')
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
