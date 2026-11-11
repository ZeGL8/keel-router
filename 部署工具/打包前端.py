#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
打包前端.py —— 从镜像重新生成 前端静态包/kelweb.tar.gz

为什么要有这一步
----------------
固件构建（固件/构建.sh）和日常推送（部署工具/远程推送.sh）都以 `前端静态包/kelweb.tar.gz` 为准，
所以前端的改动都放在 前端补丁/新增/，由本脚本合进这个包，否则会被包里的旧版本盖掉。
本脚本以包内文件清单为基准（只含原厂界面那 287 个文件，不含 LuCI），
逐个从工作镜像取最新内容，再补进 Public_JS/kelargs.js，最后重新压缩。

用法:
    python3 打包前端.py [镜像目录] [--dry]
"""
import os, hashlib, re
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("--") \
    else "/tmp/www_pull"
# 我们自己新增的页面/脚本的源文件放在项目里（前端补丁/新增），不再依赖易失的 /tmp 镜像
NEWDIR = os.path.normpath(os.path.join(HERE, "..", "前端补丁", "新增"))
PKG = os.path.normpath(os.path.join(HERE, "..", "前端静态包", "kelweb.tar.gz"))
SHIM = "Public_JS/kelargs.js"
# 原包里没有、由我们新增的文件（包清单是基准，新文件必须登记在这里才会进包，
# 否则打包时被静默漏掉 —— 2026-09-27 新增 openwrt 入口时踩到）
EXTRA = [
    SHIM,
    "PC/seniorManagement/openwrt.html",   # 高级功能 → OpenWrt高级设置
    "P_IMG/menu-openwrt.png",
    "cgi-bin/luci-sso",                   # 免二次登录进 LuCI
    "Public_JS/kel-ports.js",             # 网口自定义页：网口用途/速率设置
    "PC/seniorManagement/ipv6fw.html",    # 外网访问 → IPv6 防火墙（设备入站放行，后端 web_get_inbound_overview / web_set_device_inbound）
    "P_IMG/menu-ipv6fw.svg",
    "Public_JS/kel-devices.js",           # 设备列表（整页自绘）：名称/限速/IPv6 的唯一入口，展示公网 IPv6
    "PC/css/kel-devices.css",
    "PC/seniorManagement/clash.html",     # 高级功能 → 代理加速（mihomo，后端 web_get/set_clash）
    "P_IMG/menu-proxy.png",
    "P_IMG/menu-adg.png",
    "PC/css/kel-app.css",                 # 高级功能页共用样式
    "PC/seniorManagement/adguard.html",   # 高级功能 → 广告过滤（AdGuardHome，后端 web_get/set_adg）
    "Public_JS/kel-ui.js",                # 操作反馈层（进度条/处理中状态）
    "Public_JS/kel-upgrade.js",           # 路由设置 → 系统：上传固件升级（挂载在 新增/PC/routerSet/system.html）
    "Public_JS/kel-nav.js",               # 顶部导航新增「外网访问」「网络服务」（入口数据在 新增/Public_JS/json.js，挂载在 新增/PC/main.html）
    "Public_JS/kel-storage.js",           # 路由状态页「存储状态」卡：内存/闪存（后端 web_get_storage_info，挂载在 新增/PC/routerStatus/routerStatus.html）
    "Public_JS/kel-adv.js",               # 高级功能各页：标题/说明/设备选择
]

# 已废弃、要从包里剔除的文件（否则「镜像里找不到就沿用包内旧版本」会让它永远留在包里）。
# 路由器上的残留由 远程推送.sh 按同一份清单删除。
REMOVED = [
    "Public_JS/kel-adv-menu.js",          # 2026-10-12 被 kel-nav.js 取代
    "Public_JS/kel-devinfo.js",           # 2026-10-13 设备列表改为 kel-devices.js 整页自绘，以下三个不再使用
    "Public_JS/kel-ipv6.js",
    "PC/management/deviceList.12f39191d810dc140916.js",
]


def pack_stamp():
    """项目里所有前端源文件内容的摘要：内容不变戳不变（重复打包得到同一个包），任何一个文件变了戳就变"""
    h = hashlib.md5()
    for dp, _d, ns in sorted(os.walk(NEWDIR)):
        for fn in sorted(ns):
            if not fn.startswith("."):
                h.update(fn.encode()); h.update(open(os.path.join(dp, fn), "rb").read())
    return h.hexdigest()[:10]


def src_of(rel):
    """新增文件优先取项目里的源，其余取镜像"""
    p = os.path.join(NEWDIR, rel)
    return p if os.path.exists(p) else os.path.join(ROOT, rel)


def members():
    with tarfile.open(PKG, "r:gz") as t:
        # 备份残留（*.bak* / *.orig）不进包：否则每次部署都把它们重新铺回 /www
        return [m.name.lstrip("./") for m in t.getmembers()
                if m.isfile() and ".bak" not in m.name and not m.name.endswith(".orig")
                and m.name.lstrip("./") not in REMOVED]


def main():
    old = members()
    print("原包内文件 %d 个" % len(old))

    changed, missing, added = [], [], []
    for rel in old:
        p = src_of(rel)
        if not os.path.exists(p):
            missing.append(rel)
        else:
            changed.append(rel)

    for rel in EXTRA:
        if rel not in old and os.path.exists(src_of(rel)):
            added.append(rel)

    if missing:
        print("⚠️ 镜像里找不到 %d 个包内文件（将沿用包内旧版本）：" % len(missing))
        for m in missing[:10]:
            print("   " + m)

    print("待写入 %d 个文件（其中新增 %d）" % (len(changed) + len(added),
                                              len(added)))
    if "--dry" in sys.argv:
        return

    # 先解出包里存在、镜像里缺失的那些（保住不漏）
    # ⚠️ 用系统 tar 而不是 python tarfile：本环境的沙箱会拦 os.mkdir 的 EEXIST
    tmp = "/tmp/_pack_front"
    subprocess.run(["rm", "-rf", tmp], check=True)
    subprocess.run(["mkdir", "-p", tmp], check=True)
    subprocess.run(["tar", "xzf", PKG, "-C", tmp], check=True)

    for rel in changed + added:
        src = src_of(rel)
        dst = os.path.join(tmp, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(src, "rb") as fi, open(dst, "wb") as fo:
            fo.write(fi.read())
        # CGI 必须保留可执行位，否则 uhttpd 回 403（旧实现一律 644）
        os.chmod(dst, 0o755 if rel.startswith("cgi-bin/") else 0o644)

    # 缓存戳：浏览器会按「距上次修改时间的 10%」自行缓存静态文件（uhttpd 不发 Cache-Control），
    # 更新后用户可能几小时内看到的还是旧页面/旧脚本——旧页面配新后端会显示错的状态（2026-10-13 实际发生：
    # 「按服务选节点」全部显示成跟随全局）。所以每次打包给入口页地址和我们自己的 js/css 引用统一换一个戳。
    stamp = pack_stamp()
    for dp, _d, ns in os.walk(tmp):
        for fn in ns:
            fp = os.path.join(dp, fn)
            if fn == "json.js" and dp.endswith("Public_JS"):
                s = open(fp, encoding="utf-8").read()
                s2 = re.sub(r'\.html(\?v=[0-9a-z]+)?"', '.html?v=%s"' % stamp, s)
            elif fn.endswith(".html"):
                s = open(fp, encoding="utf-8", errors="surrogateescape").read()
                s2 = re.sub(r'((?:kel-[a-z-]+|json)\.(?:js|css))\?v=[0-9a-z]+', r'\1?v=' + stamp, s)
                # 原厂脚本（name.<20位hash>.js）也换戳：前端补丁/新增 里有改过内容的原厂脚本（删掉了调用后端不存在接口的代码），文件名不变，不换戳浏览器会继续用旧的
                s2 = re.sub(r'([A-Za-z_]+\.[0-9a-f]{20}\.js)\?(?:v=)?[0-9a-z]+', r'\1?v=' + stamp, s2)
                if fn == "main.html":
                    s2 = re.sub(r'(href="\./[A-Za-z]+/[A-Za-z_]+\.html)(\?v=[0-9a-z]+)?"', r'\1?v=%s"' % stamp, s2)
                    # 首页框架（iframe）的初始页也要换戳：它没有 href，上面那条管不到，浏览器就会一直用缓存里的旧首页
                    # （2026-11-08 升级后实际发生：旧首页引用已经改名的脚本，统计卡只剩文字）
                    s2 = re.sub(r'(src="\./[A-Za-z]+/[A-Za-z_]+\.html)(\?v=[0-9a-z]+)?"', r'\1?v=%s"' % stamp, s2)
            elif fn.endswith(".js"):
                s = open(fp, encoding="utf-8", errors="surrogateescape").read()
                # 机型配置文件：登录页读它来设 model cookie，页面据此选路由器照片、走机型分支；浏览器缓存着旧的就会拿到旧代号
                # （2026-11-08 升级后实际发生：旧代号 → 页面不认识 → 路由器照片变成默认的黑色那张）
                s2 = re.sub(r'(product_platform\.json)(\?v=[0-9a-z]+)?(["\'])', r'\1?v=%s\3' % stamp, s)
            else:
                continue
            if s2 != s:
                open(fp, "w", encoding="utf-8", errors="surrogateescape").write(s2)

    for rel in REMOVED:
        if os.path.exists(os.path.join(tmp, rel)):
            os.remove(os.path.join(tmp, rel))

    # 去掉 macOS 的 ._ 垃圾
    for dp, _d, ns in os.walk(tmp):
        for fn in ns:
            # ._ 是 macOS 垃圾；*.bak* / *.orig 是改动前的备份残留（占路由器闪存）
            if fn.startswith("._") or ".bak" in fn or fn.endswith(".orig"):
                os.remove(os.path.join(dp, fn))

    # --no-mac-metadata：macOS bsdtar 默认会把带扩展属性的文件打成 ._ AppleDouble
    # 条目塞进包（实测多出 315 个 ._），路由器端虽有 find 删除兜底，但包必须干净。
    subprocess.run(["tar", "czf", PKG, "--no-mac-metadata", "-C", tmp, "."], check=True)

    # 打包后自检：包内绝不允许出现 ._ 成员（bsdtar 行为兜底 + 防将来换 tar 命令）
    with tarfile.open(PKG, "r:gz") as t:
        all_members = t.getmembers()
    junk = [m.name for m in all_members if "/._" in m.name or m.name.startswith("._")]
    if junk:
        raise SystemExit("!! 包内仍有 macOS ._ 垃圾 %d 个（示例 %s）—— 打包未通过，包已损坏请重跑"
                         % (len(junk), junk[:3]))
    n = len([m for m in all_members if m.isfile()])
    print("✅ 已重新打包 %s（%d 个文件，无 ._ 垃圾）" % (os.path.basename(PKG), n))


main()
