/*
 * deskset_lua.h — a small C shim between Swift and the embedded Lua 5.1 (Deskset, Measure=Script).
 *
 * Swift cannot call Lua's C macros, and must never be unwound by Lua's error handling (longjmp across Swift
 * frames is undefined behaviour). So every Lua operation that can raise an error runs here, inside
 * lua_cpcall, and Swift only ever sees plain values:
 *
 * - Swift -> Lua: deskset_lua_run / _call / _get_global / _eval / _call_internal. Results are copied into C
 *   memory owned by the state (read them with deskset_lua_result before the next call on the same state).
 * - Lua -> Swift: one host function (the `host` callback). Its arguments are plain values; its results are
 *   pointers into memory the Swift side keeps alive until its next callback returns. The C trampoline pushes
 *   them (and raises the host's error, if any) after Swift has returned.
 *
 * Limits (per state): a memory cap enforced by a custom allocator (plus one for all states together), and an
 * instruction-count and call hook with a wall-clock deadline per outermost call; the pattern matcher (string.find,
 * match, gmatch, gsub — deskset_lstrlib.c) checks the same budget and has a recursion limit. Once a call has hit a
 * limit, pcall / xpcall / coroutine.resume / load cannot swallow the error: the whole call is stopped.
 *
 * Hostile scripts: besides the functions the manual removes, the shim removes or restricts every library function
 * that let a script crash the app or run native code (binary chunks, debug.setlocal on C frames, debug.setfenv on
 * C objects, Lua __gc metamethods); see "Safe replacements" in deskset_lua.c.
 */
#ifndef DESKSET_LUA_H
#define DESKSET_LUA_H

#include <stddef.h>

/* Value kinds exchanged with Swift. */
enum {
    DESKSET_NIL = 0,
    DESKSET_BOOLEAN = 1,
    DESKSET_NUMBER = 2,
    DESKSET_STRING = 3,
    /* Arguments only: `string` is a Lua expression evaluated in the script's global environment. */
    DESKSET_EXPRESSION = 4,
    /* Any other Lua type (table, function, userdata, thread); `string` is the type name. */
    DESKSET_OTHER = 5
};

/* Status codes. */
enum {
    DESKSET_OK = 0,
    DESKSET_ERROR = 1,     /* a Lua error; see deskset_lua_error_message */
    DESKSET_MISSING = 2,   /* deskset_lua_call: the global is not a function */
    DESKSET_BROKEN = 3     /* the state is unusable (failed to open, or an unprotected error happened) */
};

typedef struct deskset_value {
    int kind;
    int boolean;
    /* DESKSET_NUMBER: the number. DESKSET_STRING: the number the string converts to when `numeric` is set. */
    double number;
    int numeric;
    /* DESKSET_STRING / DESKSET_EXPRESSION: the bytes (not necessarily NUL-terminated). DESKSET_OTHER: type name. */
    const char *string;
    size_t length;
} deskset_value;

typedef struct deskset_lua deskset_lua;

/*
 * Host callback. `args` are the arguments of the Lua call (strings point into the Lua stack and are valid
 * during the callback only). Return DESKSET_OK and set *results / *result_count, or DESKSET_ERROR with
 * (*results)[0] a string message. The results memory must stay valid until the callback is entered again
 * (or the state is closed).
 */
typedef int (*deskset_host_fn)(void *context, const deskset_value *args, int count,
                              const deskset_value **results, int *result_count);

/*
 * Opens a state with the standard libraries Rainmeter scripts use (base, coroutine, table, string, math, io,
 * os, debug) minus the functions the manual lists as unavailable, then runs `prelude` (a Lua chunk) with the
 * host function as its first argument. The prelude must return a table of internal functions (see
 * deskset_lua_call_internal). Returns NULL only when out of memory; check deskset_lua_status for prelude errors.
 */
deskset_lua *deskset_lua_open(size_t memory_limit, deskset_host_fn host, void *context,
                            const char *prelude, size_t prelude_length, const char *prelude_name);
/* DESKSET_OK after a successful open, otherwise DESKSET_BROKEN (message in deskset_lua_error_message). */
int deskset_lua_status(const deskset_lua *p);
/* Stops host callbacks (the Swift side is going away); later host calls raise a Lua error instead. */
void deskset_lua_detach(deskset_lua *p);
void deskset_lua_close(deskset_lua *p);

/* Limits for each outermost call: instruction budget (0 = unlimited) and seconds (<= 0 = unlimited). */
void deskset_lua_set_limits(deskset_lua *p, unsigned long long instructions, double seconds);
/* True when the last outermost call was stopped by the instruction or time limit. */
int deskset_lua_timed_out(const deskset_lua *p);
size_t deskset_lua_memory_used(const deskset_lua *p);
size_t deskset_lua_memory_limit(const deskset_lua *p);
/* Memory of all states together: allocations that would exceed `limit` fail like the per-state limit (0 = none). */
void deskset_lua_set_total_memory_limit(size_t limit);
size_t deskset_lua_total_memory_used(void);
/* Number of calls currently running on this state (0 when idle). */
int deskset_lua_depth(const deskset_lua *p);
/* Starts os.clock's clock (and reads the tick rate) once for the whole process; later calls do nothing. Called when
   Lua is registered, and by deskset_lua_open for programs that never register it. Any thread. */
void deskset_lua_start_clock(void);

/* Loads `code` as a chunk named `chunkname` (`@file` or `=name`) and runs it. */
int deskset_lua_run(deskset_lua *p, const char *code, size_t length, const char *chunkname);
/* Calls the global function `name` with `args`; DESKSET_MISSING when the global is not a function. */
int deskset_lua_call(deskset_lua *p, const char *name, const deskset_value *args, int count);
/* The value of the global `name` (one result). */
int deskset_lua_get_global(deskset_lua *p, const char *name);
/* Evaluates `return <expression>` in the global environment. */
int deskset_lua_eval(deskset_lua *p, const char *expression, size_t length);
/* Calls the prelude's internal function `name`. */
int deskset_lua_call_internal(deskset_lua *p, const char *name, const deskset_value *args, int count);

/* Results of the last successful call (copied; valid until the next call on this state). */
int deskset_lua_result_count(const deskset_lua *p);
deskset_value deskset_lua_result(const deskset_lua *p, int index);
/* Message of the last failed call (NUL-terminated, never NULL). */
const char *deskset_lua_error_message(const deskset_lua *p);

/* The Lua number format ("%.14g"), for converting numbers to strings exactly as Lua's tostring does. */
int deskset_lua_format_number(double number, char *buffer, size_t size);

#endif
