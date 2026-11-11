#!/bin/sh
# 浸泡采样（在路由器上跑）：每 30 秒记录 内存/负载/两个服务状态/转发规则/AP载波/中继上行/DNS 自检 → /tmp/soak.log。参数：总秒数（默认 1200）
N=${1:-1200}; L=/tmp/soak.log; : > $L; t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt $N ]; do
	mem=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); ld=$(cut -d' ' -f1 /proc/loadavg)
	mh=$(grep VmRSS /proc/$(cat /tmp/kelclash/pid 2>/dev/null)/status 2>/dev/null | awk '{print int($2/1024)}'); ah=$(grep VmRSS /proc/$(cat /tmp/keladg/pid 2>/dev/null)/status 2>/dev/null | awk '{print int($2/1024)}')
	c=$(nft list chain inet fw4 dstnat 2>/dev/null | grep -c kelclash); a=$(nft list chain inet fw4 dstnat 2>/dev/null | grep -c keladg)
	ap=$(for n in phy0-ap0 phy1-ap0; do cat /sys/class/net/$n/carrier 2>/dev/null; done | tr -d '\n'); w=$(ubus call network.interface.wwan status 2>/dev/null | jsonfilter -e '@.up')
	d=$(nslookup -timeout=3 www.baidu.com 127.0.0.1 2>&1 | grep -c "^Address.*[0-9]\.[0-9]")
	echo "$(( $(date +%s) - t0 ))s 可用内存=${mem}MB 负载=$ld mihomo=${mh}MB agh=${ah}MB clash规则=$c adg规则=$a AP载波=$ap 中继=$w 本机DNS=$d" >> $L
	sleep 30
done
echo END >> $L
