#!/bin/sh
# /usr/share/keladg/run.sh —— 广告过滤（AdGuardHome）的全部动作
#   guard / rules-off / core-stop / rules-refresh / api / status
#
# 设计底线：**广告过滤出任何问题都不能让全家上不了网**。
#   ① dnsmasq 始终留在 53 端口、一步不动（DHCP、设备名、mDNS 识别都依赖它）。AdGuardHome 只监听 127.0.0.1/0.0.0.0:5354，
#      LAN 侧发往 53 的 DNS 查询由 fw4 include（/var/run/keladg/redir.nft，内存盘）重定向过来——
#      「删文件 + fw4 reload」= 一键恢复到 dnsmasq。
#   ② 规则装上之前先做 nft -c 语法检查；装完核对 nft 链里真的有，否则回滚。
#   ③ AdGuardHome 在「活着 + 监听 + 真能解析」时规则才存在：连续 2 次自检失败就撤规则；连续 4 次重启；恢复后要连续 2 次通过才重新接管。
#   ④ AdGuardHome 的上游就是 dnsmasq（127.0.0.1:53）：外网怎么解析、内网名字（*.lan）怎么解析，全部沿用 OpenWrt 原有行为。
#   ⑤ 独立看门狗（kel-watchdog，cron）不依赖本脚本：发现「规则在、守护/AdGuardHome 不在」会自己撤规则。
D=/tmp/keladg
TAG=keladg
BIN=$D/AdGuardHome
CONF=$D/AdGuardHome.yaml
WORK=$D/work
NFT=/var/run/keladg/redir.nft
FLASH=/etc/keladg
PORT=5354
API=127.0.0.1:3000
. /usr/share/kel/lib.sh
cfg() { uci -q get keladg.main.$1; }

# ------------------------------------------------------------------ 程序（只放内存）
fetch() {
	ver=$(cfg version)
	[ -x "$BIN" ] && [ -f "$D/.ok-$ver" ] && return 0
	rm -f $BIN $D/.ok-*
	url="https://github.com/AdguardTeam/AdGuardHome/releases/download/$ver/AdGuardHome_linux_mipsle_softfloat.tar.gz"
	if fetch_pkg "$url" "$(cfg size)" "$(cfg sha256)" $D/a.tgz "$(uci -q get keladg.main.mirror)" "广告过滤引擎"; then
		# 压缩包里的路径带不带 ./ 因打包方式而异：先列出来再按原样取
		mem=$(tar -tzf $D/a.tgz 2>/dev/null | grep -E '(^|/)AdGuardHome$' | head -n 1)
		if [ -n "$mem" ] && tar -xzOf $D/a.tgz "$mem" > $BIN && chmod +x $BIN; then
			rm -f $D/a.tgz; touch $D/.ok-$ver; LOG "程序就绪 $ver"; return 0
		fi
	fi
	rm -f $BIN $D/a.tgz
	phase failed "广告过滤引擎下载失败（镜像都连不上），60 秒后自动重试"; LOG "所有下载源都失败"; return 1
}

# ------------------------------------------------------------------ 配置
# 配置以 AdGuardHome 自己写的 YAML 为准（订阅、自定义规则、上游都是它管）；闪存里留一份，开机恢复。
# 每次启动都强制修正三个「安全关键项」：管理接口只听 127.0.0.1、DNS 只听 5354、关闭内置 DHCP 和登录。
genconf() {
	mkdir -p $D $WORK
	[ -s $CONF ] || { [ -s $FLASH/AdGuardHome.yaml ] && cp $FLASH/AdGuardHome.yaml $CONF; }
	if [ ! -s $CONF ]; then
		# 自检探针每 2 秒问一次「<主机名>.lan」：不进查询记录和统计，否则日志全被它刷满
		hn=$(uci -q get system.@system[0].hostname | tr 'A-Z' 'a-z'); [ -n "$hn" ] || hn=openwrt
		cat > $CONF <<EOC
schema_version: 34
http:
  address: 127.0.0.1:3000
dns:
  bind_hosts:
    - 0.0.0.0
  port: $PORT
  upstream_dns:
    - 127.0.0.1:53
  bootstrap_dns:
    - 127.0.0.1:53
  fallback_dns: []
  upstream_mode: load_balance
  local_ptr_upstreams:
    - 127.0.0.1:53
  use_private_ptr_resolvers: true
  cache_enabled: true
  cache_size: 4194304
  cache_optimistic: true
  ratelimit: 0
  blocking_mode: default
  blocked_response_ttl: 10
  enable_dnssec: false
querylog:
  enabled: true
  file_enabled: false
  interval: 24h
  size_memory: 1000
  ignored_enabled: true
  ignored:
    - '$hn.lan'
statistics:
  enabled: true
  interval: 24h
  ignored_enabled: true
  ignored:
    - '$hn.lan'
filtering:
  filtering_enabled: true
  protection_enabled: true
  filters_update_interval: 24
  safebrowsing_enabled: false
  parental_enabled: false
filters:
  - enabled: true
    url: https://anti-ad.net/adguard.txt
    name: anti-AD（中文广告/跟踪，推荐）
    id: 1
dhcp:
  enabled: false
clients:
  runtime_sources:
    whois: false
    arp: true
    rdns: false
    dhcp: false
    hosts: false
log:
  verbose: false
EOC
	fi
	# 安全关键项：无论 YAML 里现在写的是什么，都改回来（AdGuardHome 迁移配置时可能带进别的值）
	sed -i "s|^\(  address: \).*127.0.0.1:3000.*|\1127.0.0.1:3000|; s|^  port: [0-9]*$|  port: $PORT|" $CONF
}
conf_persist() {
	[ -s $CONF ] || return 0
	new=$(md5sum < $CONF | cut -d' ' -f1); [ "$new" = "$(cat $D/conf.md5 2>/dev/null)" ] && return 0
	free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 300 ] || return 0
	mkdir -p $FLASH; cp $CONF $FLASH/AdGuardHome.yaml && echo $new > $D/conf.md5
}

# ------------------------------------------------------------------ 进程
# 进程在不在（只看进程）。🔴 不能把「端口在监听」也算进来：引擎更新过滤规则/应用设置时会短暂重开 DNS 监听，
# 那一瞬间端口不在——以前因此被当成「引擎死了」强杀重启（2026-10 一周内 3 次无故重启的根因）。
# 端口/解析是否正常由 probe 负责，它有连续失败次数的门槛。
core_alive() {
	pid=$(cat $D/pid 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
# 启动完成（进程在 + DNS 端口已监听）：只在刚拉起时等它用
core_ready() {
	core_alive && netstat -lnu 2>/dev/null | awk '{print $4}' | grep -qE "(^|:)$PORT\$"
}
core_stop() {
	kill_hard "$(cat $D/pid 2>/dev/null)"
	killall -9 AdGuardHome 2>/dev/null
	rm -f $D/pid
}
guard_stop() {
	pid=$(cat $D/guard.pid 2>/dev/null)
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	rm -f $D/guard.pid
}
core_launch() {
	genconf
	ulimit -n 4096 2>/dev/null
	( cd $D && export GOMEMLIMIT=100MiB && exec nice -n 5 $BIN -c $CONF -w $WORK --no-check-update >> $D/core.log 2>&1 ) &
	echo $! > $D/pid
	cg_limit keladg "$(cat $D/pid)" 130M 180M
}
rotate_log() {
	sz=$(wc -c 2>/dev/null < $D/core.log); [ "${sz:-0}" -gt 524288 ] || return 0
	tail -n 200 $D/core.log > $D/core.tail && cat $D/core.tail > $D/core.log; rm -f $D/core.tail
}
api() {	# api METHOD PATH [json文件]
	if [ -n "$3" ]; then curl -sf -m 8 -X "$1" -H 'Content-Type: application/json' --data-binary "@$3" "http://$API$2"
	else curl -sf -m 8 -X "$1" "http://$API$2"; fi
}

# ------------------------------------------------------------------ 自检：AdGuardHome 真能解析
# 用路由器自己的主机名（<主机名>.lan，由 dnsmasq 本地应答）——不依赖外网，外网断了不会被误判成 AdGuardHome 有病。
probe() {
	h=$(uci -q get system.@system[0].hostname); [ -n "$h" ] || h=OpenWrt
	( nslookup -port=$PORT -timeout=2 -retry=1 "$h.lan" 127.0.0.1 > $D/probe.out 2>&1 ) & wait $!
	grep -q 'Address' $D/probe.out && ! grep -qi "can't find\|NXDOMAIN\|timed out\|connection refused" $D/probe.out
}

# ------------------------------------------------------------------ 转发规则（fw4 include）
# force_dns=0（默认）：只转发「发给路由器自己」的查询；=1：设备自己配的 DNS（如 8.8.8.8）也被拉回来过滤。
rule_body() {
	loc="fib daddr type local "; [ "$(cfg force_dns)" = "1" ] && loc=""
	echo "iifname { \"br-lan\", \"br-guest\" } meta l4proto { tcp, udp } th dport 53 ${loc}counter redirect to :$PORT comment \"keladg\""
}
nft_ok() {
	{ printf 'table inet kelchk2 {\n chain dstnat { type nat hook prerouting priority -100; policy accept;\n'; cat "$1"; printf '\n }\n}\n'; } > $D/chk.nft
	nft -c -f $D/chk.nft >/dev/null 2>&1; r=$?; rm -f $D/chk.nft; return $r
}
# rules_on：让实际规则收敛到设置（force_dns 变了会替换）；任何一步失败都回到 dnsmasq
rules_on() {
	mkdir -p ${NFT%/*}
	rule_body > $NFT.new
	same=0; [ -f $NFT ] && cmp -s $NFT.new $NFT && same=1
	# 文件一致且防火墙里确实有这条规则才算「已生效」；文件在、规则丢了（被别的重载冲掉）要重新装
	if [ $same = 1 ] && nft_live keladg; then rm -f $NFT.new; return 0; fi
	if ! nft_ok $NFT.new; then rm -f $NFT.new; rules_off "广告过滤没有开启：规则自检未通过，DNS 保持原样"; return 1; fi
	had=0; [ -f $NFT ] && had=1
	mv $NFT.new $NFT
	if fw4 -q reload && nft_live keladg; then
		if [ $same = 1 ]; then LOGK dns_on "广告过滤的转发规则被冲掉了，已自动重新装入"
		elif [ $had = 1 ]; then LOGK dns_on "广告过滤的范围已更新"
		else LOGK dns_on "广告过滤已生效：全家设备的域名查询现在会先经过广告过滤"; fi
		return 0
	fi
	rm -f $NFT; fw4 -q reload
	if nft_live keladg; then
		LOGK info "防火墙重载失败：旧的 DNS 转发规则仍在生效，未恢复原始 DNS"; return 1
	fi
	LOGK dns_off "广告过滤没有开启：防火墙没能加载规则，已回滚，DNS 保持原样"; return 1
}
# 以防火墙里的实际规则为准：reload 失败时文件已删但规则还在，下一轮必须继续撤，直到真的撤干净才算完成
rules_off() {
	had=0; [ -f $NFT ] && had=1; nft_live keladg && had=1
	[ $had = 1 ] || return 0
	rm -f $NFT
	fw4 -q reload; nft_live keladg && fw4 -q reload
	nft_live keladg && return 1
	LOGK dns_off "${1:-广告过滤已暂停，DNS 回到路由器自带解析}"
}

# ------------------------------------------------------------------ 守护
guard() {
	old=$(cat $D/guard.pid 2>/dev/null)
	[ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
	mkdir -p $D; echo $$ > $D/guard.pid
	trap 'rules_off; core_stop; rm -f $D/guard.pid; exit 0' TERM INT HUP
	rules_off; health_note off
	phase starting "正在启动"	# 先写状态：等网络、下载引擎期间页面不该读到上一次留下的「启动失败」
	wait_net 120
	n=0; until fetch; do n=$((n+1)); wait_net 30; nap $((n < 4 ? 20 : 60)); done
	phase starting "正在启动"
	fails=0; bad=0; okst=0; lr=0
	while :; do
		if [ "$(cfg enabled)" != "1" ]; then rules_off "广告过滤已关闭，DNS 回到路由器自带解析"; core_stop; rm -f $D/guard.pid; exit 0; fi
		if ! core_alive; then
			# 运行中的引擎进程没了：记下原因线索（日志最后一行 + 是否被内存限制杀掉），否则事后无从查起
			[ "$okst" -gt 0 ] && LOGK engine_fail "广告过滤引擎进程意外退出（$(grep -h oom_kill /sys/fs/cgroup/keladg/memory.events 2>/dev/null | tr '\n' ' ')；$(tail -n 1 $D/core.log 2>/dev/null | cut -c1-100)），正在重启"
			rules_off; okst=0; bad=0; core_stop
			phase starting "正在启动"
			core_launch
			i=0; while [ $i -lt 40 ] && ! core_ready; do nap 2; i=$((i+1)); done
			if ! core_ready; then
				fails=$((fails+1)); LOGK engine_fail "广告过滤引擎启动失败（第 $fails 次），DNS 保持原样，正在重试"
				phase failed "广告过滤引擎启动失败（第 $fails 次），DNS 保持原样；$(tail -n 1 $D/core.log 2>/dev/null | cut -c1-120)"; core_stop
				nap $((fails < 10 ? fails * 20 : 200)); continue
			fi
			fails=0; LOGK engine_start "广告过滤引擎已启动"
		fi
		phase running "运行中"
		lr=$((lr+1)); [ $((lr % 75)) -eq 0 ] && { rotate_log; conf_persist; }
		if probe; then
			bad=0; okst=$((okst+1)); health_note ok
			[ "$okst" -ge 2 ] && rules_on
		else
			bad=$((bad+1)); okst=0; health_note probe-fail
			# 连续 2 次不应答就撤规则（偶发抖动不撤）；连续 4 次重启引擎
			[ "$bad" -ge 2 ] && rules_off "广告过滤引擎没有应答，已自动恢复到路由器自带 DNS（不影响上网）"
			[ "$bad" -ge 4 ] && { LOGK engine_fail "广告过滤引擎自检连续失败，正在重启（期间 DNS 保持原样）"; core_stop; bad=0; continue; }
		fi
		nap 2
	done
}

# 规则列表的后台任务（kelapi 的 adgJob 启动）：请求体在 $D/fjob.body，结果写 $D/fjob.state。
filter_job() {	# filter_job <操作名> <控制接口路径> <超时秒>
	mkdir $D/fjob.lock 2>/dev/null || return 0
	code=$(curl -s -m "$3" -o $D/fjob.out -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data-binary @$D/fjob.body "http://$API$2" 2>/dev/null)
	if [ "$code" = 200 ]; then echo "ok|$1" > $D/fjob.state
	else echo "fail|$1|$(head -c 160 $D/fjob.out 2>/dev/null | tr '\n|' '  ')" > $D/fjob.state; fi
	rm -f $D/fjob.out $D/fjob.body; rmdir $D/fjob.lock
}

case "$1" in
	guard) guard ;;
	filter-job) shift; filter_job "$@" ;;
	fetch) fetch ;;
	rules-off) rules_off ;;
	core-start) core_launch ;;
	core-stop) guard_stop; core_stop; rm -f $D/phase $D/health ;;
	api) shift; api "$@" ;;
	status)
		st=stopped; core_alive && st=running
		ga=0; gp=$(cat $D/guard.pid 2>/dev/null); [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null && ga=1
		printf '{"core":"%s","rules":%s,"binary":%s,"guard":%s}\n' $st $(nft_live keladg && echo 1 || echo 0) $([ -x $BIN ] && echo 1 || echo 0) $ga
		;;
	*) echo "usage: $0 guard|fetch|rules-off|core-start|core-stop|api|status"; exit 1 ;;
esac
