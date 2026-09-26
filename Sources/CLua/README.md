# CLua — Lua 5.1.5 (sources unmodified) + Deskset shims

Source: https://www.lua.org/ftp/lua-5.1.5.tar.gz
(sha256 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333). MIT license, see COPYRIGHT.

Rainmeter skins are written for Lua 5.1, so this exact version is embedded. `lua.c`, `luac.c` and `print.c`
(standalone interpreter/compiler) are not included. Public headers are in `include/`. Built with `LUA_USE_POSIX`
and without `LUA_USE_DLOPEN`, so `require` cannot load native modules.

## Lua's own files

Every file from the Lua 5.1.5 distribution in this folder (`l*.c`, `l*.h`, `include/lua.h`, `lauxlib.h`,
`lualib.h`, `luaconf.h`) is byte-for-byte the released file — none of them is edited, `lstrlib.c` included. What
Deskset changes is done from the outside, at run time, by the files below, which replace or remove library functions
in each script's state after the standard libraries are opened.

## Deskset's files

- `include/deskset_lua.h`, `deskset_lua.c` — written for Deskset against Lua's public C API (not derived from Lua's
  sources). The bridge between Swift and Lua: every Lua operation that can raise an error runs inside
  `lua_cpcall`, so Lua's `longjmp` never crosses Swift frames, and values are exchanged as plain C structs. It opens
  the libraries Rainmeter scripts use and adapts them for scripts from untrusted skins:
  - limits: a memory cap per state and for all states together (custom allocator); an instruction-count hook and a
    call hook with a wall-clock deadline per outermost call; nested calls limited to 32 levels. `pcall`, `xpcall`,
    `coroutine.resume` and `load` are wrapped so a script cannot catch the "script stopped" error of a limit;
  - removed, as the Rainmeter manual lists: `require` / `module` (the `package` library is not opened),
    `os.exit`, `os.setlocale`, `io.popen`, `collectgarbage`; removed as well: `debug.sethook` (it would remove the
    limits), `newproxy`, `debug.getmetatable`, `debug.setmetatable`, `debug.getregistry`, and the file handles'
    metatable is hidden with their methods moved to a table of their own (so no Lua `__gc` code can run, where no
    limit could stop it);
  - restricted: `loadstring` / `load` accept text chunks only (no precompiled bytecode, which Lua 5.1 does not
    verify); `debug.getfenv` / `debug.setfenv` work only on Lua functions and threads; `debug.setlocal` changes only
    named locals of Lua functions (not C frames or the VM's hidden loop variables);
  - `os.clock` returns wall-clock seconds since Lua was registered at launch (like Windows' `clock()`, which counts
    from the process start), not CPU time; its origin is set once for the process (`deskset_lua_start_clock`).
- `deskset_lstrlib.c` — derived from the pattern-matching part of Lua 5.1.5's `lstrlib.c` (Copyright © 1994–2012
  Lua.org, PUC-Rio, MIT license, see COPYRIGHT). It is a separate, modified copy; `lstrlib.c` itself is compiled
  unchanged and its `string.find`, `string.match`, `string.gmatch` and `string.gsub` (and the `string.gfind` alias)
  are replaced in each state by these. Changes: the matcher's recursion is limited to 200 levels ("pattern too
  complex", the limit Lua 5.2 and later have) instead of overflowing the C stack, and every 4096 matcher steps it
  checks the running call's time / instruction budget (a backtracking pattern can otherwise run practically forever
  inside one C call, where the hooks cannot run). Results are otherwise identical to Lua 5.1.5.

Further adaptations are written in Lua, outside this folder: the prelude in
`Sources/DesksetCore/Engine/Lua/LuaPrelude.swift` runs in each state after the shim has opened the libraries and
replaces `dofile` / `loadfile` (script files are read by the host and loaded as text through the restricted
`loadstring`, so no file can load bytecode either), `print`, `os.execute`, `os.getenv`, `os.date` (`%#d` flags),
`string.rep` (an empty string repeated a huge number of times would spin in C), the default input (`/dev/null`) and
the path handling of the `io` / `os` file functions. The file handles' metatable is hidden only after the prelude has
run.

Behaviour visible to skins is documented in `docs/compat/lua.md`.
