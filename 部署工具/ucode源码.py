# -*- coding: utf-8 -*-
"""
ucode源码.py —— ucode 源码的公共解析工具（供 检查定义顺序.py / 功能盘点.py 使用）

  strip_comments_and_strings(raw)  注释、字符串、正则字面量的内容替换成空格（保留换行和引号），长度不变，偏移一一对应
  slice_braces(s, i)               s[i] 是 "{"，返回与之配对的 "}" 之后的下标（s 必须是 strip 过的）
  line_of(raw, pos)                偏移 → 行号（从 1 起）
"""
import re

# 这些字符后面出现的 "/" 是正则字面量的开头（而不是除号）
_REGEX_PREV = set("(,=:[!&|?{};+-*%<>~^")


def strip_comments_and_strings(raw):
    out = list(raw)
    n, i = len(raw), 0
    prev = ""            # 上一个非空白字符

    def blank(a, b):
        for k in range(a, b):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        c = raw[i]
        nx = raw[i + 1] if i + 1 < n else ""
        if c == "/" and nx == "/":
            j = raw.find("\n", i)
            j = n if j < 0 else j
            blank(i, j); i = j; continue
        if c == "/" and nx == "*":
            j = raw.find("*/", i + 2)
            j = n if j < 0 else j + 2
            blank(i, j); i = j; continue
        if c in "'\"`":
            j = i + 1
            while j < n and raw[j] != c:
                j += 2 if raw[j] == "\\" else 1
            blank(i + 1, min(j, n)); i = j + 1; prev = c; continue
        if c == "/" and (prev == "" or prev in _REGEX_PREV or re.search(r"\b(return|in|typeof)\s*$", raw[max(0, i - 8):i])):
            j, cls = i + 1, False
            while j < n and raw[j] != "\n":
                if raw[j] == "\\":
                    j += 2; continue
                if raw[j] == "[":
                    cls = True
                elif raw[j] == "]":
                    cls = False
                elif raw[j] == "/" and not cls:
                    break
                j += 1
            if j < n and raw[j] == "/":
                blank(i + 1, j); i = j + 1; prev = "/"; continue
        if not c.isspace():
            prev = c
        i += 1
    return "".join(out)


def slice_braces(s, i):
    depth = 0
    for k in range(i, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                return k + 1
    return None


def line_of(raw, pos):
    return raw.count("\n", 0, pos) + 1
