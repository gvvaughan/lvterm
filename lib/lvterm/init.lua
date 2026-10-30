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
-- The terminal is made by the first backend that works on the host, with
-- libvterm to emulate it.
--
-- @module lvterm

local backends = {'lvterm.ffi'}

local M = {}

local failures = {}
for _, name in ipairs(backends) do
   local ok, backend = pcall(require, name)
   if ok then
      M.backend = backend.name
      M.new = backend.new
      break
   end
   failures[#failures + 1] = name .. ': ' .. tostring(backend)
end

if M.new == nil then
   error('no lvterm backend works on this host:\n  ' ..
         table.concat(failures, '\n  '), 2)
end


--- Which backend makes terminals here.
-- @field backend `'ffi'`

--- Make a new virtual terminal.
-- @function new
-- @int[opt=24] rows height in lines
-- @int[opt=80] cols width in columns
-- @treturn lvterm.ffi.Terminal

return M
