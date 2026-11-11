#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""组装.py —— 把本地源码摆成固件里的目录结构（固件/files/），交给 ImageBuilder 的 FILES= 打进只读区。
来源只有本地源码：前端静态包/kelweb.tar.gz（先跑 部署工具/打包前端.py）、后端插件/。不从路由器取任何东西。
用法: python3 组装.py"""
import os, re, shutil, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.dirname(HERE)
OUT = os.path.join(HERE, "files")
B = os.path.join(P, "后端插件")
SYS = os.path.join(B, "系统集成")      # 设备策略、访客修复等（2026-10-13 从路由器收回本地的源码）

# (源, 固件内路径, 权限)
MAP = [
    (B + "/kelapi",                    "usr/share/rpcd/ucode/kelapi", 0o644),
    (B + "/kelapi.json",               "usr/share/rpcd/acl.d/kelapi.json", 0o644),
    (B + "/kel-lib/lib.sh",            "usr/share/kel/lib.sh", 0o644),
    (B + "/kel-watchdog",              "usr/sbin/kel-watchdog", 0o755),
    (B + "/kel-upgrade",               "usr/sbin/kel-upgrade", 0o755),
    (B + "/kelclash/run.sh",           "usr/share/kelclash/run.sh", 0o755),
    (B + "/kelclash/stats.uc",         "usr/share/kelclash/stats.uc", 0o644),
    (B + "/kelclash/kelclash.init",    "etc/init.d/kelclash", 0o755),
    (B + "/kelclash/kelclash.config",  "etc/config/kelclash", 0o644),
    (B + "/keladg/run.sh",             "usr/share/keladg/run.sh", 0o755),
    (B + "/keladg/keladg.init",        "etc/init.d/keladg", 0o755),
    (B + "/keladg/keladg.config",      "etc/config/keladg", 0o644),
    (B + "/kel-devinfo.hotplug",       "etc/hotplug.d/dhcp/30-kel-devinfo", 0o755),
    (B + "/kel-time.hotplug",          "etc/hotplug.d/ntp/30-kel-time", 0o755),
    (B + "/luci-syslog",               "www/cgi-bin/luci-syslog", 0o755),
    (B + "/get_clientmac.cgi",         "www/cgi-bin/get_clientmac.cgi", 0o755),
    (SYS + "/etc/init.d/kel-policy",   "etc/init.d/kel-policy", 0o755),
    (SYS + "/etc/init.d/guest-bss-fix", "etc/init.d/guest-bss-fix", 0o755),
    (SYS + "/usr/share/kel/policy.uc", "usr/share/kel/policy.uc", 0o644),
    (SYS + "/usr/share/kel/oui-cache.json", "usr/share/kel/oui-cache.json", 0o644),
    (SYS + "/usr/share/luci/menu.d/kel-policy.json", "usr/share/luci/menu.d/kel-policy.json", 0o644),
    (SYS + "/usr/share/rpcd/acl.d/kel-policy.json", "usr/share/rpcd/acl.d/kel-policy.json", 0o644),
    (SYS + "/www/luci-static/resources/view/kel/devices.js", "www/luci-static/resources/view/kel/devices.js", 0o644),
    (HERE + "/首次启动.sh",            "etc/uci-defaults/99-kel", 0o755),
    (HERE + "/保留清单.txt",           "lib/upgrade/keep.d/kel", 0o644),
]


# 固件是要分发的：里面只能有程序和默认设置，不能有任何一台路由器的个人数据。
# 订阅链接、宽带账号、Wi-Fi 密码、SSH 密钥、设备列表这些都属于用户，刷完后由用户自己在界面上填。
ALLOW_ETC = {"etc/config/kelclash", "etc/config/keladg", "etc/kel-empty-macset", "etc/kel_version",
             "etc/uci-defaults/99-kel", "etc/init.d/kelclash", "etc/init.d/keladg", "etc/init.d/kel-policy",
             "etc/init.d/guest-bss-fix", "etc/hotplug.d/dhcp/30-kel-devinfo", "etc/hotplug.d/ntp/30-kel-time",
             "etc/uci-defaults/98-migrate-legacy"}
SECRET = re.compile(rb"token=[0-9A-Za-z]{8,}|subscribe\?|PRIVATE KEY|ssh-(ed25519|rsa) AAAA|option (password|key|username) '[^']+'")


def check_clean():
    bad = []
    for dp, _d, ns in os.walk(OUT):
        for fn in ns:
            fp = os.path.join(dp, fn); rel = os.path.relpath(fp, OUT)
            if rel.startswith("etc/") and rel not in ALLOW_ETC:
                bad.append("不该进固件的文件: " + rel)
            if rel.startswith("www/") and not rel.startswith("www/cgi-bin/"):
                continue        # 网页是原厂静态资源 + 我们的页面，不含配置
            m = SECRET.search(open(fp, "rb").read())
            if m and rel not in ("usr/share/rpcd/ucode/kelapi",):   # 后端代码里有这些字段名是正常的，单独看默认配置
                bad.append("疑似个人数据: %s （%s）" % (rel, m.group(0)[:30].decode("latin1")))
    cfg = open(OUT + "/etc/config/kelclash", encoding="utf-8").read()
    if not re.search(r"option sub_url ''", cfg) or not re.search(r"option enabled '0'", cfg) or re.search(r"option secret", cfg):
        bad.append("etc/config/kelclash 的默认值不干净：订阅地址必须为空、默认关闭、不带控制口密钥")
    if not re.search(r"option enabled '0'", open(OUT + "/etc/config/keladg", encoding="utf-8").read()):
        bad.append("etc/config/keladg 默认必须关闭")
    if bad:
        raise SystemExit("!! 固件内容检查未通过，已中止：\n   " + "\n   ".join(bad))
    print("个人数据检查通过：固件里没有订阅链接、账号密码、密钥或设备数据")


def main():
    ver = open(os.path.join(HERE, "版本.txt")).read().strip()
    subprocess.run(["rm", "-rf", OUT], check=True)
    os.makedirs(OUT + "/www")
    subprocess.run(["tar", "xzf", P + "/前端静态包/kelweb.tar.gz", "-C", OUT + "/www"], check=True)
    for src, rel, mode in MAP:
        dst = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
        os.chmod(dst, mode)
    # 从旧版本升级时的一次性迁移脚本（可选：只有在 私有/ 里放了这个文件才会带上，开源仓库里没有它）
    legacy = os.path.join(P, "私有", "迁移旧版.sh")
    if os.path.exists(legacy):
        shutil.copyfile(legacy, OUT + "/etc/uci-defaults/98-migrate-legacy")
        os.chmod(OUT + "/etc/uci-defaults/98-migrate-legacy", 0o755)
        print("已带上旧版本迁移脚本")
    for dp, _d, ns in os.walk(OUT + "/www/cgi-bin"):
        for fn in ns:
            os.chmod(os.path.join(dp, fn), 0o755)
    open(OUT + "/etc/kel-empty-macset", "w").close()
    # 版本文件：界面「检查更新」和升级脚本都读它
    with open(OUT + "/etc/kel_version", "w") as f:
        f.write("version=%s\nbuild=%s\nbase=OpenWrt 25.12.5\nboard=jdcloud,re-cp-02\n" % (ver, time.strftime("%Y%m%d-%H%M")))
    # macOS 垃圾
    for dp, _d, ns in os.walk(OUT):
        for fn in ns:
            if fn.startswith("._") or fn == ".DS_Store":
                os.remove(os.path.join(dp, fn))
    check_clean()
    n = sum(len(ns) for _dp, _d, ns in os.walk(OUT))
    sz = sum(os.path.getsize(os.path.join(dp, fn)) for dp, _d, ns in os.walk(OUT) for fn in ns)
    print("files/ 已组装：%d 个文件，%.1f MB，版本 %s" % (n, sz / 1048576, ver))


if __name__ == "__main__":
    main()
