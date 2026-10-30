--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--- LuaJIT FFI backend: libvterm called directly, with nothing to compile.
--
-- Only the polling interface of libvterm 0.3 is declared, which is all that
-- `lvterm` needs: feed it bytes, then look at the cells and the cursor.
--
-- @module lvterm.ffi

local ffi = require 'ffi'

ffi.cdef [[
typedef struct VTerm VTerm;
typedef struct VTermState VTermState;
typedef struct VTermScreen VTermScreen;

typedef struct { int row; int col; } VTermPos;

typedef union {
   uint8_t type;
   struct { uint8_t type; uint8_t red, green, blue; } rgb;
   struct { uint8_t type; uint8_t idx; } indexed;
} VTermColor;

typedef struct {
   unsigned int bold      : 1;
   unsigned int underline : 2;
   unsigned int italic    : 1;
   unsigned int blink     : 1;
   unsigned int reverse   : 1;
   unsigned int conceal   : 1;
   unsigned int strike    : 1;
   unsigned int font      : 4;
   unsigned int dwl       : 1;
   unsigned int dhl       : 2;
   unsigned int small     : 1;
   unsigned int baseline  : 2;
} VTermScreenCellAttrs;

typedef struct {
   uint32_t chars[6];
   char     width;
   VTermScreenCellAttrs attrs;
   VTermColor fg, bg;
} VTermScreenCell;

VTerm *vterm_new(int rows, int cols);
void   vterm_free(VTerm *vt);
void   vterm_get_size(const VTerm *vt, int *rowsp, int *colsp);
void   vterm_set_size(VTerm *vt, int rows, int cols);
void   vterm_set_utf8(VTerm *vt, int is_utf8);
size_t vterm_input_write(VTerm *vt, const char *bytes, size_t len);
size_t vterm_output_get_buffer_current(const VTerm *vt);
size_t vterm_output_read(VTerm *vt, char *buffer, size_t len);

VTermState *vterm_obtain_state(VTerm *vt);
void vterm_state_get_cursorpos(const VTermState *state, VTermPos *cursorpos);

VTermScreen *vterm_obtain_screen(VTerm *vt);
void   vterm_screen_enable_altscreen(VTermScreen *screen, int altscreen);
void   vterm_screen_flush_damage(VTermScreen *screen);
void   vterm_screen_reset(VTermScreen *screen, int hard);
int    vterm_screen_get_cell(const VTermScreen *screen, VTermPos pos, VTermScreenCell *cell);
void   vterm_screen_convert_color_to_rgb(const VTermScreen *screen, VTermColor *col);
]]


-- The build found libvterm, and recorded where.
local C = ffi.load(require('lvterm.config').library)

-- The cells that libvterm 0.3 makes are 40 bytes, and the colors of the
-- older ones are not the same, so don't read memory from another layout.
if ffi.sizeof 'VTermScreenCell' ~= 40 then
   error('unsupported libvterm: only 0.3 is supported', 0)
end

local MAX_CHARS = 6


-- The UTF-8 encoding of the code point CP.
local function utf8char(cp)
   if cp < 0x80 then
      return string.char(cp)
   elseif cp < 0x800 then
      return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
   elseif cp < 0x10000 then
      return string.char(0xE0 + math.floor(cp / 0x1000),
                         0x80 + math.floor(cp / 0x40) % 0x40,
                         0x80 + cp % 0x40)
   end
   return string.char(0xF0 + math.floor(cp / 0x40000),
                      0x80 + math.floor(cp / 0x1000) % 0x40,
                      0x80 + math.floor(cp / 0x40) % 0x40,
                      0x80 + cp % 0x40)
end


-- A color as nil for the default, an index into the palette of 256, or a
-- table with `red`, `green` and `blue` fields.  The `type` flags are, from
-- the least significant: indexed, default foreground, default background.
local function color(c)
   local flags = c.type
   if math.floor(flags / 2) % 4 ~= 0 then
      return nil
   elseif flags % 2 == 1 then
      return c.indexed.idx
   end
   return {red = c.rgb.red, green = c.rgb.green, blue = c.rgb.blue}
end


local Handle = {}
Handle.__index = Handle


local M = {name = 'ffi'}


--- Make a handle for a new terminal.
-- @int rows height in lines
-- @int cols width in columns
-- @treturn Handle
function M.new(rows, cols)
   local vt = ffi.gc(C.vterm_new(rows, cols), C.vterm_free)
   C.vterm_set_utf8(vt, 1)

   local screen = C.vterm_obtain_screen(vt)
   C.vterm_screen_enable_altscreen(screen, 1)
   C.vterm_screen_reset(screen, 1)

   return setmetatable({
      vt = vt,
      state = C.vterm_obtain_state(vt),
      screen = screen,
   }, Handle)
end


--- What a backend's handle does, so the same as `lvterm.core`'s.
-- @type Handle

--- Feed bytes to the terminal.
-- @string bytes what the terminal receives
function Handle:write(bytes)
   C.vterm_input_write(self.vt, bytes, #bytes)
   C.vterm_screen_flush_damage(self.screen)
end


--- Change the size of the terminal.
-- @int rows new height in lines
-- @int cols new width in columns
function Handle:resize(rows, cols)
   C.vterm_set_size(self.vt, rows, cols)
end


--- Return the terminal to its initial state.
-- @bool hard also forget the contents of the screen
function Handle:reset(hard)
   C.vterm_screen_reset(self.screen, hard and 1 or 0)
end


--- Where the cursor is.
-- @treturn int row
-- @treturn int column
function Handle:cursor()
   local pos = ffi.new 'VTermPos'
   C.vterm_state_get_cursorpos(self.state, pos)
   return pos.row, pos.col
end


--- What one cell of the screen shows, which must be on it.
-- @int row line to read, from 0
-- @int col column to read, from 0
-- @treturn table the fields that `lvterm.terminal.Terminal:cell` documents
function Handle:cell(row, col)
   local pos = ffi.new('VTermPos', row, col)
   local cell = ffi.new 'VTermScreenCell'
   C.vterm_screen_get_cell(self.screen, pos, cell)

   local chars = {}
   for i = 0, MAX_CHARS - 1 do
      local cp = cell.chars[i]
      if cp == 0 then
         break
      elseif cp ~= 0xFFFFFFFF then
         chars[#chars + 1] = utf8char(cp)
      end
   end

   local text = table.concat(chars)
   if text == '' and cell.chars[0] == 0 then
      text = ' '
   end

   local attrs = cell.attrs
   return {
      text = text,
      width = cell.width,
      bold = attrs.bold == 1,
      italic = attrs.italic == 1,
      blink = attrs.blink == 1,
      reverse = attrs.reverse == 1,
      conceal = attrs.conceal == 1,
      strike = attrs.strike == 1,
      underline = attrs.underline,
      fg = color(cell.fg),
      bg = color(cell.bg),
   }
end


--- Take what the terminal has to send back to the program.
-- @treturn string the bytes, which the terminal forgets
function Handle:output()
   local n = tonumber(C.vterm_output_get_buffer_current(self.vt))
   if n == 0 then
      return ''
   end
   local buffer = ffi.new('char[?]', n)
   return ffi.string(buffer, C.vterm_output_read(self.vt, buffer, n))
end


return M
