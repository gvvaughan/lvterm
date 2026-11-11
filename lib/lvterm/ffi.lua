--[[
 Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5
 Copyright (C) 2026 Gary V. Vaughan
]]
--[[--
 LuaJIT FFI backend: libvterm called directly, with nothing to compile.

 Only what `lvterm` needs of libvterm 0.3 is declared: feed it bytes, then
 look at the cells and the cursor, and ask it what a key or the mouse sends.
 Four of its callbacks are used, to keep the lines that scroll off the top,
 to know when the program switches screens, hides the cursor, asks for the
 mouse or sets the title, to count the bells, and to take what the terminal
 sends back, so that a handle has that to give out in order.

 @module lvterm.ffi
]]


-- The functions that every cell goes through, and the callbacks that libvterm
-- makes for every line, are not looked up in the environment, which is slower
-- when it checks that a variable is declared.
local band = require('bit').band
local concat = table.concat
local floor = math.floor
local max = math.max
local min = math.min
local schar = string.char

local ffi = require 'ffi'
local jit = require 'jit'


local _ENV = require 'lvterm._normalize'.strictness() {
   error = error,
   ipairs = ipairs,
   require = require,
   setmetatable = setmetatable,
   tonumber = tonumber,
}

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

// LuaJIT has no bit-fields of size_t, so the three that libvterm packs into
// the 32 bits after the pointer are made of one type that it has.
typedef struct {
   const char *str;
   uint32_t    len : 30;
   uint32_t    initial : 1;
   uint32_t    final : 1;
} VTermStringFragment;

typedef union { int boolean; int number; VTermStringFragment string; char reserved[32]; } VTermValue;

typedef struct {
   void *damage;
   void *moverect;
   void *movecursor;
   int (*settermprop)(int prop, VTermValue *val, void *user);
   int (*bell)(void *user);
   void *resize;
   int (*sb_pushline)(int cols, const VTermScreenCell *cells, void *user);
   int (*sb_popline)(int cols, VTermScreenCell *cells, void *user);
   int (*sb_clear)(void *user);
} VTermScreenCallbacks;

typedef void VTermOutputCallback(const char *s, size_t len, void *user);

VTerm *vterm_new(int rows, int cols);
void   vterm_free(VTerm *vt);
void   vterm_get_size(const VTerm *vt, int *rowsp, int *colsp);
void   vterm_set_size(VTerm *vt, int rows, int cols);
void   vterm_set_utf8(VTerm *vt, int is_utf8);
size_t vterm_input_write(VTerm *vt, const char *bytes, size_t len);
void   vterm_output_set_callback(VTerm *vt, VTermOutputCallback *func, void *user);

void vterm_keyboard_unichar(VTerm *vt, uint32_t c, int mod);
void vterm_keyboard_key(VTerm *vt, int key, int mod);
void vterm_keyboard_start_paste(VTerm *vt);
void vterm_keyboard_end_paste(VTerm *vt);

void vterm_mouse_move(VTerm *vt, int row, int col, int mod);
void vterm_mouse_button(VTerm *vt, int button, int pressed, int mod);

VTermState *vterm_obtain_state(VTerm *vt);
int  vterm_state_set_termprop(VTermState *state, int prop, VTermValue *val);
void vterm_state_focus_in(VTermState *state);
void vterm_state_focus_out(VTermState *state);
void vterm_state_get_cursorpos(const VTermState *state, VTermPos *cursorpos);

VTermScreen *vterm_obtain_screen(VTerm *vt);
void   vterm_screen_set_callbacks(VTermScreen *screen, const VTermScreenCallbacks *callbacks, void *user);
void   vterm_screen_enable_altscreen(VTermScreen *screen, int altscreen);
void   vterm_screen_flush_damage(VTermScreen *screen);
void   vterm_screen_reset(VTermScreen *screen, int hard);
int    vterm_screen_get_cell(const VTermScreen *screen, VTermPos pos, VTermScreenCell *cell);
void   vterm_screen_convert_color_to_rgb(const VTermScreen *screen, VTermColor *col);
]]


-- The build found libvterm, and recorded where.
local C = ffi.load(require('lvterm.version').LIBVTERM)

-- The cells that libvterm 0.3 makes are 40 bytes, and the colors of the
-- older ones are not the same, so don't read memory from another layout.
if ffi.sizeof 'VTermScreenCell' ~= 40 then
   error('unsupported libvterm: only 0.3 is supported', 0)
end

local MAX_CHARS = 6


-- The UTF-8 encoding of the code point CP.
local function utf8char(cp)
   if cp < 0x80 then
      return schar(cp)
   elseif cp < 0x800 then
      return schar(0xC0 + floor(cp / 0x40), 0x80 + cp % 0x40)
   elseif cp < 0x10000 then
      return schar(0xE0 + floor(cp / 0x1000),
                         0x80 + floor(cp / 0x40) % 0x40,
                         0x80 + cp % 0x40)
   end
   return schar(0xF0 + floor(cp / 0x40000),
                      0x80 + floor(cp / 0x1000) % 0x40,
                      0x80 + floor(cp / 0x40) % 0x40,
                      0x80 + cp % 0x40)
end


-- A color as nil for the default, an index into the palette of 256, or a
-- table with `red`, `green` and `blue` fields.  The `type` flags are, from
-- the least significant: indexed, default foreground, default background.
local function color(c)
   local flags = c.type
   if floor(flags / 2) % 4 ~= 0 then
      return nil
   elseif flags % 2 == 1 then
      return c.indexed.idx
   end
   return {red = c.rgb.red, green = c.rgb.green, blue = c.rgb.blue}
end


-- What one cell of libvterm is, as the table that a handle gives.
local function convert(cell)
   local chars = {}
   for i = 0, MAX_CHARS - 1 do
      local cp = cell.chars[i]
      if cp == 0 then
         break
      elseif cp ~= 0xFFFFFFFF then
         chars[#chars + 1] = utf8char(cp)
      end
   end

   local text = concat(chars)
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


-- The cell that libvterm gives for one that nothing was written to: a space,
-- one column wide, in the default colors with no attributes.
local BLANK = ffi.new 'VTermScreenCell'
BLANK.width = 1
BLANK.fg.type = 2
BLANK.bg.type = 4

local CELL = ffi.sizeof 'VTermScreenCell'


-- Whether a cell is the same as one that nothing was written to, which is not
-- kept at the end of a line of the scrollback.
local function blank(cell)
   local a = cell.attrs
   return cell.chars[0] == 0 and cell.width == 1
      and band(cell.fg.type, 2) ~= 0 and band(cell.bg.type, 4) ~= 0
      and a.bold == 0 and a.underline == 0 and a.italic == 0 and a.blink == 0
      and a.reverse == 0 and a.conceal == 0 and a.strike == 0 and a.font == 0
      and a.dwl == 0 and a.dhl == 0 and a.small == 0 and a.baseline == 0
end


-- The numbers that libvterm gives to the properties that a program sets.
local PROP_CURSORVISIBLE, PROP_ALTSCREEN, PROP_TITLE, PROP_MOUSE, PROP_FOCUSREPORT = 1, 3, 4, 8, 9


-- The handles that callbacks are for, by the number that libvterm is given
-- as the data of its callbacks, so that there are only as many callbacks as
-- there are callbacks, and not as many as there are terminals, which LuaJIT limits.
local handles = setmetatable({}, {__mode = 'v'})
local serial = 0

local function handle_of(user)
   return handles[tonumber(ffi.cast('intptr_t', user))]
end


-- A line that scrolled off the top is kept, without the cells at its end
-- that are blank, as the bytes of the cells that libvterm made.
local function pushed(cols, cells, user)
   local h = handle_of(user)
   local n = cols
   while n > 0 and blank(cells[n - 1]) do
      n = n - 1
   end
   h.last = h.last + 1
   h.lines[h.last] = {cols = cols, n = n, bytes = ffi.string(cells, n * CELL)}
   if h.limit and h.last - h.first + 1 > h.limit then
      h.lines[h.first] = nil
      h.first = h.first + 1
   end
   return 1
end


-- The newest line is given back, cut or made wider than it was to be as wide as is asked for.
local function popped(cols, cells, user)
   local h = handle_of(user)
   if h.last < h.first then
      return 0
   end

   local line = h.lines[h.last]
   h.lines[h.last] = nil
   h.last = h.last - 1

   local kept = min(line.n, cols)
   ffi.copy(cells, line.bytes, kept * CELL)
   for i = kept, cols - 1 do
      cells[i] = BLANK
   end
   if kept == cols and cols > 0 and cells[cols - 1].width == 2 then
      cells[cols - 1] = BLANK
   end
   return 1
end


local function forgotten(user)
   local h = handle_of(user)
   h.lines, h.first, h.last = {}, 1, 0
   return 1
end


local function property(prop, value, user)
   local h = handle_of(user)
   if prop == PROP_ALTSCREEN then
      h.alt = value.boolean ~= 0
   elseif prop == PROP_CURSORVISIBLE then
      h.shown = value.boolean ~= 0
   elseif prop == PROP_MOUSE then
      h.mouse = value.number
   elseif prop == PROP_FOCUSREPORT then
      h.focusing = value.boolean ~= 0
   elseif prop == PROP_TITLE then
      -- A title may come in pieces, and is not the title until the last.
      local frag = value.string
      if frag.initial == 1 then
         h.partial = {}
      end
      if h.partial then
         h.partial[#h.partial + 1] = ffi.string(frag.str, frag.len)
         if frag.final == 1 then
            h.name = concat(h.partial)
            h.partial = nil
         end
      end
   end
   return 1
end


local function rang(user)
   local h = handle_of(user)
   h.rung = h.rung + 1
   return 1
end


local function sent(bytes, len, user)
   local h = handle_of(user)
   h.out[#h.out + 1] = ffi.string(bytes, len)
end


-- Made once, and kept for as long as the process lives, as libvterm keeps the
-- pointers that it is given.
local callbacks = ffi.new 'VTermScreenCallbacks'
local pushed_cb = ffi.cast('int (*)(int, const VTermScreenCell *, void *)', pushed)
local popped_cb = ffi.cast('int (*)(int, VTermScreenCell *, void *)', popped)
local forgotten_cb = ffi.cast('int (*)(void *)', forgotten)
local property_cb = ffi.cast('int (*)(int, VTermValue *, void *)', property)
local bell_cb = ffi.cast('int (*)(void *)', rang)
local sent_cb = ffi.cast('VTermOutputCallback *', sent)
callbacks.sb_pushline = pushed_cb
callbacks.sb_popline = popped_cb
callbacks.sb_clear = forgotten_cb
callbacks.settermprop = property_cb
callbacks.bell = bell_cb


-- The methods of a handle, made when all of them are defined.
local Handle


--- Make a handle for a new terminal.
-- @int rows height in lines
-- @int cols width in columns
-- @tparam[opt] table options `scrollback`, the most lines to keep, which is
--   all of them if it is not given
-- @treturn Handle
local function new(rows, cols, options)
   local vt = ffi.gc(C.vterm_new(rows, cols), C.vterm_free)
   C.vterm_set_utf8(vt, 1)

   serial = serial + 1
   local self = setmetatable({
      vt = vt,
      state = C.vterm_obtain_state(vt),
      screen = C.vterm_obtain_screen(vt),
      limit = options and options.scrollback,
      lines = {}, first = 1, last = 0,
      out = {},
      alt = false,
      shown = true,
      mouse = 0,
      focusing = false,
      rung = 0,
   }, Handle)
   handles[serial] = self

   local user = ffi.cast('void *', serial)
   C.vterm_output_set_callback(vt, sent_cb, user)
   C.vterm_screen_set_callbacks(self.screen, callbacks, user)
   C.vterm_screen_enable_altscreen(self.screen, 1)
   C.vterm_screen_reset(self.screen, 1)
   return self
end


--- What a backend's handle does, so the same as `lvterm.core`'s.
-- @type Handle

--- Feed bytes to the terminal.
-- @function write
-- @string bytes what the terminal receives
local function write(self, bytes)
   C.vterm_input_write(self.vt, bytes, #bytes)
   C.vterm_screen_flush_damage(self.screen)
end


--- Change the size of the terminal.
-- @function resize
-- @int rows new height in lines
-- @int cols new width in columns
local function resize(self, rows, cols)
   C.vterm_set_size(self.vt, rows, cols)
end


--- Return the terminal to its initial state.
-- @function reset
-- @bool hard also forget the contents of the screen
local function reset(self, hard)
   C.vterm_screen_reset(self.screen, hard and 1 or 0)
   -- libvterm stops sending mouse events and focus reports after reset.
   self.mouse = 0
   self.focusing = false
end


--- Where the cursor is.
-- @function cursor
-- @treturn int row
-- @treturn int column
local function cursor(self)
   local pos = ffi.new 'VTermPos'
   C.vterm_state_get_cursorpos(self.state, pos)
   return pos.row, pos.col
end


--- What one cell of the screen shows, which must be on it.
-- @function cell
-- @int row line to read, from 0
-- @int col column to read, from 0
-- @treturn table the fields that `lvterm.terminal.Terminal:cell` documents
local function cell(self, row, col)
   local pos = ffi.new('VTermPos', row, col)
   local cell = ffi.new 'VTermScreenCell'
   C.vterm_screen_get_cell(self.screen, pos, cell)
   return convert(cell)
end


-- Whether two colors of libvterm are the same, which two default colors are
-- whatever bytes the rest of them have.
local function same_color(a, b)
   local ta, tb = a.type, b.type
   local da, db = band(ta, 6) ~= 0, band(tb, 6) ~= 0
   if da or db then
      return da == db
   elseif band(ta, 1) ~= band(tb, 1) then
      return false
   elseif band(ta, 1) == 1 then
      return a.indexed.idx == b.indexed.idx
   end
   return a.rgb.red == b.rgb.red and a.rgb.green == b.rgb.green and a.rgb.blue == b.rgb.blue
end


-- Whether two cells are drawn alike, which is what `cell` says about them
-- other than the text.
local function alike(a, b)
   local x, y = a.attrs, b.attrs
   return x.bold == y.bold and x.italic == y.italic and x.blink == y.blink
      and x.reverse == y.reverse and x.conceal == y.conceal and x.strike == y.strike
      and x.underline == y.underline and same_color(a.fg, b.fg) and same_color(a.bg, b.bg)
end


-- The text of each code point that a cell has had, so that most of them are
-- made once.
local glyphs = {}

-- The text of a cell: a space for one that nothing was written to, and nothing
-- for the right half of a wide character.
local function text_of(cell)
   local cp = cell.chars[0]
   if cell.chars[1] == 0 then
      local g = glyphs[cp]
      if g == nil then
         g = cp == 0 and ' ' or cp == 0xFFFFFFFF and '' or utf8char(cp)
         glyphs[cp] = g
      end
      return g
   end
   return convert(cell).text
end


-- The runs of the first COLS cells of an array of them, which are drawn alike.
local function runs_of(cells, cols)
   local out, run, parts, n = {}, nil, nil, 0
   local prev
   for col = 0, cols - 1 do
      local cell = cells[col]
      if run ~= nil and cell.chars[0] == 0xFFFFFFFF then
         -- The right half of a wide character is of the run that it is in, whatever libvterm says that
         -- it is drawn like, and does not start one, or end one for the cell after it.
         run.cols = run.cols + 1
      else
         if run ~= nil and alike(prev, cell) then
            run.cols = run.cols + 1
            n = n + 1
            parts[n] = text_of(cell)
         else
            if run ~= nil then
               run.text = concat(parts, '', 1, n)
            end
            local attrs = cell.attrs
            run = {
               col = col,
               cols = 1,
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
            parts, n = {text_of(cell)}, 1
            out[#out + 1] = run
         end
         prev = cell
      end
   end
   if run ~= nil then
      run.text = concat(parts, '', 1, n)
   end
   return out
end


-- Comparing the cells of a row with those that its runs were made of.
ffi.cdef 'int memcmp(const void *a, const void *b, size_t n);'
local memcmp = ffi.C.memcmp

-- The cells of the row that is looked at, which are all that are got from libvterm for each, and
-- which are the same bytes when a row is the same, as every field of a cell is written each time.
local now, now_cols = ffi.new 'VTermScreenCell[1]', 0
local where = ffi.new 'VTermPos'
local size_rows, size_cols = ffi.new 'int[1]', ffi.new 'int[1]'


--- What a row of the screen shows, as runs of cells that are drawn alike.
-- The runs of a row are kept while its cells are the same, and are given again, the same
-- table, so that a program can tell that a row is not changed.
-- @function runs
-- @int row line to read, from 0, which must be on the screen
-- @treturn {table,...} the runs, as `lvterm.terminal.Terminal:runs` documents
local function runs(self, row)
   C.vterm_get_size(self.vt, size_rows, size_cols)
   local rows, cols = size_rows[0], size_cols[0]
   if cols > now_cols then
      now, now_cols = ffi.new('VTermScreenCell[?]', cols), cols
   end
   where.row = row
   local screen = self.screen
   for col = 0, cols - 1 do
      where.col = col
      C.vterm_screen_get_cell(screen, where, now[col])
   end

   local kept = self.kept
   if kept == nil or kept.rows ~= rows or kept.cols ~= cols then
      kept = {rows = rows, cols = cols, cells = ffi.new('VTermScreenCell[?]', rows * cols), runs = {}}
      self.kept = kept
   end
   local before = kept.runs[row]
   local at = kept.cells + row * cols
   if before ~= nil and memcmp(at, now, cols * CELL) == 0 then
      return before
   end
   ffi.copy(at, now, cols * CELL)
   local made = runs_of(now, cols)
   kept.runs[row] = made
   return made
end


--- Take what the terminal has to send back to the program.
-- @function output
-- @treturn string the bytes, which the terminal forgets
local function output(self)
   local bytes = concat(self.out)
   self.out = {}
   return bytes
end


--- Press a key.
-- @function key
-- @int code the number that libvterm has for the key
-- @int mods the modifiers that are held, as bits: shift 1, alt 2, ctrl 4
local function key(self, code, mods)
   C.vterm_keyboard_key(self.vt, code, mods)
end


--- Type a character.
-- @function char
-- @int cp the code point
-- @int mods the modifiers that are held, as for `key`
local function char(self, cp, mods)
   C.vterm_keyboard_unichar(self.vt, cp, mods)
end


--- Paste text, between the marks that the program asked for, if it did.
-- libvterm only sends the marks, so the text is added between them.
-- @function paste
-- @string text the bytes pasted
local function paste(self, text)
   C.vterm_keyboard_start_paste(self.vt)
   self.out[#self.out + 1] = text
   C.vterm_keyboard_end_paste(self.vt)
end


--- How many lines have scrolled off the top.
-- @function scrollback_size
-- @treturn int the lines in the scrollback
local function scrollback_size(self)
   return self.last - self.first + 1
end


--- A line that scrolled off the top, which must be there.
-- @function scrollback_line
-- @int n which, from 1 for the newest
-- @treturn {table,...} the cells of the line, as `cell` gives
local function scrollback_line(self, n)
   local line = self.lines[self.last - n + 1]
   local cells = ffi.new('VTermScreenCell[?]', max(line.n, 1))
   ffi.copy(cells, line.bytes, line.n * CELL)
   local out = {}
   for i = 0, line.cols - 1 do
      out[i + 1] = convert(i < line.n and cells[i] or BLANK)
   end
   return out
end


--- A line that scrolled off the top, as runs of cells that are drawn alike.
-- @function scrollback_runs
-- @int n which, from 1 for the newest, which must be there
-- @treturn {table,...} the runs, as `lvterm.terminal.Terminal:runs` documents
local function scrollback_runs(self, n)
   local line = self.lines[self.last - n + 1]
   local cells = ffi.new('VTermScreenCell[?]', max(line.cols, 1))
   ffi.copy(cells, line.bytes, line.n * CELL)
   for col = line.n, line.cols - 1 do
      cells[col] = BLANK
   end
   return runs_of(cells, line.cols)
end


--- Forget the lines that scrolled off the top.
-- @function scrollback_clear
local function scrollback_clear(self)
   self.lines, self.first, self.last = {}, 1, 0
end


--- Whether the program is on the alternate screen.
-- @function altscreen
-- @treturn bool
local function altscreen(self)
   return self.alt
end


--- Whether the program has the cursor shown.
-- @function cursor_visible
-- @treturn bool
local function cursor_visible(self)
   return self.shown
end


--- Move the mouse.
-- @function mouse_move
-- @int row line that it is over, from 0
-- @int col column that it is over, from 0
-- @int mods the modifiers that are held, as for `key`
local function mouse_move(self, row, col, mods)
   C.vterm_mouse_move(self.vt, row, col, mods)
end


--- Press or release a mouse button, where the mouse last was.
-- @function mouse_button
-- @int button 1 for the left, 2 the middle, 3 the right, 4 for the wheel
--   up and 5 for the wheel down
-- @bool pressed true to press, and false to release
-- @int mods the modifiers that are held, as for `key`
local function mouse_button(self, button, pressed, mods)
   C.vterm_mouse_button(self.vt, button, pressed and 1 or 0, mods)
end


--- Set a property of the terminal, as the program would with a sequence.
-- @function set_termprop
-- @int prop the number that libvterm has for the property
-- @int value the number or boolean that libvterm takes for it, as a number
local function set_termprop(self, prop, value)
   local val = ffi.new 'VTermValue'
   val.number = value
   C.vterm_state_set_termprop(self.state, prop, val)
end


--- Tell the program that the terminal gained the focus.
-- @function focus_in
local function focus_in(self)
   C.vterm_state_focus_in(self.state)
end


--- Tell the program that the terminal lost the focus.
-- @function focus_out
local function focus_out(self)
   C.vterm_state_focus_out(self.state)
end


--- Whether the program asked to be told when the terminal gains or loses the focus.
-- @function focus_reporting
-- @treturn bool
local function focus_reporting(self)
   return self.focusing
end


--- What the program asked to be told about the mouse.
-- @function mouse_mode
-- @treturn int 0 for nothing, 1 for clicks, 2 for drags and 3 for all moves
local function mouse_mode(self)
   return self.mouse
end


--- The title that the program set.
-- @function title
-- @treturn string|nil the title, which is nil if none was set
local function title(self)
   return self.name
end


--- Take how many times the program rang the bell.
-- @function bells
-- @treturn int the number of bells since the last call, which is forgotten
local function bells(self)
   local n = self.rung
   self.rung = 0
   return n
end


Handle = {
   write = write,
   resize = resize,
   reset = reset,
   cursor = cursor,
   cell = cell,
   runs = runs,
   output = output,
   key = key,
   char = char,
   paste = paste,
   scrollback_size = scrollback_size,
   scrollback_line = scrollback_line,
   scrollback_runs = scrollback_runs,
   scrollback_clear = scrollback_clear,
   altscreen = altscreen,
   cursor_visible = cursor_visible,
   mouse_move = mouse_move,
   mouse_button = mouse_button,
   set_termprop = set_termprop,
   focus_in = focus_in,
   focus_out = focus_out,
   focus_reporting = focus_reporting,
   mouse_mode = mouse_mode,
   title = title,
   bells = bells,
}
Handle.__index = Handle


-- LuaJIT only knows that a call to a C function calls back once it has seen
-- it do so, and a callback in code that it compiled before then is fatal:
-- "bad callback".  Output that does not scroll can make a loop hot, and the
-- first line that scrolls then panics, so keep what calls libvterm, where
-- a callback may be made, out of compiled code.
for _, name in ipairs {'write', 'resize', 'reset', 'key', 'char', 'paste',
                       'mouse_move', 'mouse_button', 'focus_in', 'focus_out'} do
   jit.off(Handle[name])
end


--- The name of the backend.
-- @field name `'ffi'`


--- @export
return {
   name = 'ffi',
   new = new,
}
