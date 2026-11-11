#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
检查定义顺序.py —— 抓 ucode「定义在后、用在前」这一类错误

机制（2026-09 在路由器上实测）
----------------------------------------------------
ucode 的函数在**被创建的那一刻**就完成了对自由变量的绑定，且**永久固化**：

  · 顶层 `function f(){}` 在文件加载执行到那一行时创建 —— 那一刻还没声明的名字，
    永久绑定失败，之后补上声明也**不会自愈**。
  · `const methods = { m: { call: function(){...} } }` 里的匿名函数，
    在该对象字面量求值（= 那几行的位置）时创建，同理。
  · 匿名函数体在新位置重新创建，就会用新环境重新绑定。

失败的表现形态**不止一种**，而且最坑的那种是静默的：

    读取未绑定名        → null（不抛！继续跑，最后得出错误结果）
    把未绑定名当函数调 → left-hand side is not a function

所以「定义在后、用在前」必须在源码顺序上根除，不能指望运行时报错。
（真实事故：applyWifi 写在 wifiSection 前面 → set_wifi 恒返回裸 [9]。
  而 rpcd 会把异常吞掉，日志里一行堆栈都没有。）

本脚本查三类位置
----------------
  1. 每个函数实例（含匿名、含方法表里的 `call: function`）的函数体
  2. 顶层可执行代码（把函数体挖空后剩下的部分）
  3. 顶层函数之间的相互引用（被 1 覆盖）

用法:
    python3 检查定义顺序.py [插件文件]
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ucode源码 as US      # noqa: E402   ← strip/正则识别统一从这里来，别再造一份

DEFAULT = os.path.join(HERE, "..", "后端插件", "kelapi")

BUILTIN = set("""
print printf warn die exit
length keys push pop shift unshift sort reverse slice splice join index
substr replace split trim lc uc
type int hex
match regexp_repl sprintf
json uniq chr ord abs min max
b64dec b64enc hexdec hexenc
require include call
popen readfile writefile access stat unlink mkdir rmdir system
proto
""".split())

IDENT = r"[A-Za-z_$][\w$]*"

# ucode 的关键字，不当引用看
KEYWORDS = set("""
if else for while do in of return break continue function let const var
new delete typeof instanceof true false null this try catch throw
switch case default import export from as
""".split())

# 不把 `.foo` / `a$.foo` 里的 foo 当引用
REF_RE = re.compile(r"(?<![\w$.])(" + IDENT + r")")


def find_defs(s):
    """引入顶层名字的位置：function 声明 / const|let|var（只取第一次出现）"""
    pos = {}
    for m in re.finditer(r"^function\s+(" + IDENT + r")\s*\(", s, re.M):
        pos.setdefault(m.group(1), (m.start(), "函数"))
    for m in re.finditer(r"^(?:const|let|var)\s+(" + IDENT + r")", s, re.M):
        pos.setdefault(m.group(1), (m.start(), "变量"))
    return pos


def collect_functions(s):
    """找出**所有**函数实例（含匿名、含方法表里的 `call: function`）

    返回 [(显示名, function 关键字位置, 体起始, 体结束)]

    位置取 function 关键字自己 —— 函数是在含它的表达式求值时创建的，
    对方法表就是那几行的位置，保守且够用。
    """
    out = []
    for m in re.finditer(r"\bfunction\s*(" + IDENT + r")?\s*\*?\s*\(", s):
        bs = s.find("{", m.end())
        if bs < 0:
            continue
        depth, k, end = 0, bs, None
        while k < len(s):
            if s[k] == "{":
                depth += 1
            elif s[k] == "}":
                depth -= 1
                if depth == 0:
                    end = k + 1
                    break
            k += 1
        if end is None:
            continue
        out.append((m.group(1) or "<匿名>", m.start(), bs, end))
    return out


def params_of(s, fpos):
    p = s.find("(", fpos)
    if p < 0:
        return set()
    q = s.find(")", p)
    if q < 0:
        return set()
    return set(re.findall(IDENT, s[p + 1:q]))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    path = args[0] if args else DEFAULT
    raw = open(path, encoding="utf-8").read()
    s = US.strip_comments_and_strings(raw)       # 同长度，偏移一一对应

    def ln(p):
        return US.line_of(raw, p)

    pos = find_defs(s)
    funcs = collect_functions(s)
    problems = []

    # ── 1. 每个函数实例体内的引用 ──────────────────────────────
    for name, fpos, bs, end in funcs:
        body = s[bs:end]
        local = set(re.findall(r"\b(?:let|const|var)\s+(" + IDENT + r")", body))
        local |= set(re.findall(r"\bfunction\s+(" + IDENT + r")", body))
        local |= params_of(s, fpos)
        for m in REF_RE.finditer(body):
            u = m.group(1)
            if u == name or u in BUILTIN or u in local:
                continue
            if u in pos and pos[u][0] > fpos:
                where = bs + m.start()
                problems.append((name, ln(fpos), u, pos[u][1],
                                 ln(pos[u][0]), ln(where)))

    # ── 2. 顶层可执行代码（挖空所有函数体后剩下的部分）──────────
    #    这里连**普通读取**也要查：ucode 读一个还没绑定的名字是静默得 null，
    #    不报错不抛异常，比抛出来的那种更难查。
    top = list(s)
    for _, _, bs, end in funcs:
        for k in range(bs, end):
            if top[k] != "\n":
                top[k] = " "
    top = "".join(top)
    for m in REF_RE.finditer(top):
        u = m.group(1)
        if u in BUILTIN or u in KEYWORDS or u not in pos:
            continue
        if pos[u][0] > m.start():
            problems.append(("(顶层)", ln(m.start()), u, pos[u][1],
                             ln(pos[u][0]), ln(m.start())))

    n_anon = sum(1 for f in funcs if f[0] == "<匿名>")
    print("顶层定义 %d 个（函数 %d）｜函数实例 %d 个（其中匿名 %d，含方法表里的 call）"
          % (len(pos), sum(1 for v in pos.values() if v[1] == "函数"),
             len(funcs), n_anon))
    print("=" * 84)
    if problems:
        print("❌ 引用了**更靠后**才创建的东西（ucode 会永久绑定失败，不会自愈）：")
        print("   %-22s %-9s %-24s %-6s %-9s %s"
              % ("引用者", "定义于", "引用了", "种类", "被引用者定义于", "引用位置"))
        for who, l1, u, uk, l2, lw in sorted(problems, key=lambda x: x[5]):
            print("   %-22s %-9s %-24s %-6s %-9s %d"
                  % (who, "第 %d 行" % l1, u, uk, "第 %d 行" % l2, lw))
    else:
        print("✅ 没有「定义在后、用在前」的引用，顺序安全")
    print("=" * 84)
    return 1 if problems else 0


sys.exit(main())
