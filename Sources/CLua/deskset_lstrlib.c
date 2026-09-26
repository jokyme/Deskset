/*
 * deskset_lstrlib.c — bounded versions of string.find, string.match, string.gmatch and string.gsub for Deskset.
 *
 * Derived from the pattern-matching part of lstrlib.c of Lua 5.1.5:
 * Copyright (C) 1994-2012 Lua.org, PUC-Rio. MIT license (see COPYRIGHT in this folder).
 * The Lua sources in this folder stay unmodified; this file replaces the four functions in each script's state.
 *
 * Changes from Lua 5.1.5, both for scripts from untrusted skins:
 * - The matcher recurses once per pattern item such as `a?`, `a*` or `(`. Lua 5.1 has no bound, so a long pattern
 *   (`string.rep('a?', 200000)`) overflowed the C stack and crashed the app. The depth is limited to
 *   DESKSET_MAX_MATCH_DEPTH ("pattern too complex", the limit Lua 5.2 and later use).
 * - Backtracking can take practically forever (`('.-'):rep(8) .. 'x'` on a long string) inside one C call, where
 *   the instruction hook cannot run. Every DESKSET_MATCH_CHECK_INTERVAL steps the matcher asks the shim whether the
 *   script's time or instruction budget is used up (deskset_lua_check_budget), which stops the call like the hook.
 */
#include <ctype.h>
#include <stddef.h>
#include <string.h>

#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

/* Defined in deskset_lua.c: counts `steps` against the running call's budget and raises the "script stopped"
   error once the budget is used up. */
void deskset_lua_check_budget(lua_State *L, unsigned long steps);
/* Installs the functions below into the string table (called by deskset_lua.c before the prelude runs). */
void deskset_lua_install_patterns(lua_State *L);

#define DESKSET_MAX_MATCH_DEPTH 200
#define DESKSET_MATCH_CHECK_INTERVAL 4096

#define uchar(c) ((unsigned char)(c))

#define CAP_UNFINISHED (-1)
#define CAP_POSITION (-2)

typedef struct MatchState {
    const char *src_init; /* init of source string */
    const char *src_end;  /* end ('\0') of source string */
    lua_State *L;
    int level;            /* total number of captures (finished or unfinished) */
    int depth;            /* remaining recursion depth */
    unsigned long steps;  /* match() calls since the last budget check */
    struct {
        const char *init;
        ptrdiff_t len;
    } capture[LUA_MAXCAPTURES];
} MatchState;

#define L_ESC '%'
#define SPECIALS "^$*+?.([%-"

static ptrdiff_t posrelat(ptrdiff_t pos, size_t len) {
    /* relative string position: negative means back from end */
    if (pos < 0) pos += (ptrdiff_t)len + 1;
    return (pos >= 0) ? pos : 0;
}

static void prepare_state(MatchState *ms, lua_State *L, const char *s, size_t length) {
    ms->L = L;
    ms->src_init = s;
    ms->src_end = s + length;
    ms->level = 0;
    ms->depth = DESKSET_MAX_MATCH_DEPTH;
    ms->steps = 0;
}

static int check_capture(MatchState *ms, int l) {
    l -= '1';
    if (l < 0 || l >= ms->level || ms->capture[l].len == CAP_UNFINISHED)
        return luaL_error(ms->L, "invalid capture index");
    return l;
}

static int capture_to_close(MatchState *ms) {
    int level = ms->level;
    for (level--; level >= 0; level--)
        if (ms->capture[level].len == CAP_UNFINISHED) return level;
    return luaL_error(ms->L, "invalid pattern capture");
}

static const char *classend(MatchState *ms, const char *p) {
    switch (*p++) {
    case L_ESC:
        if (*p == '\0') luaL_error(ms->L, "malformed pattern (ends with " LUA_QL("%%") ")");
        return p + 1;
    case '[':
        if (*p == '^') p++;
        do { /* look for a ']' */
            if (*p == '\0') luaL_error(ms->L, "malformed pattern (missing " LUA_QL("]") ")");
            if (*(p++) == L_ESC && *p != '\0') p++; /* skip escapes (e.g. '%]') */
        } while (*p != ']');
        return p + 1;
    default:
        return p;
    }
}

static int match_class(int c, int cl) {
    int res;
    switch (tolower(cl)) {
    case 'a': res = isalpha(c); break;
    case 'c': res = iscntrl(c); break;
    case 'd': res = isdigit(c); break;
    case 'l': res = islower(c); break;
    case 'p': res = ispunct(c); break;
    case 's': res = isspace(c); break;
    case 'u': res = isupper(c); break;
    case 'w': res = isalnum(c); break;
    case 'x': res = isxdigit(c); break;
    case 'z': res = (c == 0); break;
    default: return (cl == c);
    }
    return (islower(cl) ? res : !res);
}

static int matchbracketclass(int c, const char *p, const char *ec) {
    int sig = 1;
    if (*(p + 1) == '^') {
        sig = 0;
        p++; /* skip the '^' */
    }
    while (++p < ec) {
        if (*p == L_ESC) {
            p++;
            if (match_class(c, uchar(*p))) return sig;
        } else if ((*(p + 1) == '-') && (p + 2 < ec)) {
            p += 2;
            if (uchar(*(p - 2)) <= c && c <= uchar(*p)) return sig;
        } else if (uchar(*p) == c) {
            return sig;
        }
    }
    return !sig;
}

static int singlematch(int c, const char *p, const char *ep) {
    switch (*p) {
    case '.': return 1; /* matches any char */
    case L_ESC: return match_class(c, uchar(*(p + 1)));
    case '[': return matchbracketclass(c, p, ep - 1);
    default: return (uchar(*p) == c);
    }
}

static const char *match(MatchState *ms, const char *s, const char *p);

static const char *matchbalance(MatchState *ms, const char *s, const char *p) {
    if (*p == 0 || *(p + 1) == 0) luaL_error(ms->L, "unbalanced pattern");
    if (s >= ms->src_end || *s != *p) return NULL;
    {
        int b = *p;
        int e = *(p + 1);
        int cont = 1;
        while (++s < ms->src_end) {
            if (*s == e) {
                if (--cont == 0) return s + 1;
            } else if (*s == b) {
                cont++;
            }
        }
    }
    return NULL; /* string ends out of balance */
}

static const char *max_expand(MatchState *ms, const char *s, const char *p, const char *ep) {
    ptrdiff_t i = 0; /* counts maximum expand for item */
    while ((s + i) < ms->src_end && singlematch(uchar(*(s + i)), p, ep)) i++;
    /* keeps trying to match with the maximum repetitions */
    while (i >= 0) {
        const char *res = match(ms, (s + i), ep + 1);
        if (res) return res;
        i--; /* else didn't match; reduce 1 repetition to try again */
    }
    return NULL;
}

static const char *min_expand(MatchState *ms, const char *s, const char *p, const char *ep) {
    for (;;) {
        const char *res = match(ms, s, ep + 1);
        if (res != NULL)
            return res;
        else if (s < ms->src_end && singlematch(uchar(*s), p, ep))
            s++; /* try with one more repetition */
        else
            return NULL;
    }
}

static const char *start_capture(MatchState *ms, const char *s, const char *p, int what) {
    const char *res;
    int level = ms->level;
    if (level >= LUA_MAXCAPTURES) luaL_error(ms->L, "too many captures");
    ms->capture[level].init = s;
    ms->capture[level].len = what;
    ms->level = level + 1;
    if ((res = match(ms, s, p)) == NULL) /* match failed? */
        ms->level--;                     /* undo capture */
    return res;
}

static const char *end_capture(MatchState *ms, const char *s, const char *p) {
    int l = capture_to_close(ms);
    const char *res;
    ms->capture[l].len = s - ms->capture[l].init; /* close capture */
    if ((res = match(ms, s, p)) == NULL)          /* match failed? */
        ms->capture[l].len = CAP_UNFINISHED;      /* undo capture */
    return res;
}

static const char *match_capture(MatchState *ms, const char *s, int l) {
    size_t len;
    l = check_capture(ms, l);
    len = ms->capture[l].len;
    if ((size_t)(ms->src_end - s) >= len && memcmp(ms->capture[l].init, s, len) == 0)
        return s + len;
    else
        return NULL;
}

/* The matcher of Lua 5.1.5, unchanged except that recursion goes through `match` below. */
static const char *do_match(MatchState *ms, const char *s, const char *p) {
init: /* using goto's to optimize tail recursion */
    switch (*p) {
    case '(': /* start capture */
        if (*(p + 1) == ')') /* position capture? */
            return start_capture(ms, s, p + 2, CAP_POSITION);
        else
            return start_capture(ms, s, p + 1, CAP_UNFINISHED);
    case ')': /* end capture */
        return end_capture(ms, s, p + 1);
    case L_ESC:
        switch (*(p + 1)) {
        case 'b': /* balanced string? */
            s = matchbalance(ms, s, p + 2);
            if (s == NULL) return NULL;
            p += 4;
            goto init; /* else return match(ms, s, p+4); */
        case 'f': {    /* frontier? */
            const char *ep;
            char previous;
            p += 2;
            if (*p != '[') luaL_error(ms->L, "missing " LUA_QL("[") " after " LUA_QL("%%f") " in pattern");
            ep = classend(ms, p); /* points to what is next */
            previous = (s == ms->src_init) ? '\0' : *(s - 1);
            if (matchbracketclass(uchar(previous), p, ep - 1) || !matchbracketclass(uchar(*s), p, ep - 1))
                return NULL;
            p = ep;
            goto init; /* else return match(ms, s, ep); */
        }
        default:
            if (isdigit(uchar(*(p + 1)))) { /* capture results (%0-%9)? */
                s = match_capture(ms, s, uchar(*(p + 1)));
                if (s == NULL) return NULL;
                p += 2;
                goto init; /* else return match(ms, s, p+2) */
            }
            goto dflt; /* case default */
        }
    case '\0': /* end of pattern */
        return s;  /* match succeeded */
    case '$':
        if (*(p + 1) == '\0')                    /* is the '$' the last char in pattern? */
            return (s == ms->src_end) ? s : NULL; /* check end of string */
        else
            goto dflt;
    default:
    dflt: { /* it is a pattern item */
        const char *ep = classend(ms, p); /* points to what is next */
        int m = s < ms->src_end && singlematch(uchar(*s), p, ep);
        switch (*ep) {
        case '?': { /* optional */
            const char *res;
            if (m && ((res = match(ms, s + 1, ep + 1)) != NULL)) return res;
            p = ep + 1;
            goto init; /* else return match(ms, s, ep+1); */
        }
        case '*': /* 0 or more repetitions */
            return max_expand(ms, s, p, ep);
        case '+': /* 1 or more repetitions */
            return (m ? max_expand(ms, s + 1, p, ep) : NULL);
        case '-': /* 0 or more repetitions (minimum) */
            return min_expand(ms, s, p, ep);
        default:
            if (!m) return NULL;
            s++;
            p = ep;
            goto init; /* else return match(ms, s+1, ep); */
        }
    }
    }
}

/* Every recursion and every new match attempt passes here: bounded depth, and the script's budget is checked. */
static const char *match(MatchState *ms, const char *s, const char *p) {
    const char *result;
    if (ms->depth-- == 0) luaL_error(ms->L, "pattern too complex");
    if (++ms->steps >= DESKSET_MATCH_CHECK_INTERVAL) {
        deskset_lua_check_budget(ms->L, ms->steps);
        ms->steps = 0;
    }
    result = do_match(ms, s, p);
    ms->depth++;
    return result;
}

static const char *lmemfind(const char *s1, size_t l1, const char *s2, size_t l2) {
    if (l2 == 0) return s1; /* empty strings are everywhere */
    else if (l2 > l1) return NULL; /* avoids a negative 'l1' */
    else {
        const char *init; /* to search for a '*s2' inside 's1' */
        l2--;             /* 1st char will be checked by 'memchr' */
        l1 = l1 - l2;     /* 's2' cannot be found after that */
        while (l1 > 0 && (init = (const char *)memchr(s1, *s2, l1)) != NULL) {
            init++; /* 1st char is already checked */
            if (memcmp(init, s2 + 1, l2) == 0)
                return init - 1;
            else { /* correct 'l1' and 's1' to try again */
                l1 -= init - s1;
                s1 = init;
            }
        }
        return NULL; /* not found */
    }
}

static void push_onecapture(MatchState *ms, int i, const char *s, const char *e) {
    if (i >= ms->level) {
        if (i == 0) /* ms->level == 0, too */
            lua_pushlstring(ms->L, s, e - s); /* add whole match */
        else
            luaL_error(ms->L, "invalid capture index");
    } else {
        ptrdiff_t l = ms->capture[i].len;
        if (l == CAP_UNFINISHED) luaL_error(ms->L, "unfinished capture");
        if (l == CAP_POSITION)
            lua_pushinteger(ms->L, ms->capture[i].init - ms->src_init + 1);
        else
            lua_pushlstring(ms->L, ms->capture[i].init, l);
    }
}

static int push_captures(MatchState *ms, const char *s, const char *e) {
    int i;
    int nlevels = (ms->level == 0 && s) ? 1 : ms->level;
    luaL_checkstack(ms->L, nlevels, "too many captures");
    for (i = 0; i < nlevels; i++) push_onecapture(ms, i, s, e);
    return nlevels; /* number of strings pushed */
}

static int str_find_aux(lua_State *L, int find) {
    size_t l1, l2;
    const char *s = luaL_checklstring(L, 1, &l1);
    const char *p = luaL_checklstring(L, 2, &l2);
    ptrdiff_t init = posrelat(luaL_optinteger(L, 3, 1), l1) - 1;
    if (init < 0)
        init = 0;
    else if ((size_t)(init) > l1)
        init = (ptrdiff_t)l1;
    if (find && (lua_toboolean(L, 4) ||             /* explicit request? */
                 strpbrk(p, SPECIALS) == NULL)) {   /* or no special characters? */
        /* do a plain search */
        const char *s2 = lmemfind(s + init, l1 - init, p, l2);
        if (s2) {
            lua_pushinteger(L, s2 - s + 1);
            lua_pushinteger(L, s2 - s + l2);
            return 2;
        }
    } else {
        MatchState ms;
        int anchor = (*p == '^') ? (p++, 1) : 0;
        const char *s1 = s + init;
        prepare_state(&ms, L, s, l1);
        do {
            const char *res;
            ms.level = 0;
            if ((res = match(&ms, s1, p)) != NULL) {
                if (find) {
                    lua_pushinteger(L, s1 - s + 1); /* start */
                    lua_pushinteger(L, res - s);    /* end */
                    return push_captures(&ms, NULL, 0) + 2;
                } else {
                    return push_captures(&ms, s1, res);
                }
            }
        } while (s1++ < ms.src_end && !anchor);
    }
    lua_pushnil(L); /* not found */
    return 1;
}

static int str_find(lua_State *L) { return str_find_aux(L, 1); }

static int str_match(lua_State *L) { return str_find_aux(L, 0); }

static int gmatch_aux(lua_State *L) {
    MatchState ms;
    size_t ls;
    const char *s = lua_tolstring(L, lua_upvalueindex(1), &ls);
    const char *p = lua_tostring(L, lua_upvalueindex(2));
    const char *src;
    if (s == NULL || p == NULL) return 0; /* defensive: the upvalues are always strings */
    prepare_state(&ms, L, s, ls);
    for (src = s + (size_t)lua_tointeger(L, lua_upvalueindex(3)); src <= ms.src_end; src++) {
        const char *e;
        ms.level = 0;
        if ((e = match(&ms, src, p)) != NULL) {
            lua_Integer newstart = e - s;
            if (e == src) newstart++; /* empty match? go at least one position */
            lua_pushinteger(L, newstart);
            lua_replace(L, lua_upvalueindex(3));
            return push_captures(&ms, src, e);
        }
    }
    return 0; /* not found */
}

static int gmatch(lua_State *L) {
    luaL_checkstring(L, 1);
    luaL_checkstring(L, 2);
    lua_settop(L, 2);
    lua_pushinteger(L, 0);
    lua_pushcclosure(L, gmatch_aux, 3);
    return 1;
}

static void add_s(MatchState *ms, luaL_Buffer *b, const char *s, const char *e) {
    size_t l, i;
    const char *news = lua_tolstring(ms->L, 3, &l);
    for (i = 0; i < l; i++) {
        if (news[i] != L_ESC)
            luaL_addchar(b, news[i]);
        else {
            i++; /* skip ESC */
            if (!isdigit(uchar(news[i])))
                luaL_addchar(b, news[i]);
            else if (news[i] == '0')
                luaL_addlstring(b, s, e - s);
            else {
                push_onecapture(ms, news[i] - '1', s, e);
                luaL_addvalue(b); /* add capture to accumulated result */
            }
        }
    }
}

static void add_value(MatchState *ms, luaL_Buffer *b, const char *s, const char *e) {
    lua_State *L = ms->L;
    switch (lua_type(L, 3)) {
    case LUA_TNUMBER:
    case LUA_TSTRING:
        add_s(ms, b, s, e);
        return;
    case LUA_TFUNCTION: {
        int n;
        lua_pushvalue(L, 3);
        n = push_captures(ms, s, e);
        lua_call(L, n, 1);
        break;
    }
    case LUA_TTABLE:
        push_onecapture(ms, 0, s, e);
        lua_gettable(L, 3);
        break;
    }
    if (!lua_toboolean(L, -1)) { /* nil or false? */
        lua_pop(L, 1);
        lua_pushlstring(L, s, e - s); /* keep original text */
    } else if (!lua_isstring(L, -1)) {
        luaL_error(L, "invalid replacement value (a %s)", luaL_typename(L, -1));
    }
    luaL_addvalue(b); /* add result to accumulator */
}

static int str_gsub(lua_State *L) {
    size_t srcl;
    const char *src = luaL_checklstring(L, 1, &srcl);
    const char *p = luaL_checkstring(L, 2);
    int tr = lua_type(L, 3);
    int max_s = luaL_optint(L, 4, srcl + 1);
    int anchor = (*p == '^') ? (p++, 1) : 0;
    int n = 0;
    MatchState ms;
    luaL_Buffer b;
    luaL_argcheck(L, tr == LUA_TNUMBER || tr == LUA_TSTRING || tr == LUA_TFUNCTION || tr == LUA_TTABLE, 3,
                  "string/function/table expected");
    luaL_buffinit(L, &b);
    prepare_state(&ms, L, src, srcl);
    while (n < max_s) {
        const char *e;
        ms.level = 0;
        e = match(&ms, src, p);
        if (e) {
            n++;
            add_value(&ms, &b, src, e);
        }
        if (e && e > src) /* non empty match? */
            src = e;      /* skip it */
        else if (src < ms.src_end)
            luaL_addchar(&b, *src++);
        else
            break;
        if (anchor) break;
    }
    luaL_addlstring(&b, src, ms.src_end - src);
    luaL_pushresult(&b);
    lua_pushinteger(L, n); /* number of substitutions */
    return 2;
}

void deskset_lua_install_patterns(lua_State *L) {
    static const luaL_Reg functions[] = {
        {"find", str_find}, {"match", str_match}, {"gmatch", gmatch}, {"gsub", str_gsub}, {NULL, NULL}};
    const luaL_Reg *f;
    lua_getglobal(L, LUA_STRLIBNAME);
    if (lua_istable(L, -1)) {
        for (f = functions; f->name; f++) {
            lua_pushcfunction(L, f->func);
            lua_setfield(L, -2, f->name);
        }
        /* LUA_COMPAT_GFIND: the deprecated alias of gmatch. */
        lua_getfield(L, -1, "gfind");
        if (!lua_isnil(L, -1)) {
            lua_pushcfunction(L, gmatch);
            lua_setfield(L, -3, "gfind");
        }
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}
