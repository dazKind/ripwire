#!/usr/bin/env bash
# haxecheck.sh — the Haxe ingest coverage gate (grammar + tags.scm + the Haxe-only extraction seams).
#
# Modeled on luacheck.sh / phpcheck.sh: a small fixture, assertions pinned to what the binary ACTUALLY
# does (every number below was read off a real run before it was written down), plus mutation arms so the
# edge and metric assertions are non-tautological.
#
# ── WHY THIS GATE IS NOT VACUOUS ──────────────────────────────────────────────────────────────────────
# Against a binary built from 93c8eda — the commit this lane branched from, which has no Haxe grammar at
# all — every .hx file leaves the index as `why="unsupported-ext"`, so the map reports `files=0 symbols=0`
# and every arm fails. That is the trivial red and it is NOT what this gate is for. tong/tree-sitter-haxe
# names its nodes after the Haxe compiler's AST (ClassType, ClassMethod, ECall, ENew, EField, TypePath,
# EIf/EFor/EWhile/ESwitch/ETry), which shares NOTHING with the C-family/JS spellings the shared extraction
# code already knows. So every seam this port had to open is pinned here by exact value:
#   §1  the tags query: class vs interface off ONE node kind's `kind:` field, abstract/enum/typedef buckets,
#       module-level + named-local functions, enum constructors, the SCREAMING gate on fields
#   §2  captureBases with NO clause node: `extends`/`implements` are FIELD children of the class, and an
#       abstract's `from`/`to` TypePath (a cast) must NOT become a base
#   §3  captureIncludes: `import`/`using` are bare-word node kinds, `#if` is an import container, ` as X`
#       aliases are cut
#   §4  the metrics walk: EIf/EFor/EWhile (do-while included)/switch_case/ETernary/`&&`+`||` via the `op:`
#       field, and a `catch` that is not a node but a `body:` field of ETry — plus `params=` off the `args:`
#       field children. §7 mutates each independently and shows the number move.
#
# ── FIXTURE (test/haxefix/src/demo/) ─────────────────────────────────────────────────────────────────
#   IGreet.hx     interface IGreet { function greet():String; }        -- body-less method decl
#   Base.hx       class Base { static inline var MAX_RETRIES; var count; new(); tag() }
#   Greeter.hx    import demo.util.Fmt; using StringTools;
#                 class Greeter extends Base implements IGreet          -- CROSS-FILE extends + implements
#                   greet() -> new Fmt(), f.pad(), Fmt.shout(), tag(), name.trim()   (trim = static extension)
#   util/Fmt.hx   class Fmt { new(); pad(); static shout() }
#   Shape.hx      enum Shape { Dot; Circle(r) }  typedef Point  abstract Meters(Float) from Float to Float
#                 enum abstract Level(Int) { var Low; var High; }
#   Main.hx       import demo.Shape; import demo.util.Fmt as F; #if sys import sys.io.File; #end
#                 final GREETING_PREFIX                                   -- module-level constant
#                 function area(s:Shape)                                 -- module-level function, 2 case arms
#                 class Main { main(); flow(xs) [for/if+&&+||/else if/while/do-while/2 cases/2 catches/?:/
#                              named local inner()]; risky() }
#
# ── FINDINGS from running `ripwire test/haxefix` and reading the raw output ───────────────────────────
#   - 6 files / 28 symbols / edges=15 / ambiguous=0 / unresolved=0, clean stderr (no ABI/degrade line).
#   - KIND MAPPING: class -> cls, interface -> iface, abstract + enum abstract -> cls (containers of
#     methods/vars), enum + typedef -> the definition.type bucket (t="struct", as Java/C# enums land),
#     ClassMethod -> method (the constructor is literally the method named `new` — four of them here),
#     named EFunction -> fn (module-level `area` AND the named local `inner`), EnumConstructor -> var.
#   - The SCREAMING gate: `MAX_RETRIES` and `GREETING_PREFIX` are t="var"; `count`, the `name` property and
#     the enum-abstract values `Low`/`High` are NOT indexed (constCaptureNeedsScreamingGate knows Haxe).
#   - `var shout = function(s) …` in main() is an anonymous EFunction (no `name:` field) -> NOT a def; the
#     only `shout` def is Fmt's static method. Asserted, so a future "capture anonymous functions" cannot
#     silently mint a local as a symbol.
#   - EDGES: greet -> tag (an INHERITED method, cross-file), greet -> Fmt (`new Fmt()` resolves to the class),
#     greet -> pad, greet -> shout (`Fmt.shout()` static), main -> Greeter/area/flow/Circle/Meters/greet/
#     toFloat/shout, area -> Circle (a `case Circle(r)` pattern parses as an ECall — a real use of the ctor).
#   - `name.trim()` (a static extension via `using StringTools`) is captured as a `trim` call, resolves to
#     nothing in-corpus and drops — unresolved=0 rather than an invented edge. The receiver rewrite is the
#     typer's, not the text's: disclosed in queries/haxe/tags.scm, asserted in §3 as an import record only.
#   - cx(flow) = 13: 1 + for + if + `&&` + `||` + else-if + while + do-while + 2 case arms + 2 catches + `?:`.
#     ccx(flow) = 14, nest = 2. cx(area) = 3 (two arms), cx(risky) = 2. NO ev= (evCountedLang excludes Haxe).
#   - params(flow) = 1 — off the `args:` FunctionArg children; every Haxe def read params="0" until
#     countParams learned that shape (a confident wrong zero, the one direction the honesty rule forbids).
#   - --deps: files="2" (Greeter.hx, Main.hx carry directives), dep_files="6" (every .hx is a node);
#     `<inc t="sys.io.File"/>` proves the `conditional` container, `<inc t="demo.util.Fmt"/>` twice proves
#     the ` as F` alias cut.
#
# Usage:
#   bash test/haxecheck.sh
#   RIPWIRE_BIN=build/ripwire bash test/haxecheck.sh
#   RIPWIRE_BIN=asan/ripwire  bash test/haxecheck.sh
#
# Exits non-zero on any failure; prints PASS/FAIL per check and ALL PASS on success.

set -u
ROOT="$( cd "$( dirname "$0" )/.." && pwd )"
BIN="${1:-${RIPWIRE_BIN:-$ROOT/build/ripwire}}"
[ "${BIN#/}" = "$BIN" ] && BIN="$ROOT/$BIN"          # allow a repo-relative RIPWIRE_BIN
FIX="$ROOT/test/haxefix"
TMP="$( mktemp -d )"; trap 'rm -rf "$TMP"' EXIT
fail=0

ok(){ printf '  PASS  %s\n' "$*"; }
no(){ printf '  FAIL  %s\n' "$*"; fail=1; }
cxof(){ "$1" "$2" --metrics --no-cache 2>/dev/null | grep -o "n=\"$3\"[^>]* cx=\"[0-9]*\"" | grep -o ' cx="[0-9]*"' | tr -d ' '; }

[ -x "$BIN" ] || { echo "no ripwire binary at $BIN — build first (cmake --build build -j)"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required for XML assertions"; exit 2; }
[ -d "$FIX" ] || { echo "no fixture at $FIX"; exit 2; }

echo "haxecheck: BIN=$BIN  FIX=$FIX"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 0. PRESENCE: the fixture really spells every shape the arms below assert ==="
# ═══════════════════════════════════════════════════════════════════════════
# A gate whose probe target can vanish passes for the wrong reason (CONTRIBUTING.md §2). These greps are
# the guard: if a fixture edit deletes a shape, THIS arm reds instead of the assertion going inert.
D="src/demo"
presence(){ grep -qF -- "$2" "$FIX/$1" && ok "fixture $1 spells: $3" || no "fixture $1 no longer spells: $3"; }
presence $D/Greeter.hx  'class Greeter extends Base implements IGreet' 'extends + implements on one class (FIELD children, no clause node)'
presence $D/IGreet.hx   'interface IGreet'                 'an interface (ClassType kind: "interface")'
presence $D/Shape.hx    'abstract Meters(Float) from Float to Float' 'an abstract with from/to casts (must NOT be bases)'
presence $D/Shape.hx    'enum abstract Level(Int)'         'an enum abstract with non-SCREAMING values'
presence $D/Shape.hx    'Circle(r:Float);'                 'an enum constructor with arguments'
presence $D/Shape.hx    'typedef Point ='                  'a typedef'
presence $D/Base.hx     'public static inline var MAX_RETRIES' 'a SCREAMING class constant'
presence $D/Base.hx     'var count:Int = 0;'               'a non-SCREAMING field (must NOT be indexed)'
presence $D/Main.hx     'final GREETING_PREFIX'            'a module-level SCREAMING constant'
presence $D/Main.hx     'function area(s:Shape):Float'     'a module-level function'
presence $D/Main.hx     'function inner(k:Int):Int'        'a NAMED local function'
presence $D/Main.hx     'var shout = function(s:String)'   'an ANONYMOUS function value (must NOT be a def)'
presence $D/Main.hx     'import demo.util.Fmt as F;'       'an aliased import (the alias must be cut)'
presence $D/Main.hx     '#if sys'                          'a #if-guarded import (the conditional container)'
presence $D/Greeter.hx  'using StringTools;'               'a static-extension `using` directive'
presence $D/Greeter.hx  'name.trim()'                      'a static-extension call site'
presence $D/Main.hx     'if (x > 1 && x < 9 || x == 0)'    'a boolean run with && and ||'
presence $D/Main.hx     '} else if (x < 0) {'              'an else-if arm'
presence $D/Main.hx     '} while (t < 3);'                 'a do … while loop'
presence $D/Main.hx     'case 2 | 3:'                      'a second case arm'
presence $D/Main.hx     '} catch (e:Dynamic) {'            'a second catch clause'
presence $D/Main.hx     'var q = t > 0 ? 1 : 0;'           'a ternary'

MAP_OUT="$TMP/map.xml"
"$BIN" "$FIX" --no-cache >"$MAP_OUT" 2>"$TMP/map.err"
MAP_EXIT=$?
[ "$MAP_EXIT" -eq 0 ] && ok "default map: exits 0 on the Haxe fixture" || no "default map: exited $MAP_EXIT: $( cat "$TMP/map.err" )"
command -v xmllint >/dev/null 2>&1 && { xmllint --noout "$MAP_OUT" && ok "default map: passes xmllint --noout" || no "default map: xmllint failed"; }
[ -s "$TMP/map.err" ] && no "default map: unexpected stderr (ABI/degrade?): $( cat "$TMP/map.err" )" || ok "default map: clean stderr (no ABI mismatch / degrade)"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 1. STRUCTURE: every declaration bucket, 28 symbols across 6 files ==="
# ═══════════════════════════════════════════════════════════════════════════

grep -q 'files=6 symbols=28' "$MAP_OUT" && ok "header: files=6 symbols=28" || no "header: expected files=6 symbols=28: $( grep -o 'files=[0-9]* symbols=[0-9]*' "$MAP_OUT" )"
grep -q 'edges=15' "$MAP_OUT" && ok "header: edges=15" || no "header: expected edges=15: $( grep -o 'edges=[0-9]*' "$MAP_OUT" )"
grep -q 'ambiguous=0' "$MAP_OUT" && ok "header: ambiguous=0" || no "header: expected ambiguous=0: $( grep -o 'ambiguous=[0-9]*' "$MAP_OUT" )"
grep -q 'unresolved=0' "$MAP_OUT" && ok "header: unresolved=0" || no "header: expected unresolved=0: $( grep -o 'unresolved=[0-9]*' "$MAP_OUT" )"

python3 - "$MAP_OUT" <<'PYEOF' >"$TMP/parsed.json"
import sys, re, json
xml = open(sys.argv[1], encoding='utf-8').read()
files = re.findall(r'<f p="([^"]+)"[^>]*>(.*?)</f>', xml, re.S)
out = {}
for path, body in files:
    name = path.split('/')[-1]
    syms = []
    for sm in re.finditer(r'<s t="(\w+)" n="([^"]*)"[^>]*>(.*?)</s>|<s t="(\w+)" n="([^"]*)"[^>]*/>', body, re.S):
        if sm.group(1) is not None:
            t, n, inner = sm.group(1), sm.group(2), sm.group(3)
        else:
            t, n, inner = sm.group(4), sm.group(5), ""
        syms.append({"t": t, "n": n, "calls": re.findall(r'<c n="([^"]*)"', inner)})
    out[name] = syms
print(json.dumps(out))
PYEOF

python3 - "$TMP/parsed.json" <<'PYEOF' >"$TMP/struct_check"
import json, sys
d = json.load(open(sys.argv[1]))
def has(f, n, t):     return any(s["n"] == n and s["t"] == t for s in d.get(f, []))
def count(f, n):      return sum(1 for s in d.get(f, []) if s["n"] == n)
def total(n):         return sum(count(f, n) for f in d)
def edge(f, frm, to): return any(s["n"] == frm and to in s["calls"] for s in d.get(f, []))
print("K_CLASS:%s"      % has("Greeter.hx", "Greeter", "cls"))
print("K_IFACE:%s"      % has("IGreet.hx", "IGreet", "iface"))
print("K_ABSTRACT:%s"   % has("Shape.hx", "Meters", "cls"))
print("K_ENUMABS:%s"    % has("Shape.hx", "Level", "cls"))
print("K_ENUM:%s"       % has("Shape.hx", "Shape", "struct"))
print("K_TYPEDEF:%s"    % has("Shape.hx", "Point", "struct"))
print("K_ENUMCTOR:%s"   % (has("Shape.hx", "Circle", "var") and has("Shape.hx", "Dot", "var")))
print("K_METHOD:%s"     % has("Greeter.hx", "greet", "method"))
print("K_IFACEDECL:%s"  % has("IGreet.hx", "greet", "method"))
print("K_CTOR4:%s"      % (total("new") == 4))
print("K_MODFN:%s"      % has("Main.hx", "area", "fn"))
print("K_LOCALFN:%s"    % has("Main.hx", "inner", "fn"))
print("K_CONST:%s"      % has("Base.hx", "MAX_RETRIES", "var"))
print("K_MODCONST:%s"   % has("Main.hx", "GREETING_PREFIX", "var"))
print("N_FIELD:%s"      % (total("count") == 0))
print("N_PROP:%s"       % (total("name") == 0))
print("N_ENUMABSVAL:%s" % (total("Low") == 0 and total("High") == 0))
print("N_ANONFN:%s"     % (total("shout") == 1 and has("Fmt.hx", "shout", "method")))
print("E_INHERITED:%s"  % edge("Greeter.hx", "greet", "tag"))
print("E_NEW:%s"        % edge("Greeter.hx", "greet", "Fmt"))
print("E_METHOD:%s"     % edge("Greeter.hx", "greet", "pad"))
print("E_STATIC:%s"     % edge("Greeter.hx", "greet", "shout"))
print("E_NEWMAIN:%s"    % edge("Main.hx", "main", "Greeter"))
print("E_MODFN:%s"      % edge("Main.hx", "main", "area"))
print("E_ENUMCTOR:%s"   % (edge("Main.hx", "main", "Circle") and edge("Main.hx", "area", "Circle")))
print("E_LOCALFN:%s"    % edge("Main.hx", "flow", "inner"))
PYEOF
cat "$TMP/struct_check"

arm(){ grep -q "^$1:True" "$TMP/struct_check" && ok "$2" || no "$2 — MISSING"; }
arm K_CLASS      'kind: `class Greeter` -> t="cls" (ClassType kind: "class")'
arm K_IFACE      'kind: `interface IGreet` -> t="iface" (the SAME node kind, told apart by its kind: field)'
arm K_ABSTRACT   'kind: `abstract Meters(Float)` -> t="cls" (a container of methods, class-like)'
arm K_ENUMABS    'kind: `enum abstract Level(Int)` -> t="cls"'
arm K_ENUM       'kind: `enum Shape` -> t="struct" (the definition.type bucket, as Java/C# enums land)'
arm K_TYPEDEF    'kind: `typedef Point` -> t="struct" (definition.type)'
arm K_ENUMCTOR   'kind: enum constructors `Dot` / `Circle(r)` -> t="var"'
arm K_METHOD     'kind: `function greet()` -> t="method"'
arm K_IFACEDECL  'kind: the interface'"'"'s body-less `function greet():String;` is still a method row'
arm K_CTOR4      'kind: exactly FOUR `new` methods (Base, Greeter, Fmt, Meters) — the constructor is the method named new'
arm K_MODFN      'kind: module-level `function area()` -> t="fn" (Haxe 4.2 module fields)'
arm K_LOCALFN    'kind: the NAMED local `function inner()` -> t="fn"'
arm K_CONST      'const: `public static inline var MAX_RETRIES` -> t="var" (SCREAMING passes the gate)'
arm K_MODCONST   'const: module-level `final GREETING_PREFIX` -> t="var"'
arm N_FIELD      'negative: `var count` is NOT indexed (the SCREAMING gate knows Haxe)'
arm N_PROP       'negative: the `name(default, null)` property is NOT indexed'
arm N_ENUMABSVAL 'negative: enum-abstract values `Low`/`High` are NOT indexed (disclosed floor)'
arm N_ANONFN     'negative: `var shout = function(...)` mints NO def — the only shout is Fmt'"'"'s method'
arm E_INHERITED  'edge: greet -> tag (an INHERITED method, defined in Base.hx, CROSS-FILE)'
arm E_NEW        'edge: greet -> Fmt (`new Fmt()` resolves to the class)'
arm E_METHOD     'edge: greet -> pad (`f.pad(name)`, an EField callee)'
arm E_STATIC     'edge: greet -> shout (`Fmt.shout(name)`, a static call through the type name)'
arm E_NEWMAIN    'edge: main -> Greeter (`new Greeter("x")`)'
arm E_MODFN      'edge: main -> area (a call to a module-level function)'
arm E_ENUMCTOR   'edge: main -> Circle AND area -> Circle (construction and a `case Circle(r)` pattern)'
arm E_LOCALFN    'edge: flow -> inner (a call to the named local function)'

CR="$( "$BIN" "$FIX" --callers=shout --no-cache 2>/dev/null )"
echo "$CR" | grep -q 'n="greet"' && echo "$CR" | grep -q 'n="main"' && ok "--callers=shout lists greet AND main (the anonymous function's call attributes to its enclosing method)" \
    || no "--callers=shout did not list greet + main: $( echo "$CR" | grep -o 'n="[^"]*"' | tr '\n' ' ' )"
CR="$( "$BIN" "$FIX" --callers=Fmt --no-cache 2>/dev/null )"
echo "$CR" | grep -q 'n="greet"' && ok "--callers=Fmt lists greet (who constructs Fmt)" || no "--callers=Fmt did not list greet: $CR"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 2. INHERITANCE: extends + implements are FIELD children; an abstract's from/to are NOT bases ==="
# ═══════════════════════════════════════════════════════════════════════════
USES_B="$( "$BIN" "$FIX" --uses=Base --no-cache 2>/dev/null )"
echo "$USES_B" | grep -q '<u role="extends" p="src/demo/Greeter.hx:6" in_id="Greeter"/>' \
    && ok '--uses=Base: role="extends" at Greeter.hx:6 inside Greeter (the `extends` FIELD TypePath)' \
    || no "--uses=Base: expected an extends use-site from Greeter: $( echo "$USES_B" | grep -o '<u [^>]*/>' | tr '\n' ' ' )"
USES_I="$( "$BIN" "$FIX" --uses=IGreet --no-cache 2>/dev/null )"
echo "$USES_I" | grep -q '<u role="extends" p="src/demo/Greeter.hx:6" in_id="Greeter"/>' \
    && ok '--uses=IGreet: role="extends" at Greeter.hx:6 (the `implements` FIELD TypePath — same overlay)' \
    || no "--uses=IGreet: expected an extends use-site from Greeter: $( echo "$USES_I" | grep -o '<u [^>]*/>' | tr '\n' ' ' )"
LEGO="$( "$BIN" "$FIX" --lego=IGreet --no-cache 2>/dev/null )"
echo "$LEGO" | grep -q '<impl n="Greeter" p="src/demo/Greeter.hx"/>' && ok '--lego=IGreet lists Greeter as the implementor' \
    || no "--lego=IGreet did not list Greeter: $( echo "$LEGO" | grep -o '<impl [^>]*/>' | tr '\n' ' ' )"
LEGO="$( "$BIN" "$FIX" --lego=Base --no-cache 2>/dev/null )"
echo "$LEGO" | grep -q '<impl n="Greeter" p="src/demo/Greeter.hx"/>' && ok '--lego=Base lists Greeter as the subclass' \
    || no "--lego=Base did not list Greeter: $( echo "$LEGO" | grep -o '<impl [^>]*/>' | tr '\n' ' ' )"
# `abstract Meters(Float) from Float to Float` — the from/to TypePaths carry the SAME node kind as the
# inheritance fields and are implicit CASTS. A base edge here would be an invented edge.
USES_F="$( "$BIN" "$FIX" --uses=Float --no-cache 2>&1 )"
echo "$USES_F" | grep -q '<u role="extends"' \
    && no 'an extends use-site appeared for Float — an abstract'"'"'s from/to cast was read as a base clause' \
    || ok 'no role="extends" use-site for Float (an abstract'"'"'s from/to TypePaths are casts, not bases)'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 3. IMPORTS: import/using are Include records, #if is a container, aliases are cut ==="
# ═══════════════════════════════════════════════════════════════════════════
DEPS="$( "$BIN" "$FIX" --deps --no-cache 2>/dev/null )"
echo "$DEPS" | grep -q '<deps files="2"' && ok '--deps: files="2" (Greeter.hx and Main.hx carry directives)' \
    || no "--deps: expected files=2: $( echo "$DEPS" | grep -o '<deps [^>]*>' )"
echo "$DEPS" | grep -q 'dep_files="6"' && ok '--deps health: dep_files="6" — every .hx is dependency-capable' \
    || no "--deps health: expected dep_files=6: $( echo "$DEPS" | grep -o '<health [^/]*/>' )"
echo "$DEPS" | grep -q '<inc t="sys.io.File"/>' && ok '--deps: `#if sys import sys.io.File; #end` captured (conditional is an import container)' \
    || no "--deps: the #if-guarded import is missing: $( echo "$DEPS" | grep -o '<inc [^/]*/>' | tr '\n' ' ' )"
[ "$( echo "$DEPS" | grep -o '<inc t="demo.util.Fmt"/>' | wc -l | tr -d ' ' )" = 2 ] && ok '--deps: `import demo.util.Fmt as F` records demo.util.Fmt (alias cut) — two files, two records' \
    || no "--deps: expected 2 x demo.util.Fmt: $( echo "$DEPS" | grep -o '<inc [^/]*/>' | tr '\n' ' ' )"
echo "$DEPS" | grep -q '<inc t="StringTools"/>' && ok '--deps: `using StringTools` is an Include record' \
    || no "--deps: the using directive is missing"
USES_S="$( "$BIN" "$FIX" --uses=StringTools --no-cache 2>/dev/null )"
echo "$USES_S" | grep -q '<u role="import" p="src/demo/Greeter.hx:4"/>' && ok '--uses=StringTools: role="import" at Greeter.hx:4 — a static extension is an import, never a receiver hint' \
    || no "--uses=StringTools: expected an import use-site: $( echo "$USES_S" | grep -o '<u [^>]*/>' | tr '\n' ' ' )"
# the disclosed floor: `name.trim()` is captured as a `trim` call, resolves to nothing in-corpus and drops
USES_T="$( "$BIN" "$FIX" --uses=trim --no-cache 2>/dev/null )"
echo "$USES_T" | grep -q 'defs="0" external="1"' && echo "$USES_T" | grep -q '<u role="call" p="src/demo/Greeter.hx:16"' \
    && ok '--uses=trim: defs="0" external="1", one call site — the static-extension floor is stated, not silent' \
    || no "--uses=trim: expected defs=0 external=1 + a call site: $( echo "$USES_T" | grep -o '<uses [^>]*>\|<u [^>]*/>' | tr '\n' ' ' )"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 4. CENSUS: --skipped no longer drops Haxe, and names it ==="
# ═══════════════════════════════════════════════════════════════════════════
SK="$( "$BIN" "$FIX" --skipped --no-cache 2>/dev/null )"
echo "$SK" | grep -q 'unsupported_ext="0"' && ok '--skipped: unsupported_ext=0 (no .hx falls out of the index)' \
    || no "--skipped: expected unsupported_ext=0: $( echo "$SK" | grep -o 'unsupported_ext="[0-9]*"' )"
echo "$SK" | grep -q '<lang n="hx" files="6" symbols="28"/>' && ok '--skipped: <lang n="hx" files="6" symbols="28"/> census row' \
    || no "--skipped: hx census row missing/wrong: $( echo "$SK" | grep -o '<lang n="[a-z]*" [^/]*/>' | tr '\n' ' ' )"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 5. METRICS: the Haxe control-flow kinds, by exact number ==="
# ═══════════════════════════════════════════════════════════════════════════
CX="$( cxof "$BIN" "$FIX" flow )"
[ "$CX" = 'cx="13"' ] && ok 'flow(): cx=13 (for + if + && + || + else-if + while + do-while + 2 cases + 2 catches + ?:)' \
    || no "flow(): expected cx=13, got $CX"
CX="$( cxof "$BIN" "$FIX" area )"
[ "$CX" = 'cx="3"' ] && ok 'area(): cx=3 (two switch_case arms; the ESwitch head itself is not a decision)' \
    || no "area(): expected cx=3, got $CX"
CX="$( cxof "$BIN" "$FIX" risky )"
[ "$CX" = 'cx="2"' ] && ok 'risky(): cx=2 (one if)' || no "risky(): expected cx=2, got $CX"
MET="$( "$BIN" "$FIX" --metrics --no-cache 2>/dev/null )"
echo "$MET" | grep -q 'n="flow"[^>]*ccx="14"' && ok 'flow(): ccx=14' || no "flow(): expected ccx=14: $( echo "$MET" | grep -o 'n="flow"[^>]*ccx="[0-9]*"' | grep -o 'ccx="[0-9]*"' )"
echo "$MET" | grep -q 'n="flow"[^>]*nest="2"' && ok 'flow(): nest=2 (for -> if)' || no "flow(): expected nest=2: $( echo "$MET" | grep -o 'n="flow"[^>]*nest="[0-9]*"' | grep -o 'nest="[0-9]*"' )"
echo "$MET" | grep -q 'n="flow"[^>]*params="1"' && ok 'flow(): params=1 (the args: FunctionArg children — not a confident 0)' \
    || no "flow(): expected params=1: $( echo "$MET" | grep -o 'n="flow"[^>]*params="[0-9]*"' | grep -o 'params="[0-9]*"' )"
echo "$MET" | grep -q 'n="greet"[^>]*params="0"' && ok 'greet(): params=0 (a real empty list)' \
    || no "greet(): expected params=0: $( echo "$MET" | grep -o 'n="greet"[^>]*params="[0-9]*"' | grep -o 'params="[0-9]*"' | head -1 )"
# ev= is a DISCLOSED non-goal for Haxe (model.h::evCountedLang) — assert the absence, so today's silence
# can never be read as "ev == 0" and a future round that adds ev has to come here and say so.
echo "$MET" | grep -q 'n="flow"[^>]*ev="' && no 'flow(): ev= emitted, but Haxe is outside evCountedLang — one of the two is now wrong' \
    || ok 'flow(): no ev= attribute (Haxe is deliberately outside evCountedLang; "not measured", not zero)'

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 6. DETERMINISM: default map thrice, byte-identical ==="
# ═══════════════════════════════════════════════════════════════════════════
"$BIN" "$FIX" --no-cache >"$TMP/det_a.xml" 2>/dev/null
"$BIN" "$FIX" --no-cache >"$TMP/det_b.xml" 2>/dev/null
"$BIN" "$FIX" --no-cache >"$TMP/det_c.xml" 2>/dev/null
diff -q "$TMP/det_a.xml" "$TMP/det_b.xml" >/dev/null && diff -q "$TMP/det_b.xml" "$TMP/det_c.xml" >/dev/null \
    && ok "determinism: default map byte-identical across three runs" \
    || no "determinism: default map differs across runs"

# ═══════════════════════════════════════════════════════════════════════════
echo
echo "=== 7. MUTATION: each seam moved independently ==="
# ═══════════════════════════════════════════════════════════════════════════
mutate(){ rm -rf "$TMP/mut"; cp -R "$FIX" "$TMP/mut"; }
pyedit(){ python3 -c '
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p).read()
if old not in s:
    sys.exit("mutation target not present: " + old)
open(p, "w").write(s.replace(old, new, 1))
' "$@"; }
M="$TMP/mut/src/demo"

# 7a. DROP the `&&` operand -> cx 13 -> 12 (the EBinop `op:` field really is read)
mutate
pyedit "$M/Main.hx" 'if (x > 1 && x < 9 || x == 0) {' 'if (x > 1 || x == 0) {' \
    && { CX="$( cxof "$BIN" "$TMP/mut" flow )"
         [ "$CX" = 'cx="12"' ] && ok "mutation: \`&&\` dropped -> cx 13 -> 12 (the EBinop op: field is read)" \
                               || no "mutation: expected cx=12 after dropping \`&&\`, got $CX"; } \
    || no "mutation 7a: the && edit did not apply — the arm would have been inert"

# 7b. DELETE the second catch -> cx 13 -> 12 (each `body:` field of ETry is one decision)
mutate
pyedit "$M/Main.hx" ' catch (e:Dynamic) {
			t = -2;
		}' '' && { CX="$( cxof "$BIN" "$TMP/mut" flow )"
                [ "$CX" = 'cx="12"' ] && ok "mutation: second catch deleted -> cx 13 -> 12 (a catch is a body: field of ETry, counted)" \
                                      || no "mutation: expected cx=12 after deleting a catch, got $CX"; } \
       || no "mutation 7b: the catch edit did not apply — the arm would have been inert"

# 7c. DELETE the do … while -> cx 13 -> 12 (EWhile covers both loop spellings)
mutate
pyedit "$M/Main.hx" '		do {
			t++;
		} while (t < 3);
' '' && { CX="$( cxof "$BIN" "$TMP/mut" flow )"
          [ "$CX" = 'cx="12"' ] && ok "mutation: do … while deleted -> cx 13 -> 12 (do-while is an EWhile too)" \
                                || no "mutation: expected cx=12 after deleting the do-while, got $CX"; } \
      || no "mutation 7c: the do-while edit did not apply — the arm would have been inert"

# 7d. DELETE the second case arm -> cx 13 -> 12 (switch_case is the decision, gated to Haxe)
mutate
pyedit "$M/Main.hx" '			case 2 | 3:
				t = 4;
' '' && { CX="$( cxof "$BIN" "$TMP/mut" flow )"
          [ "$CX" = 'cx="12"' ] && ok "mutation: a case arm deleted -> cx 13 -> 12 (switch_case really is a decision)" \
                                || no "mutation: expected cx=12 after deleting a case arm, got $CX"; } \
      || no "mutation 7d: the case edit did not apply — the arm would have been inert"

# 7e. DELETE the else-if arm -> cx 13 -> 12 AND ccx 14 -> 13 (flat +1, not +1+nesting: the EIf-under-EIf parity)
mutate
pyedit "$M/Main.hx" ' else if (x < 0) {
				t -= x;
			}' '' && { CX="$( cxof "$BIN" "$TMP/mut" flow )"
                   CCX="$( "$BIN" "$TMP/mut" --metrics --no-cache 2>/dev/null | grep -o 'n="flow"[^>]*ccx="[0-9]*"' | grep -o 'ccx="[0-9]*"' )"
                   [ "$CX" = 'cx="12"' ] && [ "$CCX" = 'ccx="13"' ] && ok "mutation: else-if deleted -> cx 13 -> 12, ccx 14 -> 13 (an else-if is a FLAT +1 in both)" \
                                                                    || no "mutation: expected cx=12 ccx=13 after deleting the else-if, got $CX $CCX"; } \
        || no "mutation 7e: the else-if edit did not apply — the arm would have been inert"

# 7f. rename the STATIC call site (leave the def intact) -> the greet -> shout edge must vanish
mutate
pyedit "$M/Greeter.hx" 'Fmt.shout(name)' 'Fmt.shoutX(name)' \
    && { "$BIN" "$TMP/mut" --no-cache >"$TMP/mut.xml" 2>/dev/null
         python3 - "$TMP/mut.xml" <<'PYEOF' && ok "mutation: renamed Fmt.shout() call site -> greet -> shout edge vanished" || no "mutation: greet -> shout edge survived a renamed call site (tautology)"
import re, sys
xml = open(sys.argv[1]).read()
m = re.search(r'<s t="method" n="greet"[^>]*>(.*?)</s>', xml, re.S)
sys.exit(0 if (m is None or '<c n="shout"/>' not in m.group(1)) else 1)
PYEOF
       } \
    || no "mutation 7f: the call-site rename did not apply — the arm would have been inert"

# 7g. retarget `extends Base` -> the extends use-site on Base must vanish (the FIELD really is read)
mutate
pyedit "$M/Greeter.hx" 'class Greeter extends Base implements IGreet' 'class Greeter extends Other implements IGreet' \
    && { USES_B="$( "$BIN" "$TMP/mut" --uses=Base --no-cache 2>/dev/null )"
         echo "$USES_B" | grep -q '<u role="extends"' \
             && no "mutation: an extends use-site on Base survived retargeting the clause (tautology)" \
             || ok "mutation: \`extends Other\` -> no extends use-site on Base (the extends field is what is read)"; } \
    || no "mutation 7g: the extends edit did not apply — the arm would have been inert"

# 7h. lower-case the SCREAMING constant -> it must leave the index (symbols 28 -> 27)
mutate
pyedit "$M/Base.hx" 'public static inline var MAX_RETRIES:Int = 3;' 'public static inline var maxRetries:Int = 3;' \
    && { "$BIN" "$TMP/mut" --no-cache >"$TMP/mut.xml" 2>/dev/null
         grep -q 'files=6 symbols=27' "$TMP/mut.xml" && ! grep -q 'n="maxRetries"' "$TMP/mut.xml" \
             && ok "mutation: MAX_RETRIES -> maxRetries leaves the index (symbols 28 -> 27; the SCREAMING gate is live for Haxe)" \
             || no "mutation: expected symbols=27 and no maxRetries row: $( grep -o 'files=[0-9]* symbols=[0-9]*' "$TMP/mut.xml" )"; } \
    || no "mutation 7h: the constant edit did not apply — the arm would have been inert"

# 7i. strip the #if wrapper -> the import is STILL captured (so 7i + the §3 positive together prove the
#     container path adds the guarded case without being the only path)
mutate
pyedit "$M/Main.hx" '#if sys
import sys.io.File;
#end' 'import sys.io.File;' \
    && { DEPS="$( "$BIN" "$TMP/mut" --deps --no-cache 2>/dev/null )"
         echo "$DEPS" | grep -q '<inc t="sys.io.File"/>' && ok "mutation: unguarded \`import sys.io.File\` is captured too (top level and container agree)" \
                                                        || no "mutation: the unguarded import vanished: $( echo "$DEPS" | grep -o '<inc [^/]*/>' | tr '\n' ' ' )"; } \
    || no "mutation 7i: the #if edit did not apply — the arm would have been inert"

# ─── Summary ──────────────────────────────────────────────────────────────────
echo
if [ "$fail" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
else
    echo "SOME CHECKS FAILED"
    exit 1
fi
