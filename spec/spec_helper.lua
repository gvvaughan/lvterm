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
