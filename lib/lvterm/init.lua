--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--- A virtual terminal, for testing programs that draw on one.
--
-- Feed a `Terminal` the bytes that a program writes, and ask what the
-- screen shows, and where the cursor is:
--
--     local lvterm = require 'lvterm'
--     local term = lvterm.new(24, 80)
--     term:write '\27[2;3Hhello'
--     term:text(1, 2, 5)   --> 'hello'
--     term:cursor()        --> 1, 7
--
-- libvterm emulates the terminal, called directly through the FFI of
-- LuaJIT where there is one (the `ffi` backend), and otherwise through a
-- thin C binding (the `core` backend).  The environment variable
-- `LVTERM_BACKEND`, set to `ffi` or `core`, makes `lvterm` use that backend
-- or fail, rather than fall back to another one, so that a test run is
-- certain of which it exercises.
--
-- @module lvterm

local terminal = require 'lvterm.terminal'

local wanted = os.getenv 'LVTERM_BACKEND'

local names = {'ffi', 'core'}
if wanted ~= nil and wanted ~= '' then
   names = {wanted}
end

local M = {}

local failures = {}
for _, name in ipairs(names) do
   local ok, backend = pcall(require, 'lvterm.' .. name)
   if ok then
      M.backend = backend.name
      M.handle = backend.new
      break
   end
   failures[#failures + 1] = name .. ': ' .. tostring(backend)
end

if M.handle == nil then
   error('no lvterm backend works on this host:\n  ' ..
         table.concat(failures, '\n  '), 2)
end


--- Which backend makes terminals here.
-- @field backend `'ffi'` or `'core'`

--- Make a new virtual terminal.
-- @int[opt=24] rows height in lines
-- @int[opt=80] cols width in columns
-- @tparam[opt] table options `scrollback`, the most lines to keep of those
--   that scroll off the top, which is as many as there is memory for if it
--   is not given, and none if it is 0
-- @treturn lvterm.terminal.Terminal
function M.new(rows, cols, options)
   rows, cols = rows or 24, cols or 80
   if rows < 1 or cols < 1 then
      error(string.format('a terminal needs positive rows and columns, not %d,%d',
                          rows, cols), 2)
   end
   local scrollback = options and options.scrollback
   if scrollback ~= nil and (type(scrollback) ~= 'number' or scrollback < 0 or scrollback % 1 ~= 0) then
      error(string.format('the scrollback of a terminal is a number of lines, not %s',
                          tostring(scrollback)), 2)
   end
   return terminal.new(M.handle(rows, cols, options), rows, cols)
end


return M
