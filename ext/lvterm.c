/*
 * Virtual terminal for Lua 5.1, 5.2, 5.3, 5.4 & 5.5.
 *
 * (c) Gary V. Vaughan <gary@gnu.org> 2026
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */
/***
 The libvterm backend for hosts without a LuaJIT FFI.

 A thin binding of libvterm 0.3: feed a terminal bytes, then ask what its
 cells show and where its cursor is, and what a key or the mouse sends.
 Four of its callbacks are used, to keep the lines that scroll off the top,
 to know when the program switches screens, hides the cursor, asks for the
 mouse or sets the title, to count the bells, and to take what the terminal
 sends back, so that a handle has that to give out in order.
 The `lvterm.Terminal` that `lvterm` makes is built over this, and over the
 FFI backend alike, so what a handle does is only what the two have in
 common.

 @module lvterm.core
*/

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include <vterm.h>

#ifndef VTERM_COLOR_IS_DEFAULT_FG
#  error "lvterm needs libvterm 0.3"
#endif

#define HANDLE "lvterm.core.terminal"

/* A line that scrolled off the top, without the cells at its end that are
   blank: COLS wide when it was made, and N cells of it are kept. */
typedef struct
{
	int		cols;
	int		n;
	VTermScreenCell	cells[1];
} Line;

typedef struct
{
	VTerm		*vt;
	VTermState	*state;
	VTermScreen	*screen;

	/* The scrollback is a ring of lines, the oldest first. */
	Line		**ring;
	size_t		cap;
	size_t		first;
	size_t		count;
	int		limited;	/* whether LIMIT is the most to keep */
	size_t		limit;

	int		alt;		/* on the alternate screen */
	int		shown;		/* the cursor is shown */
	int		mouse;		/* what the program asked of the mouse */
	int		focusing;	/* the program asked for the focus */
	int		bells;		/* the bells since they were taken */

	char		*title;		/* the title that the program set */
	size_t		titlelen;
	char		*partial;	/* the title that is still coming, if one is */
	size_t		partiallen;
	size_t		partialcap;

	char		*out;		/* what the terminal sends back */
	size_t		outlen;
	size_t		outcap;
} Handle;


/* The handle at index 1, unless it has been freed. */
static Handle *
checkhandle(lua_State *L)
{
	Handle *h = (Handle *) luaL_checkudata(L, 1, HANDLE);

	if (h->vt == NULL)
		luaL_error(L, "attempt to use a freed terminal");
	return h;
}


/* Append the UTF-8 encoding of the code point CP to B. */
static void
addutf8(luaL_Buffer *b, uint32_t cp)
{
	if (cp < 0x80)
	{
		luaL_addchar(b, (char) cp);
	}
	else if (cp < 0x800)
	{
		luaL_addchar(b, (char) (0xC0 | (cp >> 6)));
		luaL_addchar(b, (char) (0x80 | (cp & 0x3F)));
	}
	else if (cp < 0x10000)
	{
		luaL_addchar(b, (char) (0xE0 | (cp >> 12)));
		luaL_addchar(b, (char) (0x80 | ((cp >> 6) & 0x3F)));
		luaL_addchar(b, (char) (0x80 | (cp & 0x3F)));
	}
	else
	{
		luaL_addchar(b, (char) (0xF0 | (cp >> 18)));
		luaL_addchar(b, (char) (0x80 | ((cp >> 12) & 0x3F)));
		luaL_addchar(b, (char) (0x80 | ((cp >> 6) & 0x3F)));
		luaL_addchar(b, (char) (0x80 | (cp & 0x3F)));
	}
}


/* Push a color as nil for the default, an index into the palette of 256,
   or a table with `red`, `green` and `blue` fields. */
static void
pushcolor(lua_State *L, const VTermColor *c)
{
	if (VTERM_COLOR_IS_DEFAULT_FG(c) || VTERM_COLOR_IS_DEFAULT_BG(c))
	{
		lua_pushnil(L);
	}
	else if (VTERM_COLOR_IS_INDEXED(c))
	{
		lua_pushinteger(L, c->indexed.idx);
	}
	else
	{
		lua_createtable(L, 0, 3);
		lua_pushinteger(L, c->rgb.red);
		lua_setfield(L, -2, "red");
		lua_pushinteger(L, c->rgb.green);
		lua_setfield(L, -2, "green");
		lua_pushinteger(L, c->rgb.blue);
		lua_setfield(L, -2, "blue");
	}
}


static void
setboolean(lua_State *L, const char *name, int value)
{
	lua_pushboolean(L, value);
	lua_setfield(L, -2, name);
}


/* Add bytes to what the terminal has to send back. */
static void
addout(Handle *h, const char *bytes, size_t len)
{
	if (h->outlen + len > h->outcap)
	{
		size_t cap = h->outcap ? h->outcap : 256;
		char *out;

		while (cap < h->outlen + len)
			cap *= 2;
		out = (char *) realloc(h->out, cap);
		if (out == NULL)
			return;
		h->out = out;
		h->outcap = cap;
	}
	memcpy(h->out + h->outlen, bytes, len);
	h->outlen += len;
}


/* The line that is the Nth newest of the scrollback, which must be there. */
static Line *
scrolled(Handle *h, size_t n)
{
	return h->ring[(h->first + h->count - n) % h->cap];
}


/* The cell that libvterm gives for one that nothing was written to: a space,
   one column wide, in the default colors with no attributes. */
static void
blankcell(VTermScreenCell *cell)
{
	memset(cell, 0, sizeof (VTermScreenCell));
	cell->width = 1;
	cell->fg.type = VTERM_COLOR_DEFAULT_FG;
	cell->bg.type = VTERM_COLOR_DEFAULT_BG;
}


static void
forget(Handle *h)
{
	while (h->count > 0)
	{
		free(scrolled(h, 1));
		h->count--;
	}
	h->first = 0;
}


/* Whether a cell is the same as one that nothing was written to, which is
   not kept at the end of a line of the scrollback. */
static int
isblank(const VTermScreenCell *c)
{
	return c->chars[0] == 0 && c->width == 1
		&& (c->fg.type & VTERM_COLOR_DEFAULT_FG)
		&& (c->bg.type & VTERM_COLOR_DEFAULT_BG)
		&& !c->attrs.bold && !c->attrs.underline && !c->attrs.italic
		&& !c->attrs.blink && !c->attrs.reverse && !c->attrs.conceal
		&& !c->attrs.strike && !c->attrs.font && !c->attrs.dwl
		&& !c->attrs.dhl && !c->attrs.small && !c->attrs.baseline;
}


/* A line that scrolled off the top is kept, without the cells at its end
   that are blank. */
static int
sb_pushline(int cols, const VTermScreenCell *cells, void *user)
{
	Handle *h = (Handle *) user;
	Line *line;
	int n = cols;

	if (h->limited && h->limit == 0)
		return 1;

	while (n > 0 && isblank(&cells[n - 1]))
		n--;
	line = (Line *) malloc(sizeof (Line) + (n > 0 ? n - 1 : 0) * sizeof (VTermScreenCell));
	if (line == NULL)
		return 0;
	line->cols = cols;
	line->n = n;
	memcpy(line->cells, cells, n * sizeof (VTermScreenCell));

	if (h->limited && h->count >= h->limit)
	{
		free(h->ring[h->first]);
		h->first = (h->first + 1) % h->cap;
		h->count--;
	}
	if (h->count == h->cap)
	{
		size_t cap = h->cap ? h->cap * 2 : 64;
		Line **ring = (Line **) malloc(cap * sizeof (Line *));
		size_t i;

		if (ring == NULL)
		{
			free(line);
			return 0;
		}
		for (i = 0; i < h->count; i++)
			ring[i] = h->ring[(h->first + i) % h->cap];
		free(h->ring);
		h->ring = ring;
		h->cap = cap;
		h->first = 0;
	}
	h->ring[(h->first + h->count) % h->cap] = line;
	h->count++;
	return 1;
}


/* The newest line is given back, cut or made wider than it was to be as
   wide as is asked for. */
static int
sb_popline(int cols, VTermScreenCell *cells, void *user)
{
	Handle *h = (Handle *) user;
	Line *line;
	VTermScreenCell blank;
	int kept, i;

	if (h->count == 0)
		return 0;
	line = scrolled(h, 1);
	h->count--;

	kept = line->n < cols ? line->n : cols;
	memcpy(cells, line->cells, kept * sizeof (VTermScreenCell));
	blankcell(&blank);
	for (i = kept; i < cols; i++)
		cells[i] = blank;
	if (kept == cols && cols > 0 && cells[cols - 1].width == 2)
		cells[cols - 1] = blank;
	free(line);
	return 1;
}


static int
sb_clear(void *user)
{
	forget((Handle *) user);
	return 1;
}


/* Add a piece of a title, which is the title when the last has come. */
static void
addtitle(Handle *h, VTermStringFragment frag)
{
	if (frag.initial)
	{
		free(h->partial);
		h->partial = NULL;
		h->partiallen = h->partialcap = 0;
	}
	else if (h->partial == NULL)
		return;

	if (h->partiallen + frag.len + 1 > h->partialcap)
	{
		size_t cap = h->partialcap ? h->partialcap : 64;
		char *p;

		while (cap < h->partiallen + frag.len + 1)
			cap *= 2;
		p = (char *) realloc(h->partial, cap);
		if (p == NULL)
			return;
		h->partial = p;
		h->partialcap = cap;
	}
	memcpy(h->partial + h->partiallen, frag.str, frag.len);
	h->partiallen += frag.len;

	if (frag.final)
	{
		free(h->title);
		h->title = h->partial;
		h->titlelen = h->partiallen;
		h->partial = NULL;
		h->partiallen = h->partialcap = 0;
	}
}


static int
settermprop(VTermProp prop, VTermValue *val, void *user)
{
	Handle *h = (Handle *) user;

	if (prop == VTERM_PROP_ALTSCREEN)
		h->alt = val->boolean != 0;
	else if (prop == VTERM_PROP_CURSORVISIBLE)
		h->shown = val->boolean != 0;
	else if (prop == VTERM_PROP_MOUSE)
		h->mouse = val->number;
	else if (prop == VTERM_PROP_FOCUSREPORT)
		h->focusing = val->boolean != 0;
	else if (prop == VTERM_PROP_TITLE)
		addtitle(h, val->string);
	return 1;
}


static int
bell(void *user)
{
	((Handle *) user)->bells++;
	return 1;
}


static void
sent(const char *bytes, size_t len, void *user)
{
	addout((Handle *) user, bytes, len);
}


/* Must stay for as long as a terminal does, as libvterm keeps the pointer. */
static const VTermScreenCallbacks callbacks =
{
	NULL,		/* damage */
	NULL,		/* moverect */
	NULL,		/* movecursor */
	settermprop,
	bell,
	NULL,		/* resize */
	sb_pushline,
	sb_popline,
	sb_clear
};


/***
Make a new terminal.
@function new
@int rows height in lines
@int cols width in columns
@tparam[opt] table options `scrollback`, the most lines to keep, which is
  all of them if it is not given
@treturn handle a terminal that a `lvterm.Terminal` is made over
*/
static int
core_new(lua_State *L)
{
	int rows = (int) luaL_checkinteger(L, 1);
	int cols = (int) luaL_checkinteger(L, 2);
	Handle *h;

	h = (Handle *) lua_newuserdata(L, sizeof (Handle));
	memset(h, 0, sizeof (Handle));
	luaL_getmetatable(L, HANDLE);
	lua_setmetatable(L, -2);

	h->vt = vterm_new(rows, cols);
	if (h->vt == NULL)
		return luaL_error(L, "cannot make a terminal of %d,%d", rows, cols);

	vterm_set_utf8(h->vt, 1);
	h->state = vterm_obtain_state(h->vt);
	h->screen = vterm_obtain_screen(h->vt);
	h->shown = 1;

	if (lua_istable(L, 3))
	{
		lua_getfield(L, 3, "scrollback");
		if (!lua_isnil(L, -1))
		{
			h->limited = 1;
			h->limit = (size_t) luaL_checkinteger(L, -1);
		}
		lua_pop(L, 1);
	}

	vterm_output_set_callback(h->vt, sent, h);
	vterm_screen_set_callbacks(h->screen, &callbacks, h);
	vterm_screen_enable_altscreen(h->screen, 1);
	vterm_screen_reset(h->screen, 1);
	return 1;
}


static int
handle_gc(lua_State *L)
{
	Handle *h = (Handle *) luaL_checkudata(L, 1, HANDLE);

	if (h->vt != NULL)
	{
		vterm_free(h->vt);
		h->vt = NULL;
		forget(h);
		free(h->ring);
		h->ring = NULL;
		free(h->out);
		h->out = NULL;
		free(h->title);
		h->title = NULL;
		free(h->partial);
		h->partial = NULL;
	}
	return 0;
}


/***
Feed bytes to the terminal, as a program writes them.
@function write
@string bytes what the terminal receives
*/
static int
handle_write(lua_State *L)
{
	Handle *h = checkhandle(L);
	size_t len;
	const char *bytes = luaL_checklstring(L, 2, &len);

	vterm_input_write(h->vt, bytes, len);
	vterm_screen_flush_damage(h->screen);
	return 0;
}


/***
Change the size of the terminal.
@function resize
@int rows new height in lines
@int cols new width in columns
*/
static int
handle_resize(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_set_size(h->vt, (int) luaL_checkinteger(L, 2),
		       (int) luaL_checkinteger(L, 3));
	return 0;
}


/***
Return the terminal to its initial state.
@function reset
@bool hard also forget the contents of the screen
*/
static int
handle_reset(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_screen_reset(h->screen, lua_toboolean(L, 2));
	/* libvterm stops sending mouse events and focus reports after reset. */
	h->mouse = 0;
	h->focusing = 0;
	return 0;
}


/***
Where the cursor is.
@function cursor
@treturn int row
@treturn int column
*/
static int
handle_cursor(lua_State *L)
{
	Handle *h = checkhandle(L);
	VTermPos pos;

	vterm_state_get_cursorpos(h->state, &pos);
	lua_pushinteger(L, pos.row);
	lua_pushinteger(L, pos.col);
	return 2;
}


/* Push the table that describes a cell of libvterm. */
static void
pushcell(lua_State *L, const VTermScreenCell *cell)
{
	luaL_Buffer b;
	int i;

	/* The text is a space for an empty cell, and nothing for the right
	   half of a wide character. */
	luaL_buffinit(L, &b);
	if (cell->chars[0] == 0)
		luaL_addchar(&b, ' ');
	for (i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell->chars[i] != 0; i++)
		if (cell->chars[i] != (uint32_t) -1)
			addutf8(&b, cell->chars[i]);
	luaL_pushresult(&b);

	lua_createtable(L, 0, 11);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "text");
	lua_pushinteger(L, cell->width);
	lua_setfield(L, -2, "width");
	setboolean(L, "bold", cell->attrs.bold);
	setboolean(L, "italic", cell->attrs.italic);
	setboolean(L, "blink", cell->attrs.blink);
	setboolean(L, "reverse", cell->attrs.reverse);
	setboolean(L, "conceal", cell->attrs.conceal);
	setboolean(L, "strike", cell->attrs.strike);
	lua_pushinteger(L, cell->attrs.underline);
	lua_setfield(L, -2, "underline");
	pushcolor(L, &cell->fg);
	lua_setfield(L, -2, "fg");
	pushcolor(L, &cell->bg);
	lua_setfield(L, -2, "bg");

	/* The table is under the text that was pushed first. */
	lua_remove(L, -2);
}


/* Whether two colors are the same, which two default colors are whatever
   bytes the rest of them have. */
static int
samecolor(const VTermColor *a, const VTermColor *b)
{
	int da = VTERM_COLOR_IS_DEFAULT_FG(a) || VTERM_COLOR_IS_DEFAULT_BG(a);
	int db = VTERM_COLOR_IS_DEFAULT_FG(b) || VTERM_COLOR_IS_DEFAULT_BG(b);

	if (da || db)
		return da == db;
	if (VTERM_COLOR_IS_INDEXED(a) != VTERM_COLOR_IS_INDEXED(b))
		return 0;
	if (VTERM_COLOR_IS_INDEXED(a))
		return a->indexed.idx == b->indexed.idx;
	return a->rgb.red == b->rgb.red && a->rgb.green == b->rgb.green
		&& a->rgb.blue == b->rgb.blue;
}


/* Whether two cells are drawn alike, which is what `cell` says about them
   other than the text. */
static int
alike(const VTermScreenCell *a, const VTermScreenCell *b)
{
	return a->attrs.bold == b->attrs.bold
		&& a->attrs.italic == b->attrs.italic
		&& a->attrs.blink == b->attrs.blink
		&& a->attrs.reverse == b->attrs.reverse
		&& a->attrs.conceal == b->attrs.conceal
		&& a->attrs.strike == b->attrs.strike
		&& a->attrs.underline == b->attrs.underline
		&& samecolor(&a->fg, &b->fg) && samecolor(&a->bg, &b->bg);
}


/* Push the runs of COLS cells, which are drawn alike, in a table.  The right
   half of a wide character is in the run of the character, whatever libvterm
   says that it is drawn like. */
static void
pushruns(lua_State *L, const VTermScreenCell *cells, int cols)
{
	int i = 0, n = 0;

	lua_newtable(L);
	while (i < cols)
	{
		const VTermScreenCell *first = &cells[i];
		luaL_Buffer b;
		int j = i + 1, k, m;

		while (j < cols
		       && (cells[j].chars[0] == (uint32_t) -1 || alike(first, &cells[j])))
			j++;

		luaL_buffinit(L, &b);
		for (k = i; k < j; k++)
		{
			if (cells[k].chars[0] == 0)
				luaL_addchar(&b, ' ');
			for (m = 0; m < VTERM_MAX_CHARS_PER_CELL && cells[k].chars[m] != 0; m++)
				if (cells[k].chars[m] != (uint32_t) -1)
					addutf8(&b, cells[k].chars[m]);
		}
		luaL_pushresult(&b);

		lua_createtable(L, 0, 12);
		lua_pushvalue(L, -2);
		lua_setfield(L, -2, "text");
		lua_pushinteger(L, i);
		lua_setfield(L, -2, "col");
		lua_pushinteger(L, j - i);
		lua_setfield(L, -2, "cols");
		setboolean(L, "bold", first->attrs.bold);
		setboolean(L, "italic", first->attrs.italic);
		setboolean(L, "blink", first->attrs.blink);
		setboolean(L, "reverse", first->attrs.reverse);
		setboolean(L, "conceal", first->attrs.conceal);
		setboolean(L, "strike", first->attrs.strike);
		lua_pushinteger(L, first->attrs.underline);
		lua_setfield(L, -2, "underline");
		pushcolor(L, &first->fg);
		lua_setfield(L, -2, "fg");
		pushcolor(L, &first->bg);
		lua_setfield(L, -2, "bg");

		/* The table is over the text that was pushed first. */
		lua_remove(L, -2);
		lua_rawseti(L, -2, ++n);
		i = j;
	}
}


/***
What a row of the screen shows, as runs of cells that are drawn alike.
@function runs
@int row line to read, from 0, which must be on the screen
@treturn table the runs, as `lvterm.terminal.Terminal:runs` documents
*/
static int
handle_runs(lua_State *L)
{
	Handle *h = checkhandle(L);
	VTermPos pos;
	VTermScreenCell *cells;
	int rows, cols;

	pos.row = (int) luaL_checkinteger(L, 2);
	vterm_get_size(h->vt, &rows, &cols);
	cells = (VTermScreenCell *) lua_newuserdata(L, (cols > 0 ? cols : 1) * sizeof (VTermScreenCell));
	for (pos.col = 0; pos.col < cols; pos.col++)
		if (!vterm_screen_get_cell(h->screen, pos, &cells[pos.col]))
			return luaL_error(L, "position %d,%d is not on the screen",
					  pos.row, pos.col);

	pushruns(L, cells, cols);
	return 1;
}


/***
What one cell of the screen shows, which must be on it.
@function cell
@int row line to read, from 0
@int col column to read, from 0
@treturn table the fields that `lvterm.Terminal:cell` documents
*/
static int
handle_cell(lua_State *L)
{
	Handle *h = checkhandle(L);
	VTermPos pos;
	VTermScreenCell cell;

	pos.row = (int) luaL_checkinteger(L, 2);
	pos.col = (int) luaL_checkinteger(L, 3);
	if (!vterm_screen_get_cell(h->screen, pos, &cell))
		return luaL_error(L, "position %d,%d is not on the screen",
				  pos.row, pos.col);

	pushcell(L, &cell);
	return 1;
}


/***
Take what the terminal has to send back to the program.
@function output
@treturn string the bytes, which the terminal forgets
*/
static int
handle_output(lua_State *L)
{
	Handle *h = checkhandle(L);

	lua_pushlstring(L, h->out ? h->out : "", h->outlen);
	h->outlen = 0;
	return 1;
}


/***
Press a key.
@function key
@int code the number that libvterm has for the key
@int mods the modifiers that are held, as bits: shift 1, alt 2, ctrl 4
*/
static int
handle_key(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_keyboard_key(h->vt, (VTermKey) luaL_checkinteger(L, 2),
			   (VTermModifier) luaL_checkinteger(L, 3));
	return 0;
}


/***
Type a character.
@function char
@int cp the code point
@int mods the modifiers that are held, as for `key`
*/
static int
handle_char(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_keyboard_unichar(h->vt, (uint32_t) luaL_checkinteger(L, 2),
			       (VTermModifier) luaL_checkinteger(L, 3));
	return 0;
}


/***
Paste text, between the marks that the program asked for, if it did.
libvterm only sends the marks, so the text is added between them.
@function paste
@string text the bytes pasted
*/
static int
handle_paste(lua_State *L)
{
	Handle *h = checkhandle(L);
	size_t len;
	const char *text = luaL_checklstring(L, 2, &len);

	vterm_keyboard_start_paste(h->vt);
	addout(h, text, len);
	vterm_keyboard_end_paste(h->vt);
	return 0;
}


/***
How many lines have scrolled off the top.
@function scrollback_size
@treturn int the lines in the scrollback
*/
static int
handle_scrollback_size(lua_State *L)
{
	Handle *h = checkhandle(L);

	lua_pushinteger(L, (lua_Integer) h->count);
	return 1;
}


/***
A line that scrolled off the top, which must be there.
@function scrollback_line
@int n which, from 1 for the newest
@treturn table the cells of the line, as `cell` gives
*/
static int
handle_scrollback_line(lua_State *L)
{
	Handle *h = checkhandle(L);
	size_t n = (size_t) luaL_checkinteger(L, 2);
	Line *line;
	VTermScreenCell blank;
	int i;

	if (n < 1 || n > h->count)
		return luaL_error(L, "line %d is not in the scrollback", (int) n);
	line = scrolled(h, n);
	blankcell(&blank);

	lua_createtable(L, line->cols, 0);
	for (i = 0; i < line->cols; i++)
	{
		pushcell(L, i < line->n ? &line->cells[i] : &blank);
		lua_rawseti(L, -2, i + 1);
	}
	return 1;
}


/***
A line that scrolled off the top, as runs of cells that are drawn alike.
@function scrollback_runs
@int n which, from 1 for the newest, which must be there
@treturn table the runs, as `lvterm.terminal.Terminal:runs` documents
*/
static int
handle_scrollback_runs(lua_State *L)
{
	Handle *h = checkhandle(L);
	size_t n = (size_t) luaL_checkinteger(L, 2);
	Line *line;
	VTermScreenCell *cells;
	int i;

	if (n < 1 || n > h->count)
		return luaL_error(L, "line %d is not in the scrollback", (int) n);
	line = scrolled(h, n);

	cells = (VTermScreenCell *) lua_newuserdata(L, (line->cols > 0 ? line->cols : 1) * sizeof (VTermScreenCell));
	memcpy(cells, line->cells, line->n * sizeof (VTermScreenCell));
	for (i = line->n; i < line->cols; i++)
		blankcell(&cells[i]);

	pushruns(L, cells, line->cols);
	return 1;
}


/***
Forget the lines that scrolled off the top.
@function scrollback_clear
*/
static int
handle_scrollback_clear(lua_State *L)
{
	forget(checkhandle(L));
	return 0;
}


/***
Move the mouse.
@function mouse_move
@int row line that it is over, from 0
@int col column that it is over, from 0
@int mods the modifiers that are held, as for `key`
*/
static int
handle_mouse_move(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_mouse_move(h->vt, (int) luaL_checkinteger(L, 2),
			 (int) luaL_checkinteger(L, 3),
			 (VTermModifier) luaL_checkinteger(L, 4));
	return 0;
}


/***
Press or release a mouse button, where the mouse last was.
@function mouse_button
@int button 1 for the left, 2 the middle, 3 the right, 4 for the wheel
  up and 5 for the wheel down
@bool pressed true to press, and false to release
@int mods the modifiers that are held, as for `key`
*/
static int
handle_mouse_button(lua_State *L)
{
	Handle *h = checkhandle(L);

	vterm_mouse_button(h->vt, (int) luaL_checkinteger(L, 2),
			   lua_toboolean(L, 3),
			   (VTermModifier) luaL_checkinteger(L, 4));
	return 0;
}


/***
Set a property of the terminal, as the program would with a sequence.
@function set_termprop
@int prop the number that libvterm has for the property
@int value the number or boolean that libvterm takes for it, as a number
*/
static int
handle_set_termprop(lua_State *L)
{
	Handle *h = checkhandle(L);
	VTermValue val;

	memset(&val, 0, sizeof (val));
	val.number = (int) luaL_checkinteger(L, 3);
	vterm_state_set_termprop(h->state, (VTermProp) luaL_checkinteger(L, 2), &val);
	return 0;
}


/***
Tell the program that the terminal gained the focus.
@function focus_in
*/
static int
handle_focus_in(lua_State *L)
{
	vterm_state_focus_in(checkhandle(L)->state);
	return 0;
}


/***
Tell the program that the terminal lost the focus.
@function focus_out
*/
static int
handle_focus_out(lua_State *L)
{
	vterm_state_focus_out(checkhandle(L)->state);
	return 0;
}


/***
Whether the program asked to be told when the terminal gains or loses the focus.
@function focus_reporting
@treturn bool
*/
static int
handle_focus_reporting(lua_State *L)
{
	lua_pushboolean(L, checkhandle(L)->focusing);
	return 1;
}


/***
What the program asked to be told about the mouse.
@function mouse_mode
@treturn int 0 for nothing, 1 for clicks, 2 for drags and 3 for all moves
*/
static int
handle_mouse_mode(lua_State *L)
{
	lua_pushinteger(L, checkhandle(L)->mouse);
	return 1;
}


/***
The title that the program set.
@function title
@treturn string|nil the title, which is nil if none was set
*/
static int
handle_title(lua_State *L)
{
	Handle *h = checkhandle(L);

	if (h->title == NULL)
		lua_pushnil(L);
	else
		lua_pushlstring(L, h->title, h->titlelen);
	return 1;
}


/***
Take how many times the program rang the bell.
@function bells
@treturn int the number of bells since the last call, which is forgotten
*/
static int
handle_bells(lua_State *L)
{
	Handle *h = checkhandle(L);

	lua_pushinteger(L, h->bells);
	h->bells = 0;
	return 1;
}


/***
Whether the program is on the alternate screen.
@function altscreen
@treturn bool
*/
static int
handle_altscreen(lua_State *L)
{
	lua_pushboolean(L, checkhandle(L)->alt);
	return 1;
}


/***
Whether the program has the cursor shown.
@function cursor_visible
@treturn bool
*/
static int
handle_cursor_visible(lua_State *L)
{
	lua_pushboolean(L, checkhandle(L)->shown);
	return 1;
}


static const luaL_Reg handle_methods[] =
{
	{"write",	handle_write},
	{"resize",	handle_resize},
	{"reset",	handle_reset},
	{"cursor",	handle_cursor},
	{"cell",	handle_cell},
	{"runs",	handle_runs},
	{"output",	handle_output},
	{"key",		handle_key},
	{"char",	handle_char},
	{"paste",	handle_paste},
	{"scrollback_size",	handle_scrollback_size},
	{"scrollback_line",	handle_scrollback_line},
	{"scrollback_runs",	handle_scrollback_runs},
	{"scrollback_clear",	handle_scrollback_clear},
	{"altscreen",	handle_altscreen},
	{"cursor_visible",	handle_cursor_visible},
	{"mouse_move",	handle_mouse_move},
	{"mouse_button",	handle_mouse_button},
	{"mouse_mode",	handle_mouse_mode},
	{"set_termprop",	handle_set_termprop},
	{"focus_in",	handle_focus_in},
	{"focus_out",	handle_focus_out},
	{"focus_reporting",	handle_focus_reporting},
	{"title",	handle_title},
	{"bells",	handle_bells},
	{NULL,		NULL}
};


/* Add the functions in L to the table at the top of the stack, which
   `luaL_setfuncs` does from Lua 5.2. */
static void
addfuncs(lua_State *L, const luaL_Reg *funcs)
{
	for (; funcs->name != NULL; funcs++)
	{
		lua_pushcfunction(L, funcs->func);
		lua_setfield(L, -2, funcs->name);
	}
}


LUALIB_API int
luaopen_lvterm_core(lua_State *L)
{
	luaL_newmetatable(L, HANDLE);
	lua_newtable(L);
	addfuncs(L, handle_methods);
	lua_setfield(L, -2, "__index");
	lua_pushcfunction(L, handle_gc);
	lua_setfield(L, -2, "__gc");
	lua_pop(L, 1);

	lua_newtable(L);
	lua_pushliteral(L, "core");
	lua_setfield(L, -2, "name");
	lua_pushcfunction(L, core_new);
	lua_setfield(L, -2, "new");
	return 1;
}
