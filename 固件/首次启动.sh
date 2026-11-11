#!/bin/sh
# /etc/uci-defaults/99-kel —— 固件刷入后第一次开机执行一次（成功后系统自动删除本文件）。
# 两种情况都会走到这里，所以每一步都必须「已经有了就不动」：
#   A. 保留配置升级：用户的 /etc/config 已恢复，这里只补缺的、清旧的；
#   B. 恢复出厂 / 全新刷入：/etc/config 是 OpenWrt 默认值，这里补齐本系统需要的基础设置。
# 只写 uci 和开机自启状态，不在这里重启任何服务（此时系统还在启动过程中，各服务随后自己起来）。

# ---- 1. 升级保留清单：代码已经在固件（只读区）里，绝不能再随配置备份带到下一个版本——
#         否则旧版本的网页/脚本会在升级后盖住新固件里的文件。要保留的**数据**由 /lib/upgrade/keep.d/kel 声明。
if [ -f /etc/sysupgrade.conf ]; then
	grep -v -E '^/(www|usr/share/kel|usr/share/kelclash|usr/share/keladg|usr/sbin/kel-|usr/share/rpcd/|usr/share/nftables\.d/|usr/share/luci/menu\.d/kel|etc/init\.d/|etc/hotplug\.d/|etc/kel|etc/config/kel)' /etc/sysupgrade.conf > /tmp/sysupgrade.conf.new
	cat /tmp/sysupgrade.conf.new > /etc/sysupgrade.conf; rm -f /tmp/sysupgrade.conf.new
fi

# ---- 2. 定时任务（看门狗、保险丝、流量采样）
mkdir -p /etc/crontabs; touch /etc/crontabs/root
grep -q 'kel-flow-sample' /etc/crontabs/root || echo '* * * * * ubus call kelapi.static web_get_network_flow >/dev/null 2>&1 # kel-flow-sample' >> /etc/crontabs/root
grep -q '# kel-watchdog$' /etc/crontabs/root || echo '*/2 * * * * /usr/sbin/kel-watchdog # kel-watchdog' >> /etc/crontabs/root
grep -q 'kel-watchdog-fuse' /etc/crontabs/root || echo '* * * * * /usr/sbin/kel-watchdog fuse # kel-watchdog-fuse' >> /etc/crontabs/root

# ---- 3. 防火墙：代理/广告过滤的转发规则入口（规则文件由各自的守护在自检通过后才写）、访问控制与按设备关 IPv6 的集合
inc() { uci -q get firewall.$1 >/dev/null && return; uci set firewall.$1=include; uci set firewall.$1.type=nftables; uci set firewall.$1.position=chain-prepend; uci set firewall.$1.chain=dstnat; uci set firewall.$1.path=$2; }
inc kelclash /var/run/kelclash/redir.nft
inc keladg /var/run/keladg/redir.nft
# 代理「国内 IP 直连」用的命名集合（表级装入；文件由 kelclash 守护和转发规则一起写，没有时 fw4 跳过它）
uci -q get firewall.kelclash_cn >/dev/null || { uci set firewall.kelclash_cn=include; uci set firewall.kelclash_cn.type=nftables; uci set firewall.kelclash_cn.position=table-append; uci set firewall.kelclash_cn.path=/var/run/kelclash/cn.nft; }
# QUIC（UDP 443）拦截：放在 forward 链最前面（文件由 kelclash 守护在自检通过后才写；没有文件时 fw4 跳过它）
uci -q get firewall.kelclash_quic >/dev/null || { uci set firewall.kelclash_quic=include; uci set firewall.kelclash_quic.type=nftables; uci set firewall.kelclash_quic.position=chain-prepend; uci set firewall.kelclash_quic.chain=forward; uci set firewall.kelclash_quic.path=/var/run/kelclash/quic.nft; }
macset() { uci -q get firewall.$1 >/dev/null && return; uci set firewall.$1=ipset; uci set firewall.$1.name=$1; uci set firewall.$1.family=$2; uci set firewall.$1.match=src_mac; uci set firewall.$1.loadfile=/etc/kel-empty-macset; }
macset kel_macfilter_allow any
macset kel_macfilter_deny any
macset kel_noipv6 ipv6
uci -q get firewall.kel_macfilter_rule >/dev/null || { uci set firewall.kel_macfilter_rule=rule; uci set firewall.kel_macfilter_rule.name=KEL-MAC-Blacklist; uci set firewall.kel_macfilter_rule.src='*'; uci set firewall.kel_macfilter_rule.dest='*'; uci set firewall.kel_macfilter_rule.proto=all; uci set firewall.kel_macfilter_rule.family=any; uci set firewall.kel_macfilter_rule.ipset=kel_macfilter_deny; uci set firewall.kel_macfilter_rule.target=DROP; uci set firewall.kel_macfilter_rule.enabled=0; }
uci -q get firewall.kel_noipv6_rule >/dev/null || { uci set firewall.kel_noipv6_rule=rule; uci set firewall.kel_noipv6_rule.name=KEL-Device-No-IPv6; uci set firewall.kel_noipv6_rule.src='*'; uci set firewall.kel_noipv6_rule.dest='*'; uci set firewall.kel_noipv6_rule.family=ipv6; uci set firewall.kel_noipv6_rule.proto=all; uci set firewall.kel_noipv6_rule.ipset=kel_noipv6; uci set firewall.kel_noipv6_rule.target=REJECT; uci set firewall.kel_noipv6_rule.enabled=1; }
# 旧版限速脚本 /etc/kel-qos.sh 已被 kel-policy 取代，它的 include 残留在配置里（fw4 每次重载都警告「路径不存在」）
while i=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.\([^.]*\)\.path='\/etc\/kel-qos\.sh'$/\1/p" | head -n 1); [ -n "$i" ]; do uci delete firewall.$i; done
uci commit firewall
[ -e /etc/kel-empty-macset ] || : > /etc/kel-empty-macset

# ---- 3b. 拨号上网时 IPv6 用标准接法：wan6 挂在拨号连接上，不用 PPP 自动生成的 wan_6（否则 IPv6 设置页的设置不生效）
if [ "$(uci -q get network.wan.proto)" = pppoe ] && uci -q get network.wan6 >/dev/null; then
	uci set network.wan6.device='@wan'; uci set network.wan.ipv6='1'; uci commit network
fi

# ---- 4. DNS 备用上游（运营商 DNS 对部分域名不应答时兜底）
if ! uci -q get dhcp.@dnsmasq[0].server | grep -q 223.5.5.5; then
	uci add_list dhcp.@dnsmasq[0].server=223.5.5.5; uci add_list dhcp.@dnsmasq[0].server=119.29.29.29
	uci set dhcp.@dnsmasq[0].allservers=1; uci commit dhcp
fi

# ---- 5. 系统：时区（只在还是出厂默认 UTC 时设）、cron 不刷日志
[ "$(uci -q get system.@system[0].zonename)" ] || { uci set system.@system[0].timezone=CST-8; uci set system.@system[0].zonename=Asia/Shanghai; }
uci set system.@system[0].cronloglevel=9; uci commit system
[ -f /etc/config/kel ] || touch /etc/config/kel

# ---- 6. 开机自启：基础服务总是开；代理/广告过滤跟随用户在界面上的开关（uci enabled）
/etc/init.d/cron enable
/etc/init.d/kel-policy enable
/etc/init.d/guest-bss-fix enable
[ -x /etc/init.d/umdns ] && /etc/init.d/umdns enable
for s in kelclash keladg; do
	if [ "$(uci -q get $s.main.enabled)" = 1 ]; then /etc/init.d/$s enable; else /etc/init.d/$s disable; fi
done

# ---- 7. 升级记录：新系统第一次启动成功走到这里，记一行（远程升级脚本和界面据此确认「刷完并且起来了」）
# （此时系统时区文件还没生成，date 默认是 UTC；按配置里的时区算，和「start」那行对得上）
echo "$(TZ=$(uci -q get system.@system[0].timezone) date '+%Y-%m-%d %H:%M:%S') booted version=$(sed -n 's/^version=//p' /etc/kel_version)" >> /etc/kel_upgrade.log
exit 0
