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

 A thin binding of the polling interface of libvterm 0.3: feed a terminal
 bytes, then ask what its cells show and where its cursor is.  The
 `lvterm.Terminal` that `lvterm` makes is built over this, and over the
 FFI backend alike, so what a handle does is only what the two have in
 common.

 @module lvterm.core
*/

#include <stdint.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include <vterm.h>

#ifndef VTERM_COLOR_IS_DEFAULT_FG
#  error "lvterm needs libvterm 0.3"
#endif

#define HANDLE "lvterm.core.terminal"

typedef struct
{
	VTerm		*vt;
	VTermState	*state;
	VTermScreen	*screen;
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


/***
Make a new terminal.
@function new
@int rows height in lines
@int cols width in columns
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
	luaL_Buffer b;
	int i;

	pos.row = (int) luaL_checkinteger(L, 2);
	pos.col = (int) luaL_checkinteger(L, 3);
	if (!vterm_screen_get_cell(h->screen, pos, &cell))
		return luaL_error(L, "position %d,%d is not on the screen",
				  pos.row, pos.col);

	/* The text is a space for an empty cell, and nothing for the right
	   half of a wide character. */
	luaL_buffinit(L, &b);
	if (cell.chars[0] == 0)
		luaL_addchar(&b, ' ');
	for (i = 0; i < VTERM_MAX_CHARS_PER_CELL && cell.chars[i] != 0; i++)
		if (cell.chars[i] != (uint32_t) -1)
			addutf8(&b, cell.chars[i]);
	luaL_pushresult(&b);

	lua_createtable(L, 0, 11);
	lua_pushvalue(L, -2);
	lua_setfield(L, -2, "text");
	lua_pushinteger(L, cell.width);
	lua_setfield(L, -2, "width");
	setboolean(L, "bold", cell.attrs.bold);
	setboolean(L, "italic", cell.attrs.italic);
	setboolean(L, "blink", cell.attrs.blink);
	setboolean(L, "reverse", cell.attrs.reverse);
	setboolean(L, "conceal", cell.attrs.conceal);
	setboolean(L, "strike", cell.attrs.strike);
	lua_pushinteger(L, cell.attrs.underline);
	lua_setfield(L, -2, "underline");
	pushcolor(L, &cell.fg);
	lua_setfield(L, -2, "fg");
	pushcolor(L, &cell.bg);
	lua_setfield(L, -2, "bg");
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
	size_t n = vterm_output_get_buffer_current(h->vt);

	if (n == 0)
	{
		lua_pushliteral(L, "");
	}
	else
	{
		char *buffer = (char *) lua_newuserdata(L, n);

		lua_pushlstring(L, buffer, vterm_output_read(h->vt, buffer, n));
	}
	return 1;
}


static const luaL_Reg handle_methods[] =
{
	{"write",	handle_write},
	{"resize",	handle_resize},
	{"reset",	handle_reset},
	{"cursor",	handle_cursor},
	{"cell",	handle_cell},
	{"output",	handle_output},
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
