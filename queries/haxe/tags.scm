; ripwire Haxe tags — written for ripwire (.hx). Derived from the upstream tong/tree-sitter-haxe v0.5.0
; node-types.json and verified against real parses (test/haxefix + the haxe/std, HaxeFlixel/flixel and
; HeapsIO/heaps shape-recall runs in the port round). The grammar's node kinds mirror the Haxe
; compiler's own AST (ClassType / ClassMethod / ECall / ENew / EField / TypePath), so the names below
; read like the language reference.
;
; Haxe structure the call graph cares about:
;   - type declarations: class / interface (ONE node kind, ClassType, told apart by its `kind:` field),
;     abstract and enum abstract (AbstractType — a container of ClassMethod/ClassVar, so it buckets as
;     class-like), enum (EnumType) and typedef (DefType) -> def nodes (the containers)
;   - methods (ClassMethod — the constructor is the method literally named `new`), NAMED functions
;     (EFunction with a `name:` — module-level functions since Haxe 4.2, and named local functions;
;     an anonymous `function( x ) …` value has no name field and correctly matches nothing)
;   - enum constructors (EnumConstructor) -> t="var": `Circle( r )` is a call to a constructor, so the
;     use-site index and --callers answer "who constructs this variant"
;   - `f( .. )`, `o.m( .. )`, `T.s( .. )`, `o?.m( .. )` and `new T( .. )` -> the call references (edges)
;   - `extends` / `implements` -> captured by ingest_relations.h::captureBases (NOT here — matches every
;     other language: tags.scm never captures inheritance directly). Haxe has no clause node: the
;     TypePaths are FIELD children of the ClassType, and the field name is what keeps an abstract's
;     `from` / `to` casts out of the inheritance overlay.
;   - `import` / `using` -> captured by ingest_relations.h::captureIncludes (NOT here, same convention).
;
; Deliberately NOT captured (noise, matching Java/C#): plain fields, properties, locals, typedef fields.
; Fields DO pass through the @definition.constant pattern below, and ingest_names.h's SCREAMING_SNAKE gate
; (constCaptureNeedsScreamingGate) is what keeps `public static inline var MAX_RETRIES` and drops
; `var count` — the same posture as Java's field_declaration.
;
; Deliberately NOT captured (CANNOT be from the syntax, disclosed rather than faked) — the honest floor:
;   - STATIC EXTENSIONS. `using StringTools; s.trim()` calls StringTools.trim( s ) — the receiver is
;     rewritten by the typer, not spelled in the text. The call IS captured (as `trim`, via the EField
;     pattern) and resolves by name like any other method call; the `using` directive is an Include record,
;     never a receiver hint.
;   - ENUM-ABSTRACT VALUES. `enum abstract Level( Int ) { var Low = 0; }` spells its values as ClassVar,
;     and the SCREAMING gate above drops them unless they are SCREAMING. A zero there is "not indexed",
;     never "none exists".
;   - HAS-A field-type edges (captureFields knows no Haxe node kind) — `--lego` composition is empty on a
;     Haxe corpus; stated, not implied.
;   - Macros and reification (`macro function`, `$i{…}`, `@:build`) generate code the text does not
;     contain; nothing is invented for them.
;   - GRAMMAR GAPS, measured (CMakeLists.txt's haxe block): `overload` as an access modifier,
;     `abstract X from Int {}` with no underlying type, and `#if` inside an expression each leave an ERROR
;     node; tree-sitter's recovery keeps the enclosing declaration, and the file still indexes.

; ---- definitions ----

; class Foo extends Base implements IBar { .. }  /  extern class  /  final class  /  private class
(ClassType
  kind: "class"
  name: (type_name) @name) @definition.class

; interface IBar { .. }
(ClassType
  kind: "interface"
  name: (type_name) @name) @definition.interface

; abstract Meters( Float ) from Float to Float { .. }  /  enum abstract Level( Int ) { .. } — a container
; of methods and vars, class-like for the call graph (its from/to are casts, not bases — see header)
(AbstractType
  name: (type_name) @name) @definition.class

; enum Shape { Dot; Circle( r:Float ); }  — typedef/alias/enum bucket (matches Java/C# enum -> definition.type)
(EnumType
  name: (type_name) @name) @definition.type

; typedef Point = { x:Float, y:Float };
(DefType
  name: (type_name) @name) @definition.type

; function greet():String { .. }  — a method; `function new( .. )` is the constructor, named `new`.
; An interface's body-less `function greet():String;` is the same node without a `body:` and lands as a
; declaration the graph's decl/def collapse already knows how to shadow.
(ClassMethod
  name: (identifier) @name) @definition.method

; function area( s:Shape ):Float { .. }  — a NAMED function: module-level (Haxe 4.2 module fields) or a
; named local function inside a body. Anonymous function values have no `name:` and match nothing.
(EFunction
  name: (identifier) @name) @definition.function

; enum Shape { Dot; Circle( r:Float ); }  — each constructor is a value/callable the code constructs by name
(EnumConstructor
  name: (identifier) @name) @definition.var

; settings constants: `public static inline var MAX_RETRIES:Int = 3;` — the pattern sees EVERY class field
; (and property), and ingest_names.h's SCREAMING_SNAKE gate keeps the field-noise exclusion above intact.
(ClassVar
  name: (identifier) @name) @definition.constant

; module-level `final GREETING_PREFIX = "hi";` / `var …` — the same gate; anchored under `module` so a
; local `var` inside a body (also EVars) never reaches it.
(module
  (EVars
    name: (identifier) @name) @definition.constant)

; ---- references (calls) ----

; foo( .. )  — bare call (same-class method, local function, module function, enum constructor)
(ECall
  callee: (identifier) @name) @reference.call

; obj.foo( .. )  /  Type.staticFn( .. )  /  obj?.foo( .. )  — one EField node kind, `.` and `?.` alike
(ECall
  callee: (EField
    name: (identifier) @name)) @reference.call

; new Foo( .. )  /  new pkg.Foo<T>( .. )  — object creation resolves to the class name (the constructor is
; the method named `new` inside it; `--callers=Foo` answers "who constructs Foo")
(ENew
  (TypePath
    name: (type_name) @name)) @reference.call
