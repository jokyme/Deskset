/*
 * deskset_lua.c — see include/deskset_lua.h. Written for Deskset against the public Lua 5.1 API only; the Lua
 * sources in this folder are unmodified.
 */
#include "deskset_lua.h"

#include <setjmp.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef __APPLE__
#include <mach/mach_time.h>
#endif

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

#define DESKSET_MAX_ARGS 64
#define DESKSET_MAX_RESULTS 16
/* Nested calls on one state (Update -> host -> inline Lua on the same script -> ...). */
#define DESKSET_MAX_DEPTH 32
/* The count hook runs every this many VM instructions. */
#define DESKSET_HOOK_INTERVAL 1000

/* deskset_lstrlib.c: bounded string.find / match / gmatch / gsub. */
void deskset_lua_install_patterns(lua_State *L);
void deskset_lua_check_budget(lua_State *L, unsigned long steps);

/* Memory of all states together (0 = unlimited), so many Script measures cannot add up to exhaust the Mac. */
static _Atomic size_t total_used = 0;
static _Atomic size_t total_limit = 0;

struct deskset_lua {
    lua_State *L;
    size_t used;
    size_t limit;
    deskset_host_fn host;
    void *context;

    unsigned long long instruction_limit;
    double seconds_limit;
    unsigned long long instructions;
    /* now_ticks() value after which the running call is stopped (0 = no deadline). */
    uint64_t deadline;
    int aborted;
    int last_timed_out;
    char abort_message[160];

    int depth;
    /* An unprotected error happened (the state must not be touched again, not even closed). */
    int broken;
    /* The libraries or the prelude failed to load (the state is closed normally). */
    int open_failed;
    int internal_ref;
    char *prelude_name;
    jmp_buf *panic_jump;

    deskset_value results[DESKSET_MAX_RESULTS];
    char *result_strings[DESKSET_MAX_RESULTS];
    int result_count;
    char *error;
};

/* MARK: - Helpers */

static deskset_lua *state_of(lua_State *L) {
    void *ud = NULL;
    lua_getallocf(L, &ud);
    return (deskset_lua *)ud;
}

/* A monotonic clock read on every function call of a script (the call hook), so it must be cheap:
   mach_absolute_time takes about 4 ns, clock_gettime about 16 ns. */
#ifdef __APPLE__
static uint64_t now_ticks(void) { return mach_absolute_time(); }
static double ticks_per_second(void) {
    static double value = 0;
    if (value == 0) {
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        value = 1e9 * (double)timebase.denom / (double)timebase.numer;
    }
    return value;
}
#else
static uint64_t now_ticks(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}
static double ticks_per_second(void) { return 1e9; }
#endif

static double monotonic_seconds(void) { return (double)now_ticks() / ticks_per_second(); }

static void set_error(deskset_lua *p, const char *message, size_t length) {
    free(p->error);
    p->error = (char *)malloc(length + 1);
    if (p->error) {
        memcpy(p->error, message, length);
        p->error[length] = '\0';
    }
}

static void clear_results(deskset_lua *p) {
    int i;
    for (i = 0; i < p->result_count; i++) {
        free(p->result_strings[i]);
        p->result_strings[i] = NULL;
    }
    p->result_count = 0;
}

int deskset_lua_format_number(double number, char *buffer, size_t size) {
    return snprintf(buffer, size, LUA_NUMBER_FMT, number);
}

/* Describes the value at `index` without raising errors or allocating Lua memory. String pointers point into
   the Lua stack. */
static void describe(lua_State *L, int index, deskset_value *out) {
    int type = lua_type(L, index);
    memset(out, 0, sizeof(*out));
    switch (type) {
    case LUA_TNONE:
    case LUA_TNIL:
        out->kind = DESKSET_NIL;
        break;
    case LUA_TBOOLEAN:
        out->kind = DESKSET_BOOLEAN;
        out->boolean = lua_toboolean(L, index);
        break;
    case LUA_TNUMBER:
        out->kind = DESKSET_NUMBER;
        out->number = lua_tonumber(L, index);
        break;
    case LUA_TSTRING:
        out->kind = DESKSET_STRING;
        out->string = lua_tolstring(L, index, &out->length);
        if (lua_isnumber(L, index)) {
            out->numeric = 1;
            out->number = lua_tonumber(L, index);
        }
        break;
    default:
        out->kind = DESKSET_OTHER;
        out->string = lua_typename(L, type);
        out->length = strlen(out->string);
        break;
    }
}

/* "file:line: " of the innermost Lua function that is not the prelude, starting at `level`. */
static void push_where(lua_State *L, int level) {
    deskset_lua *p = state_of(L);
    lua_Debug ar;
    int guard = 0;
    while (guard++ < 64 && lua_getstack(L, level++, &ar)) {
        if (!lua_getinfo(L, "Sl", &ar)) continue;
        if (ar.currentline <= 0) continue;
        if (p->prelude_name && ar.source && strcmp(ar.source, p->prelude_name) == 0) continue;
        lua_pushfstring(L, "%s:%d: ", ar.short_src, ar.currentline);
        return;
    }
    lua_pushliteral(L, "");
}

/* MARK: - Allocator and limits */

static void account(deskset_lua *p, size_t freed, size_t added) {
    size_t f = freed <= p->used ? freed : p->used;
    p->used = p->used - f + added;
    if (added >= f) {
        atomic_fetch_add(&total_used, added - f);
    } else {
        atomic_fetch_sub(&total_used, f - added);
    }
}

static void *deskset_alloc(void *ud, void *ptr, size_t osize, size_t nsize) {
    deskset_lua *p = (deskset_lua *)ud;
    void *block;
    if (nsize == 0) {
        free(ptr);
        account(p, osize, 0);
        return NULL;
    }
    if (nsize > osize) {
        size_t growth = nsize - osize;
        size_t all_limit = atomic_load(&total_limit);
        if (p->limit > 0) {
            size_t base = p->used - (osize <= p->used ? osize : p->used);
            if (base + nsize > p->limit || base + nsize < base) return NULL;
        }
        if (all_limit > 0) {
            size_t all = atomic_load(&total_used);
            if (all + growth > all_limit || all + growth < all) return NULL;
        }
    }
    block = realloc(ptr, nsize);
    if (block == NULL) {
        /* Lua 5.1 assumes that shrinking never fails. */
        return nsize <= osize ? ptr : NULL;
    }
    account(p, osize, nsize);
    return block;
}

static void begin_budget(deskset_lua *p) {
    /* At most a year, so the conversion to ticks cannot overflow. */
    double seconds = p->seconds_limit < 3.0e7 ? p->seconds_limit : 3.0e7;
    p->instructions = 0;
    p->aborted = 0;
    p->abort_message[0] = '\0';
    p->deadline = seconds > 0 ? now_ticks() + (uint64_t)(seconds * ticks_per_second()) : 0;
}

/* Adds `work` to the instruction count, checks both limits, and raises the "script stopped" error once the call
   has been aborted. `level` is the stack level where the message's file:line is looked up. */
static void spend(lua_State *L, deskset_lua *p, unsigned long long work, int level) {
    p->instructions += work;
    if (!p->aborted) {
        if (p->instruction_limit > 0 && p->instructions > p->instruction_limit) {
            p->aborted = 1;
            snprintf(p->abort_message, sizeof(p->abort_message),
                     "script stopped after %llu instructions (endless loop?)", p->instruction_limit);
        } else if (p->deadline > 0 && now_ticks() > p->deadline) {
            p->aborted = 1;
            snprintf(p->abort_message, sizeof(p->abort_message),
                     "script stopped after running for %.1f seconds (endless loop?)", p->seconds_limit);
        }
    }
    if (p->aborted) {
        push_where(L, level);
        lua_pushstring(L, p->abort_message);
        lua_concat(L, 2);
        lua_error(L);
    }
}

/* Count events: VM instructions. Call events (every Lua or C function call): the budget is checked before the
   call, so a loop of slow library calls (sorting a huge table, searching a long string…) — a few VM instructions
   per iteration — stops at the next call after the deadline instead of after the next 1000 instructions. */
static void deskset_hook(lua_State *L, lua_Debug *ar) {
    deskset_lua *p = state_of(L);
    spend(L, p, ar->event == LUA_HOOKCOUNT ? DESKSET_HOOK_INTERVAL : 0, 0);
}

/* The pattern matcher (deskset_lstrlib.c) runs in one C call; it reports its steps here. */
void deskset_lua_check_budget(lua_State *L, unsigned long steps) {
    deskset_lua *p = state_of(L);
    if (p == NULL) return;
    spend(L, p, steps, 1);
}

/* Windows' clock() (which Lua's os.clock uses) counts wall-clock time since the process started; the C library
   on macOS counts CPU time, which barely moves for an idle app. Scripts time animations and timeouts with it, so
   os.clock returns wall-clock seconds since the first Lua state was opened. */
static double clock_origin = -1;

static int deskset_os_clock(lua_State *L) {
    lua_pushnumber(L, monotonic_seconds() - clock_origin);
    return 1;
}

static int deskset_panic(lua_State *L) {
    deskset_lua *p = state_of(L);
    if (p && p->panic_jump) longjmp(*p->panic_jump, 1);
    return 0; /* Lua then calls exit(): only reachable without an armed jump, which the entry points prevent. */
}

/* A limit hit inside pcall / xpcall / coroutine.resume / load must stop the whole call: call the original
   function (upvalue 1), then raise again when the call has been aborted. */
static int guarded_call(lua_State *L) {
    deskset_lua *p = state_of(L);
    lua_pushvalue(L, lua_upvalueindex(1));
    lua_insert(L, 1);
    lua_call(L, lua_gettop(L) - 1, LUA_MULTRET);
    if (p->aborted) {
        push_where(L, 1);
        lua_pushstring(L, p->abort_message);
        lua_concat(L, 2);
        return lua_error(L);
    }
    return lua_gettop(L);
}

static void guard_function(lua_State *L, const char *table, const char *name) {
    if (table) {
        lua_getglobal(L, table);
    } else {
        lua_pushvalue(L, LUA_GLOBALSINDEX);
    }
    if (lua_istable(L, -1)) {
        lua_getfield(L, -1, name);
        if (lua_isfunction(L, -1)) {
            lua_pushcclosure(L, guarded_call, 1);
            lua_setfield(L, -2, name);
        } else {
            lua_pop(L, 1);
        }
    }
    lua_pop(L, 1);
}

/* MARK: - Safe replacements
 *
 * Lua 5.1 trusts its C API users; a few library functions hand that trust to scripts. Each replacement below
 * closes one way for a script from a downloaded skin to crash the app or run native code. */

/* Binary chunks: Lua 5.1 loads precompiled bytecode without a sound verifier, so crafted bytecode can corrupt
   memory. Skins ship source code; only text chunks are loaded. */
static int is_binary(const char *code, size_t length) {
    return length > 0 && code[0] == LUA_SIGNATURE[0];
}

static int load_text(lua_State *L, const char *code, size_t length, const char *chunkname) {
    if (is_binary(code, length)) {
        lua_pushliteral(L, "binary (precompiled) chunks are not supported");
        return LUA_ERRSYNTAX;
    }
    return luaL_loadbuffer(L, code, length, chunkname);
}

/* loadstring(string [, chunkname]) */
static int safe_loadstring(lua_State *L) {
    size_t length;
    const char *code = luaL_checklstring(L, 1, &length);
    const char *chunkname = luaL_optstring(L, 2, code);
    if (load_text(L, code, length, chunkname) == 0) return 1;
    lua_pushnil(L);
    lua_insert(L, -2); /* nil, message */
    return 2;
}

typedef struct {
    int first;
} reader_state;

/* Like Lua's own reader for load(): calls the function (stack slot 1), keeps the piece in the reserved slot 3; the
   first piece may not start a binary chunk. */
static const char *safe_reader(lua_State *L, void *ud, size_t *size) {
    reader_state *state = (reader_state *)ud;
    const char *piece;
    luaL_checkstack(L, 2, "too many nested functions");
    lua_pushvalue(L, 1);
    lua_call(L, 0, 1);
    if (lua_isnil(L, -1)) {
        *size = 0;
        return NULL;
    }
    if (!lua_isstring(L, -1)) luaL_error(L, "reader function must return a string");
    lua_replace(L, 3);
    piece = lua_tolstring(L, 3, size);
    if (state->first) {
        state->first = 0;
        if (is_binary(piece, *size)) luaL_error(L, "binary (precompiled) chunks are not supported");
    }
    return piece;
}

/* load(function [, chunkname]) */
static int safe_load(lua_State *L) {
    reader_state state;
    const char *chunkname = luaL_optstring(L, 2, "=(load)");
    luaL_checktype(L, 1, LUA_TFUNCTION);
    lua_settop(L, 3); /* function, chunk name, reserved slot */
    state.first = 1;
    if (lua_load(L, safe_reader, &state, chunkname) == 0) return 1;
    lua_pushnil(L);
    lua_insert(L, -2);
    return 2;
}

/* debug.getfenv / debug.setfenv reach the environment of any object. The io library keeps its default files and
   close functions in the environments of its C functions and file handles and reads them back without type
   checks, so replacing them crashed the app (e.g. debug.setfenv(file, {}) then file:close()). Here they work on
   Lua functions and threads only (what base getfenv / setfenv reach); other objects have no environment (nil). */
static int has_script_environment(lua_State *L, int index) {
    return (lua_isfunction(L, index) && !lua_iscfunction(L, index)) || lua_isthread(L, index);
}

static int safe_getfenv(lua_State *L) {
    luaL_checkany(L, 1);
    if (has_script_environment(L, 1)) {
        lua_getfenv(L, 1);
    } else {
        lua_pushnil(L);
    }
    return 1;
}

static int safe_setfenv(lua_State *L) {
    luaL_checktype(L, 2, LUA_TTABLE);
    if (!has_script_environment(L, 1)) return luaL_argerror(L, 1, "Lua function or thread expected");
    lua_settop(L, 2);
    if (lua_setfenv(L, 1) == 0) luaL_error(L, LUA_QL("setfenv") " cannot change environment of given object");
    return 1;
}

/* debug.setlocal could overwrite the stack slots of a running C function (table.sort's table, a string gsub is
   scanning) or the VM's hidden temporaries, which the C code and the VM use without type checks. Only the named
   local variables of Lua functions can be changed; for anything else it returns nil like for a missing local. */
static int safe_setlocal(lua_State *L) {
    int arg = 0;
    lua_State *L1 = L;
    lua_Debug ar;
    const char *name;
    int n;
    if (lua_isthread(L, 1)) {
        arg = 1;
        L1 = lua_tothread(L, 1);
    }
    if (!lua_getstack(L1, luaL_checkint(L, arg + 1), &ar)) return luaL_argerror(L, arg + 1, "level out of range");
    n = luaL_checkint(L, arg + 2);
    luaL_checkany(L, arg + 3);
    if (!lua_getinfo(L1, "S", &ar) || strcmp(ar.what, "C") == 0) {
        lua_pushnil(L);
        return 1;
    }
    name = lua_getlocal(L1, &ar, n);
    if (name == NULL) {
        lua_pushnil(L);
        return 1;
    }
    lua_pop(L1, 1);
    if (name[0] == '(') { /* (for index), (*temporary)…: VM internals */
        lua_pushnil(L);
        return 1;
    }
    lua_settop(L, arg + 3);
    lua_xmove(L, L1, 1);
    lua_pushstring(L, lua_setlocal(L1, &ar, n));
    return 1;
}

static void set_function(lua_State *L, const char *table, const char *name, lua_CFunction f) {
    if (table) {
        lua_getglobal(L, table);
    } else {
        lua_pushvalue(L, LUA_GLOBALSINDEX);
    }
    if (lua_istable(L, -1)) {
        lua_pushcfunction(L, f);
        lua_setfield(L, -2, name);
    }
    lua_pop(L, 1);
}

/* The file handles' metatable doubles as their method table (__index = itself), so `io.stdout.__index` handed it
   to scripts even with getmetatable hidden, and a Lua __gc set there ran with hooks off during garbage collection:
   an endless loop in it froze the app for good. The methods move to their own table; the metatable keeps only the
   metamethods and is no longer reachable from scripts. */
static void split_file_methods(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, LUA_FILEHANDLE);
    if (lua_istable(L, -1)) {
        lua_newtable(L); /* methods */
        lua_pushnil(L);
        while (lua_next(L, -3) != 0) {
            /* key at -2, value at -1; copy entries whose key does not start with "__" */
            if (lua_type(L, -2) == LUA_TSTRING && strncmp(lua_tostring(L, -2), "__", 2) != 0) {
                lua_pushvalue(L, -2);
                lua_insert(L, -2);
                lua_settable(L, -4);
            } else {
                lua_pop(L, 1);
            }
        }
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
}

static void remove_function(lua_State *L, const char *table, const char *name) {
    if (table) {
        lua_getglobal(L, table);
    } else {
        lua_pushvalue(L, LUA_GLOBALSINDEX);
    }
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        lua_setfield(L, -2, name);
    }
    lua_pop(L, 1);
}

/* MARK: - Host trampoline */

static void push_value(lua_State *L, const deskset_value *v);

static int host_trampoline(lua_State *L) {
    deskset_lua *p = state_of(L);
    deskset_value args[DESKSET_MAX_ARGS];
    const deskset_value *results = NULL;
    int result_count = 0;
    int count = lua_gettop(L);
    int status;
    int i;
    if (count > DESKSET_MAX_ARGS) {
        push_where(L, 1);
        lua_pushliteral(L, "too many arguments");
        lua_concat(L, 2);
        return lua_error(L);
    }
    if (p->host == NULL) {
        push_where(L, 1);
        lua_pushliteral(L, "the skin is being unloaded");
        lua_concat(L, 2);
        return lua_error(L);
    }
    for (i = 0; i < count; i++) describe(L, i + 1, &args[i]);
    status = p->host(p->context, args, count, &results, &result_count);
    if (status != DESKSET_OK) {
        push_where(L, 1);
        if (result_count > 0 && results && results[0].kind == DESKSET_STRING) {
            lua_pushlstring(L, results[0].string ? results[0].string : "", results[0].length);
        } else {
            lua_pushliteral(L, "error in a skin function");
        }
        lua_concat(L, 2);
        return lua_error(L);
    }
    if (result_count < 0 || results == NULL) result_count = 0;
    luaL_checkstack(L, result_count, "too many results");
    for (i = 0; i < result_count; i++) push_value(L, &results[i]);
    return result_count;
}

/* MARK: - Protected operations */

enum { OP_OPEN, OP_RUN, OP_CALL, OP_GLOBAL, OP_EVAL, OP_INTERNAL };

typedef struct {
    deskset_lua *p;
    int op;
    const char *name;
    const char *code;
    size_t length;
    const char *chunkname;
    const deskset_value *args;
    int count;
    int missing;
} deskset_request;

static void load_expression(lua_State *L, const char *expression, size_t length) {
    static const char prefix[] = "return (";
    size_t total = sizeof(prefix) - 1 + length + 1;
    char *code = (char *)malloc(total);
    int status;
    if (code == NULL) {
        lua_pushliteral(L, "not enough memory");
        lua_error(L);
        return;
    }
    memcpy(code, prefix, sizeof(prefix) - 1);
    memcpy(code + sizeof(prefix) - 1, expression, length);
    code[total - 1] = ')';
    status = load_text(L, code, total, "=inline");
    free(code);
    if (status != 0) lua_error(L);
}

static void push_value(lua_State *L, const deskset_value *v) {
    switch (v->kind) {
    case DESKSET_BOOLEAN:
        lua_pushboolean(L, v->boolean);
        break;
    case DESKSET_NUMBER:
        lua_pushnumber(L, v->number);
        break;
    case DESKSET_STRING:
        lua_pushlstring(L, v->string ? v->string : "", v->string ? v->length : 0);
        break;
    case DESKSET_EXPRESSION:
        load_expression(L, v->string ? v->string : "", v->string ? v->length : 0);
        lua_call(L, 0, 1);
        break;
    default:
        lua_pushnil(L);
        break;
    }
}

static void push_arguments(lua_State *L, const deskset_value *args, int count) {
    int i;
    luaL_checkstack(L, count + LUA_MINSTACK, "too many arguments");
    for (i = 0; i < count; i++) push_value(L, &args[i]);
}

/* Copies the values on the stack into C memory (no Lua allocation, cannot raise). */
static void store_results(deskset_lua *p, lua_State *L) {
    int top = lua_gettop(L);
    int i;
    clear_results(p);
    for (i = 1; i <= top && i <= DESKSET_MAX_RESULTS; i++) {
        deskset_value v;
        describe(L, i, &v);
        if ((v.kind == DESKSET_STRING || v.kind == DESKSET_OTHER) && v.string) {
            char *copy = (char *)malloc(v.length + 1);
            if (copy) {
                memcpy(copy, v.string, v.length);
                copy[v.length] = '\0';
            } else {
                v.length = 0;
            }
            p->result_strings[i - 1] = copy;
            v.string = copy ? copy : "";
        }
        p->results[i - 1] = v;
        p->result_count = i;
    }
}

static void open_library(lua_State *L, lua_CFunction open, const char *name) {
    lua_pushcfunction(L, open);
    lua_pushstring(L, name);
    lua_call(L, 1, 0);
}

static int protected_main(lua_State *L) {
    deskset_request *r = (deskset_request *)lua_touserdata(L, 1);
    deskset_lua *p = r->p;
    lua_settop(L, 0);
    switch (r->op) {
    case OP_OPEN:
        open_library(L, luaopen_base, "");
        open_library(L, luaopen_table, LUA_TABLIBNAME);
        open_library(L, luaopen_io, LUA_IOLIBNAME);
        open_library(L, luaopen_os, LUA_OSLIBNAME);
        open_library(L, luaopen_string, LUA_STRLIBNAME);
        open_library(L, luaopen_math, LUA_MATHLIBNAME);
        open_library(L, luaopen_debug, LUA_DBLIBNAME);
        /* Manual (Lua Scripting, "Restrictions"): require, os.exit, os.setlocale, io.popen and collectgarbage are
           not available (the package library, and with it require and module, is not opened at all).
           debug.sethook would let a script remove the limits. */
        remove_function(L, NULL, "collectgarbage");
        remove_function(L, "os", "exit");
        remove_function(L, "os", "setlocale");
        remove_function(L, "io", "popen");
        remove_function(L, "debug", "sethook");
        /* Lua 5.1 runs __gc metamethods with hooks disabled, so no limit could stop an endless loop in one. Scripts
           must not be able to attach Lua code to garbage collection: newproxy (undocumented) is removed, the
           metatable of file handles is hidden (__metatable), and the debug functions that reach raw metatables and
           the registry are removed. */
        remove_function(L, NULL, "newproxy");
        remove_function(L, "debug", "getmetatable");
        remove_function(L, "debug", "setmetatable");
        remove_function(L, "debug", "getregistry");
        split_file_methods(L);
        /* Memory safety against hostile scripts (see "Safe replacements"). */
        set_function(L, NULL, "loadstring", safe_loadstring);
        set_function(L, NULL, "load", safe_load);
        set_function(L, "debug", "getfenv", safe_getfenv);
        set_function(L, "debug", "setfenv", safe_setfenv);
        set_function(L, "debug", "setlocal", safe_setlocal);
        deskset_lua_install_patterns(L);
        lua_getglobal(L, "os");
        if (lua_istable(L, -1)) {
            lua_pushcfunction(L, deskset_os_clock);
            lua_setfield(L, -2, "clock");
        }
        lua_pop(L, 1);
        guard_function(L, NULL, "pcall");
        guard_function(L, NULL, "xpcall");
        guard_function(L, NULL, "load");
        guard_function(L, "coroutine", "resume");
        if (load_text(L, r->code, r->length, r->chunkname) != 0) lua_error(L);
        lua_pushcfunction(L, host_trampoline);
        lua_call(L, 1, 1);
        if (!lua_istable(L, -1)) luaL_error(L, "the prelude did not return a table");
        p->internal_ref = luaL_ref(L, LUA_REGISTRYINDEX);
        lua_settop(L, 0);
        /* After the prelude has adapted the file methods: hide the file handles' metatable. */
        lua_getfield(L, LUA_REGISTRYINDEX, LUA_FILEHANDLE);
        if (lua_istable(L, -1)) {
            lua_pushboolean(L, 0);
            lua_setfield(L, -2, "__metatable");
        }
        lua_settop(L, 0);
        break;
    case OP_RUN:
        if (load_text(L, r->code, r->length, r->chunkname) != 0) lua_error(L);
        lua_call(L, 0, LUA_MULTRET);
        break;
    case OP_CALL:
        lua_getglobal(L, r->name);
        if (!lua_isfunction(L, -1)) {
            r->missing = 1;
            lua_settop(L, 0);
            break;
        }
        push_arguments(L, r->args, r->count);
        lua_call(L, r->count, LUA_MULTRET);
        break;
    case OP_GLOBAL:
        lua_getglobal(L, r->name);
        break;
    case OP_EVAL:
        load_expression(L, r->code, r->length);
        lua_call(L, 0, 1);
        break;
    case OP_INTERNAL:
        lua_rawgeti(L, LUA_REGISTRYINDEX, p->internal_ref);
        lua_getfield(L, -1, r->name);
        lua_remove(L, -2);
        if (!lua_isfunction(L, -1)) {
            r->missing = 1;
            lua_settop(L, 0);
            break;
        }
        push_arguments(L, r->args, r->count);
        lua_call(L, r->count, LUA_MULTRET);
        break;
    }
    store_results(p, L);
    return 0;
}

static int run_request(deskset_lua *p, deskset_request *r) {
    jmp_buf jump;
    jmp_buf *saved;
    volatile int status = 0;
    volatile int panicked = 0;
    lua_State *L;
    if (p == NULL || p->broken || p->open_failed || p->L == NULL) return DESKSET_BROKEN;
    L = p->L;
    if (p->depth >= DESKSET_MAX_DEPTH) {
        static const char message[] = "script calls are nested too deeply";
        set_error(p, message, sizeof(message) - 1);
        return DESKSET_ERROR;
    }
    if (p->depth == 0) begin_budget(p);
    p->depth++;
    r->p = p;
    r->missing = 0;
    saved = p->panic_jump;
    p->panic_jump = &jump;
    if (setjmp(jump) == 0) {
        status = lua_cpcall(L, protected_main, r);
    } else {
        panicked = 1;
    }
    p->panic_jump = saved;
    p->depth--;
    if (p->depth == 0) p->last_timed_out = p->aborted;
    if (panicked) {
        static const char message[] = "the Lua state failed and was stopped";
        p->broken = 1;
        set_error(p, message, sizeof(message) - 1);
        return DESKSET_BROKEN;
    }
    if (status != 0) {
        int type = lua_type(L, -1);
        clear_results(p);
        if (type == LUA_TSTRING) {
            size_t length = 0;
            const char *message = lua_tolstring(L, -1, &length);
            set_error(p, message, length);
        } else if (type == LUA_TNUMBER) {
            char buffer[64];
            int n = deskset_lua_format_number(lua_tonumber(L, -1), buffer, sizeof(buffer));
            set_error(p, buffer, n > 0 ? (size_t)n : 0);
        } else {
            char buffer[96];
            int n = snprintf(buffer, sizeof(buffer), "(error object is a %s value)", lua_typename(L, type));
            set_error(p, buffer, n > 0 ? (size_t)n : 0);
        }
        lua_pop(L, 1);
        return DESKSET_ERROR;
    }
    return r->missing ? DESKSET_MISSING : DESKSET_OK;
}

/* MARK: - Public API */

deskset_lua *deskset_lua_open(size_t memory_limit, deskset_host_fn host, void *context,
                            const char *prelude, size_t prelude_length, const char *prelude_name) {
    deskset_request r;
    deskset_lua *p = (deskset_lua *)calloc(1, sizeof(deskset_lua));
    if (p == NULL) return NULL;
    p->limit = memory_limit;
    p->host = host;
    p->context = context;
    p->internal_ref = LUA_NOREF;
    p->seconds_limit = 5;
    if (prelude_name) {
        size_t n = strlen(prelude_name);
        p->prelude_name = (char *)malloc(n + 1);
        if (p->prelude_name) memcpy(p->prelude_name, prelude_name, n + 1);
    }
    if (clock_origin < 0) clock_origin = monotonic_seconds();
    p->L = lua_newstate(deskset_alloc, p);
    if (p->L == NULL) {
        free(p->prelude_name);
        free(p);
        return NULL;
    }
    lua_atpanic(p->L, deskset_panic);
    lua_sethook(p->L, deskset_hook, LUA_MASKCOUNT | LUA_MASKCALL, DESKSET_HOOK_INTERVAL);
    memset(&r, 0, sizeof(r));
    r.op = OP_OPEN;
    r.code = prelude;
    r.length = prelude_length;
    r.chunkname = prelude_name ? prelude_name : "=prelude";
    if (run_request(p, &r) != DESKSET_OK) p->open_failed = 1;
    clear_results(p);
    return p;
}

int deskset_lua_status(const deskset_lua *p) {
    return (p == NULL || p->broken || p->open_failed) ? DESKSET_BROKEN : DESKSET_OK;
}

void deskset_lua_detach(deskset_lua *p) {
    if (p) {
        p->host = NULL;
        p->context = NULL;
    }
}

void deskset_lua_close(deskset_lua *p) {
    jmp_buf jump;
    if (p == NULL) return;
    p->host = NULL;
    p->context = NULL;
    if (p->L && !p->broken) {
        /* lua_close runs the __gc metamethods, with hooks off (Lua 5.1); the only ones left are the io library's C
           functions that close open files. */
        begin_budget(p);
        p->panic_jump = &jump;
        if (setjmp(jump) == 0) lua_close(p->L);
        p->panic_jump = NULL;
    } else if (p->L) {
        /* A broken state is abandoned, not closed: its memory no longer counts against the total. */
        account(p, p->used, 0);
    }
    p->L = NULL;
    clear_results(p);
    free(p->error);
    free(p->prelude_name);
    free(p);
}

void deskset_lua_set_total_memory_limit(size_t limit) { atomic_store(&total_limit, limit); }
size_t deskset_lua_total_memory_used(void) { return atomic_load(&total_used); }

void deskset_lua_set_limits(deskset_lua *p, unsigned long long instructions, double seconds) {
    if (p == NULL) return;
    p->instruction_limit = instructions;
    p->seconds_limit = seconds;
}

int deskset_lua_timed_out(const deskset_lua *p) { return p ? p->last_timed_out : 0; }
size_t deskset_lua_memory_used(const deskset_lua *p) { return p ? p->used : 0; }
size_t deskset_lua_memory_limit(const deskset_lua *p) { return p ? p->limit : 0; }
int deskset_lua_depth(const deskset_lua *p) { return p ? p->depth : 0; }

int deskset_lua_run(deskset_lua *p, const char *code, size_t length, const char *chunkname) {
    deskset_request r;
    memset(&r, 0, sizeof(r));
    r.op = OP_RUN;
    r.code = code ? code : "";
    r.length = code ? length : 0;
    r.chunkname = chunkname ? chunkname : "=script";
    return run_request(p, &r);
}

int deskset_lua_call(deskset_lua *p, const char *name, const deskset_value *args, int count) {
    deskset_request r;
    memset(&r, 0, sizeof(r));
    r.op = OP_CALL;
    r.name = name ? name : "";
    r.args = args;
    r.count = args ? count : 0;
    return run_request(p, &r);
}

int deskset_lua_get_global(deskset_lua *p, const char *name) {
    deskset_request r;
    memset(&r, 0, sizeof(r));
    r.op = OP_GLOBAL;
    r.name = name ? name : "";
    return run_request(p, &r);
}

int deskset_lua_eval(deskset_lua *p, const char *expression, size_t length) {
    deskset_request r;
    memset(&r, 0, sizeof(r));
    r.op = OP_EVAL;
    r.code = expression ? expression : "";
    r.length = expression ? length : 0;
    return run_request(p, &r);
}

int deskset_lua_call_internal(deskset_lua *p, const char *name, const deskset_value *args, int count) {
    deskset_request r;
    memset(&r, 0, sizeof(r));
    r.op = OP_INTERNAL;
    r.name = name ? name : "";
    r.args = args;
    r.count = args ? count : 0;
    return run_request(p, &r);
}

int deskset_lua_result_count(const deskset_lua *p) { return p ? p->result_count : 0; }

deskset_value deskset_lua_result(const deskset_lua *p, int index) {
    deskset_value none;
    if (p == NULL || index < 0 || index >= p->result_count) {
        memset(&none, 0, sizeof(none));
        return none;
    }
    return p->results[index];
}

const char *deskset_lua_error_message(const deskset_lua *p) {
    return (p && p->error) ? p->error : "";
}
