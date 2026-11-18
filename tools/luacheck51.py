"""Minimal Lua 5.1 parser + scope linter (no external deps).

Reports: syntax errors, GLua-only syntax (!=, &&, ||, !, //, continue),
global reads/writes not in an allow-list, unused locals (simple), shadowing of
locals in same scope is ignored.
"""
import re
import sys

KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}


class LuaError(Exception):
    pass


class Tok:
    __slots__ = ("kind", "val", "line")

    def __init__(self, kind, val, line):
        self.kind, self.val, self.line = kind, val, line

    def __repr__(self):
        return f"{self.kind}:{self.val!r}@{self.line}"


def tokenize(src):
    toks = []
    i, n, line = 0, len(src), 1
    ops3 = ["..."]
    ops2 = ["==", "~=", "<=", ">=", "..", "::"]
    bad2 = ["!=", "&&", "||", "//", "/*"]
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c in " \t\r":
            i += 1
            continue
        if src.startswith("--", i):
            m = re.match(r"--\[(=*)\[", src[i:])
            if m:
                close = "]" + m.group(1) + "]"
                j = src.find(close, i + len(m.group(0)))
                if j < 0:
                    raise LuaError(f"line {line}: unterminated long comment")
                line += src.count("\n", i, j)
                i = j + len(close)
            else:
                j = src.find("\n", i)
                i = n if j < 0 else j
            continue
        m = re.match(r"\[(=*)\[", src[i:])
        if m:
            close = "]" + m.group(1) + "]"
            j = src.find(close, i + len(m.group(0)))
            if j < 0:
                raise LuaError(f"line {line}: unterminated long string")
            toks.append(Tok("string", src[i + len(m.group(0)):j], line))
            line += src.count("\n", i, j)
            i = j + len(close)
            continue
        if c in "\"'":
            j = i + 1
            buf = []
            while True:
                if j >= n:
                    raise LuaError(f"line {line}: unterminated string")
                ch = src[j]
                if ch == "\\":
                    buf.append(src[j:j + 2])
                    if src[j + 1] == "\n":
                        line += 1
                    j += 2
                    continue
                if ch == "\n":
                    raise LuaError(f"line {line}: newline in string")
                if ch == c:
                    break
                buf.append(ch)
                j += 1
            toks.append(Tok("string", "".join(buf), line))
            i = j + 1
            continue
        m = re.match(r"0[xX][0-9a-fA-F]+|(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?", src[i:])
        if m and (c.isdigit() or (c == "." and i + 1 < n and src[i + 1].isdigit())):
            toks.append(Tok("number", m.group(0), line))
            i += len(m.group(0))
            continue
        m = re.match(r"[A-Za-z_][A-Za-z0-9_]*", src[i:])
        if m:
            w = m.group(0)
            if w == "continue":
                raise LuaError(f"line {line}: GLua-only keyword 'continue'")
            toks.append(Tok("kw" if w in KEYWORDS else "name", w, line))
            i += len(w)
            continue
        for b in bad2:
            if src.startswith(b, i):
                raise LuaError(f"line {line}: GLua-only operator {b!r}")
        if c == "!":
            raise LuaError(f"line {line}: GLua-only operator '!'")
        matched = False
        for op in ops3 + ops2:
            if src.startswith(op, i):
                toks.append(Tok("op", op, line))
                i += len(op)
                matched = True
                break
        if matched:
            continue
        if c in "+-*/%^#<>=(){}[];:,.":
            toks.append(Tok("op", c, line))
            i += 1
            continue
        raise LuaError(f"line {line}: unexpected character {c!r}")
    toks.append(Tok("eof", None, line))
    return toks


BINPRI = {
    "or": (1, 1), "and": (2, 2),
    "<": (3, 3), ">": (3, 3), "<=": (3, 3), ">=": (3, 3), "~=": (3, 3), "==": (3, 3),
    "..": (5, 4),  # right assoc
    "+": (6, 6), "-": (6, 6),
    "*": (7, 7), "/": (7, 7), "%": (7, 7),
    "^": (10, 9),  # right assoc
}
UNARY_PRI = 8


class Scope:
    def __init__(self, parent, is_func=False):
        self.parent = parent
        self.vars = {}
        self.is_func = is_func


class Parser:
    def __init__(self, toks, fname):
        self.t = toks
        self.p = 0
        self.fname = fname
        self.scope = None
        self.global_reads = {}
        self.global_writes = {}
        self.locals_info = []  # (name, line, used_flag_holder)

    # --- token helpers
    def peek(self, k=0):
        return self.t[self.p + k]

    def next(self):
        tok = self.t[self.p]
        self.p += 1
        return tok

    def check(self, val):
        tok = self.peek()
        return tok.kind in ("op", "kw") and tok.val == val

    def accept(self, val):
        if self.check(val):
            self.p += 1
            return True
        return False

    def expect(self, val, what=""):
        tok = self.peek()
        if not self.check(val):
            raise LuaError(f"line {tok.line}: expected {val!r} {what} got {tok.val!r}")
        self.p += 1
        return tok

    def name(self):
        tok = self.next()
        if tok.kind != "name":
            raise LuaError(f"line {tok.line}: expected name, got {tok.val!r}")
        return tok

    # --- scopes
    def push(self, is_func=False):
        self.scope = Scope(self.scope, is_func)

    def pop(self):
        for nm, info in self.scope.vars.items():
            if not info["used"] and not nm.startswith("_") and nm not in ("self",):
                self.locals_info.append((nm, info["line"]))
        self.scope = self.scope.parent

    def declare(self, tok_or_name, line=None):
        if isinstance(tok_or_name, Tok):
            nm, line = tok_or_name.val, tok_or_name.line
        else:
            nm = tok_or_name
        # redeclare in same scope: mark previous as used to avoid noise
        if nm in self.scope.vars:
            self.scope.vars[nm]["used"] = True
        self.scope.vars[nm] = {"line": line, "used": False}

    def resolve(self, nm, line, write=False):
        s = self.scope
        while s:
            if nm in s.vars:
                if not write:
                    s.vars[nm]["used"] = True
                return True
            s = s.parent
        (self.global_writes if write else self.global_reads).setdefault(nm, []).append(line)
        return False

    # --- grammar
    def chunk(self):
        self.push(is_func=True)
        self.declare("...", 0)
        self.scope.vars["..."]["used"] = True
        self.block()
        if self.peek().kind != "eof":
            tok = self.peek()
            raise LuaError(f"line {tok.line}: unexpected {tok.val!r}")
        self.pop()

    def block_follow(self):
        tok = self.peek()
        return tok.kind == "eof" or (tok.kind == "kw" and tok.val in ("end", "else", "elseif", "until"))

    def block(self):
        while not self.block_follow():
            if self.check("return"):
                self.next()
                if not self.block_follow() and not self.check(";"):
                    self.explist()
                self.accept(";")
                if not self.block_follow():
                    tok = self.peek()
                    raise LuaError(f"line {tok.line}: 'return' must be last statement")
                return
            if self.check("break"):
                self.next()
                self.accept(";")
                if not self.block_follow():
                    tok = self.peek()
                    raise LuaError(f"line {tok.line}: 'break' must be last statement")
                return
            self.statement()
            self.accept(";")

    def statement(self):
        tok = self.peek()
        if tok.kind == "kw":
            v = tok.val
            if v == "if":
                self.next(); self.expr(); self.expect("then")
                self.scoped_block()
                while self.accept("elseif"):
                    self.expr(); self.expect("then"); self.scoped_block()
                if self.accept("else"):
                    self.scoped_block()
                self.expect("end", "to close 'if'")
                return
            if v == "while":
                self.next(); self.expr(); self.expect("do"); self.scoped_block(); self.expect("end"); return
            if v == "do":
                self.next(); self.scoped_block(); self.expect("end"); return
            if v == "for":
                self.next()
                n1 = self.name()
                if self.accept("="):
                    self.expr(); self.expect(","); self.expr()
                    if self.accept(","):
                        self.expr()
                    self.expect("do")
                    self.push(); self.declare(n1); self.block(); self.pop()
                    self.expect("end")
                else:
                    names = [n1]
                    while self.accept(","):
                        names.append(self.name())
                    self.expect("in"); self.explist(); self.expect("do")
                    self.push()
                    for nm in names:
                        self.declare(nm)
                    self.block(); self.pop()
                    self.expect("end")
                return
            if v == "repeat":
                self.next(); self.push(); self.block(); self.expect("until"); self.expr(); self.pop(); return
            if v == "function":
                self.next()
                n = self.name()
                self.resolve(n.val, n.line, write=True) if not self._is_dotted() else self.resolve(n.val, n.line)
                is_method = False
                while self.accept("."):
                    self.name()
                if self.accept(":"):
                    self.name(); is_method = True
                self.funcbody(is_method)
                return
            if v == "local":
                self.next()
                if self.accept("function"):
                    n = self.name(); self.declare(n)
                    self.scope.vars[n.val]["used"] = True  # recursion/self-ref fine
                    self.funcbody(False)
                    return
                names = [self.name()]
                while self.accept(","):
                    names.append(self.name())
                if self.accept("="):
                    self.explist()
                for nm in names:
                    self.declare(nm)
                return
        # exprstat
        kind, last = self.suffixedexp(assign_ctx=True)
        if self.check("=") or self.check(","):
            targets = [(kind, last)]
            while self.accept(","):
                targets.append(self.suffixedexp(assign_ctx=True))
            self.expect("=")
            for k, l in targets:
                if k == "call":
                    raise LuaError(f"line {tok.line}: cannot assign to call")
                if k == "name":
                    self.resolve(l.val, l.line, write=True)
            self.explist()
        else:
            if kind != "call":
                raise LuaError(f"line {tok.line}: syntax error near {self.peek().val!r} (expression statement)")
            if kind == "name":
                pass

    def _is_dotted(self):
        return self.check(".") or self.check(":")

    def scoped_block(self):
        self.push(); self.block(); self.pop()

    def funcbody(self, is_method):
        self.expect("(")
        self.push(is_func=True)
        if is_method:
            self.declare("self", self.peek().line)
            self.scope.vars["self"]["used"] = True
        if not self.check(")"):
            while True:
                if self.accept("..."):
                    self.declare("...", self.peek().line)
                    self.scope.vars["..."]["used"] = True
                    break
                n = self.name()
                self.declare(n)
                if not self.accept(","):
                    break
        self.expect(")")
        self.block()
        self.expect("end", "to close function")
        self.pop()

    def explist(self):
        self.expr()
        while self.accept(","):
            self.expr()

    def primaryexp(self, assign_ctx):
        tok = self.peek()
        if tok.kind == "name":
            self.next()
            # defer resolve for possible assignment target
            return "name", tok
        if self.accept("("):
            self.expr(); self.expect(")")
            return "paren", None
        raise LuaError(f"line {tok.line}: unexpected symbol {tok.val!r}")

    def suffixedexp(self, assign_ctx=False):
        kind, last = self.primaryexp(assign_ctx)
        first_name = last if kind == "name" else None
        had_suffix = False
        while True:
            if self.accept("."):
                self.name(); kind = "index"; had_suffix = True
            elif self.accept("["):
                if first_name and not had_suffix:
                    self.resolve(first_name.val, first_name.line); first_name = None
                self.expr(); self.expect("]"); kind = "index"; had_suffix = True
            elif self.accept(":"):
                self.name(); self.funcargs(); kind = "call"; had_suffix = True
            elif self.check("(") or self.check("{") or self.peek().kind == "string":
                if self.check("(") and self.peek().line != self.t[self.p - 1].line:
                    raise LuaError(f"line {self.peek().line}: ambiguous syntax (call on new line)")
                self.funcargs(); kind = "call"; had_suffix = True
            else:
                break
            if first_name is not None and had_suffix:
                self.resolve(first_name.val, first_name.line)
                first_name = None
        if kind == "name":
            if not assign_ctx or not (self.check("=") or self.check(",")):
                self.resolve(last.val, last.line)
                return "nameread", last
        return kind, last

    def funcargs(self):
        if self.accept("("):
            if not self.check(")"):
                self.explist()
            self.expect(")")
        elif self.check("{"):
            self.table()
        else:
            self.next()

    def table(self):
        self.expect("{")
        while not self.check("}"):
            if self.accept("["):
                self.expr(); self.expect("]"); self.expect("="); self.expr()
            elif self.peek().kind == "name" and self.peek(1).kind == "op" and self.peek(1).val == "=":
                self.next(); self.next(); self.expr()
            else:
                self.expr()
            if not (self.accept(",") or self.accept(";")):
                break
        self.expect("}")

    def simpleexp(self):
        tok = self.peek()
        if tok.kind in ("number", "string"):
            self.next(); return
        if tok.kind == "kw" and tok.val in ("nil", "true", "false"):
            self.next(); return
        if self.check("..."):
            self.next()
            # vararg only valid inside vararg function: check nearest func scope
            s = self.scope
            while s and not s.is_func:
                s = s.parent
            if not s or "..." not in s.vars:
                raise LuaError(f"line {tok.line}: cannot use '...' outside a vararg function")
            return
        if self.check("{"):
            self.table(); return
        if self.accept("function"):
            self.funcbody(False); return
        self.suffixedexp()

    def expr(self, limit=0):
        tok = self.peek()
        if (tok.kind == "kw" and tok.val == "not") or (tok.kind == "op" and tok.val in ("-", "#")):
            self.next()
            self.expr(UNARY_PRI)
        else:
            self.simpleexp()
        while True:
            tok = self.peek()
            op = tok.val if tok.kind in ("op", "kw") else None
            if op not in BINPRI or BINPRI[op][0] <= limit:
                break
            self.next()
            self.expr(BINPRI[op][1])


GMOD_GLOBALS = set("""
AetherGas bit math string table util hook timer net cvars concommand debugoverlay ents game engine player
Vector Angle Color IsValid Entity SysTime CurTime RealTime CreateConVar GetConVar AddCSLuaFile include print MsgC Msg
pairs ipairs next tonumber tostring type assert error pcall select unpack setmetatable getmetatable rawget rawset
isstring istable isnumber isbool isfunction IsColor color_white vector_origin SERVER CLIENT
FCVAR_ARCHIVE FCVAR_REPLICATED CONTENTS_SOLID CONTENTS_MOVEABLE CONTENTS_WINDOW CONTENTS_GRATE
COLLISION_GROUP_DEBRIS COLLISION_GROUP_DEBRIS_TRIGGER COLLISION_GROUP_INTERACTIVE_DEBRIS COLLISION_GROUP_WEAPON
MOVETYPE_VPHYSICS DMG_GENERIC DMG_NERVEGAS DMG_DROWN DMG_BURN HUD_PRINTCONSOLE
MASK_SOLID_BRUSHONLY MATERIAL_QUADS StormFox2 EffectData CreateClientConVar CreateMaterial Mesh mesh render surface EyePos EyeAngles ScrW ScrH
DMG_BLAST IN_WALK GNarcotics WireLib numpad input DrawMotionBlur MATERIAL_FOG_LINEAR DMG_ACID list HUD_PRINTCENTER FILL LEFT TOP vgui file NOTIFY_GENERIC NOTIFY_HINT chat ErrorNoHalt notification VectorRand tobool CreateVFireBall DynamicLight RENDERGROUP_BOTH DMG_AIRBOAT DMG_BUCKSHOT DMG_BULLET DMG_CLUB DMG_CRUSH DMG_DISSOLVE DMG_ENERGYBEAM DMG_NEVERGIB DMG_PLASMA DMG_SHOCK DMG_SLASH DMG_SLOWBURN DMG_SNIPER MAT_METAL MAT_GRATE MAT_VENT MAT_COMPUTER MAT_CONCRETE MAT_TILE MAT_FLESH MAT_ALIENFLESH MAT_BLOODYFLESH MAT_GLASS
ENT SWEP TOOL draw cam LocalPlayer IsFirstTimePredicted SafeRemoveEntityDelayed CreateSound DamageInfo SOLID_VPHYSICS COLLISION_GROUP_WEAPON SIMPLE_USE ACT_VM_THROW ACT_VM_DRAW PLAYER_ATTACK1 undo cleanup language DrawMaterialOverlay DrawColorModify Lerp FrameTime color_black TEXT_ALIGN_CENTER TEXT_ALIGN_RIGHT RunConsoleCommand NULL RealTime Material unpack spawnmenu IN_RELOAD IN_USE killicon ClientsideModel RENDERGROUP_OPAQUE properties gamemode scripted_ents weapons VJBASE_VERSION VJ DrGBase JMod IN_ATTACK constraint TEXT_ALIGN_BOTTOM
""".split())


def check_file(path):
    with open(path, encoding="utf-8") as fh:
        src = fh.read()
    toks = tokenize(src)
    p = Parser(toks, path)
    p.chunk()
    issues = []
    for nm, lines in sorted(p.global_reads.items()):
        if nm not in GMOD_GLOBALS:
            issues.append(f"  unknown global READ  {nm} at lines {sorted(set(lines))}")
    for nm, lines in sorted(p.global_writes.items()):
        if nm not in ("AetherGas",):
            issues.append(f"  global WRITE {nm} at lines {sorted(set(lines))}")
    for nm, line in p.locals_info:
        issues.append(f"  unused local {nm} (line {line})")
    return issues


if __name__ == "__main__":
    # --strict: предупреждения (неизвестные глобалы, неиспользуемые локальные) тоже дают код возврата 1 (CI)
    strict = "--strict" in sys.argv
    bad = 0
    for path in [a for a in sys.argv[1:] if a != "--strict"]:
        try:
            issues = check_file(path)
        except LuaError as e:
            print(f"SYNTAX {path}: {e}")
            bad += 1
            continue
        status = "OK " if not issues else "WARN"
        if issues and strict:
            bad += 1
        print(f"{status} {path}")
        for s in issues:
            print(s)
    sys.exit(1 if bad else 0)
