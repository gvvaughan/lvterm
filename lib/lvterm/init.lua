--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 A virtual terminal, for testing programs that draw on one.

 Feed a `Terminal` the bytes that a program writes, and ask what the
 screen shows, and where the cursor is:

     local lvterm = require 'lvterm'
     local term = lvterm.new(24, 80)
     term:write '\27[2;3Hhello'
     term:text(1, 2, 5)   --> 'hello'
     term:cursor()        --> 1, 7

 libvterm emulates the terminal, called directly through the FFI of
 LuaJIT where there is one (the `ffi` backend), and otherwise through a
 thin C binding (the `core` backend).  The environment variable
 `LVTERM_BACKEND`, set to `ffi` or `core`, makes `lvterm` use that backend
 or fail, rather than fall back to another one, so that a test run is
 certain of which it exercises.

 @module lvterm
]]


local _ENV = require 'lvterm._normalize'.strictness() {
   concat = table.concat,
   error = error,
   format = string.format,
   getenv = os.getenv,
   ipairs = ipairs,
   pcall = pcall,
   require = require,
   tostring = tostring,
   type = type,
}


-- Check the types of the arguments of `new`, if typecheck is installed.
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


local terminal = require 'lvterm.terminal'



--[[ ================ ]]--
--[[ Choose backend. ]]--
--[[ ================ ]]--


-- The backend that makes terminals here: the one that was asked for, or the
-- first that works.
local backend
do
   local wanted = getenv 'LVTERM_BACKEND'

   local names = {'ffi', 'core'}
   if wanted ~= nil and wanted ~= '' then
      names = {wanted}
   end

   local failures = {}
   for _, name in ipairs(names) do
      local ok, b = pcall(require, 'lvterm.' .. name)
      if ok then
         backend = b
         break
      end
      failures[#failures + 1] = name .. ': ' .. tostring(b)
   end

   if backend == nil then
      error('no lvterm backend works on this host:\n  ' .. concat(failures, '\n  '), 2)
   end
end



--[[ ================= ]]--
--[[ Public Interface. ]]--
--[[ ================= ]]--


--- Which backend makes terminals here.
-- @field backend `'ffi'` or `'core'`


--- Make a handle, which is what the backend makes a `Terminal` over.
-- A program that wants a terminal calls `new`, which uses this.
-- @function handle
-- @int rows height in lines
-- @int cols width in columns
-- @tparam[opt] table options as for `new`
-- @treturn table a handle, which has the methods that `lvterm.terminal` calls


--- Make a new virtual terminal.
-- @function new
-- @int[opt=24] rows height in lines
-- @int[opt=80] cols width in columns
-- @tparam[opt] table options `scrollback`, the most lines to keep of those
--   that scroll off the top, which is as many as there is memory for if it
--   is not given, and none if it is 0
-- @treturn lvterm.terminal.Terminal
local function new(rows, cols, options)
   rows, cols = rows or 24, cols or 80
   if rows < 1 or cols < 1 then
      error(format('a terminal needs positive rows and columns, not %d,%d', rows, cols), 2)
   end
   local scrollback = options and options.scrollback
   if scrollback ~= nil and (type(scrollback) ~= 'number' or scrollback < 0 or scrollback % 1 ~= 0) then
      error(format('the scrollback of a terminal is a number of lines, not %s', tostring(scrollback)), 2)
   end
   return terminal.new(backend.new(rows, cols, options), rows, cols)
end


--- @export
return {
   backend = backend.name,
   handle = backend.new,
   new = argscheck('lvterm.new (<?int>, <?int>, <?table>)', new),
}
