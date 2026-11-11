# /usr/share/kel/lib.sh —— kelclash（mihomo）与 keladg（AdGuardHome）两个守护共用的函数
# 调用方先设好：D（内存里的状态目录）、TAG（日志标签）。

# 守护事件（给页面看的「发生了什么」）：时间戳|类型|一句话，最多保留 60 条。
# 页面按类型配图标、对重要事件弹一次提示——后台的自动动作在前台必须看得见、说得清。
ev() {
	mkdir -p $D
	printf '%s|%s|%s\n' "$(date +%s)" "$1" "$2" >> $D/events
	[ "$(wc -l < $D/events)" -gt 60 ] && { tail -n 40 $D/events > $D/events.t && cat $D/events.t > $D/events; rm -f $D/events.t; }
}
LOGK() { logger -t $TAG "$2"; echo "$2"; ev "$1" "$2"; }
LOG() { LOGK info "$*"; }

# 可被信号立即打断的 sleep（普通 sleep 会让 trap 拖到睡醒才执行，procd 5 秒等不到就 SIGKILL，规则和内核就残留了）
nap() { sleep "$1" & wait $!; }

# 给页面看的「人话状态」：phase(downloading/starting/running/failed) + 一行说明 / 健康检查结论
phase() { mkdir -p $D; printf '%s\n%s\n' "$1" "$2" > $D/phase; }
health_note() { mkdir -p $D; printf '%s\n' "$1" > $D/health; }

# 转发规则是否真的在防火墙里生效。只看 include 文件会被骗：别的组件重载防火墙、或我们自己的 reload 失败时，文件和实际规则会不一致。
nft_live() { nft list chain inet fw4 dstnat 2>/dev/null | grep -q "$1"; }

# 把进程放进限内存的 cgroup（v2）：超了只杀它自己，不会拖垮路由器。
# 🔴 cgroup v2 要先在根上打开 memory 控制器才有 memory.max；某次开机后根的 subtree_control 是空的，
#    老代码直接 mkdir+写文件，写失败被静默吞掉，内存上限就一直没生效（2026-10-01 发现）。
cg_limit() {	# cg_limit <名字> <pid> <memory.high> <memory.max>
	cg=/sys/fs/cgroup/$1
	grep -qw memory /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || echo +memory > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null
	[ -d $cg ] || mkdir $cg 2>/dev/null
	echo "$3" > $cg/memory.high 2>/dev/null; echo "$4" > $cg/memory.max 2>/dev/null
	echo "$2" > $cg/cgroup.procs 2>/dev/null
	[ -r $cg/memory.max ] && [ "$(cat $cg/memory.max 2>/dev/null)" != max ] && return 0
	LOG "警告：内存上限没能生效（cgroup 内存控制器不可用），只靠 GOMEMLIMIT 约束"; return 1
}

# 结束进程：先 TERM，2 秒内没退（被冻结/卡死的进程要等它醒来才会处理 TERM）就 KILL
kill_hard() {
	[ -n "$1" ] || return 0
	kill "$1" 2>/dev/null
	i=0; while kill -0 "$1" 2>/dev/null && [ $i -lt 2 ]; do nap 1; i=$((i+1)); done
	kill -0 "$1" 2>/dev/null && kill -9 "$1" 2>/dev/null
	return 0
}

# 等网络就绪再干「要联网」的活：有默认路由 + 本机 dnsmasq 能解析；网通了再多等一会儿让 NTP 校时（时间没校准，事件时间戳会是几天前）。
# 最多等 $1 秒（默认 120），到点照样往下走——启动慢也不能卡死守护。
# 🔴 2026-10-05 实测：开机时 DNS/WAN 还没好，下载镜像探速第一轮全是「可用 0 个」，白白浪费几分钟才完全生效。
wait_net() {
	t=${1:-120}; i=0
	while [ $i -lt $t ]; do
		if ip route show default 2>/dev/null | grep -q default && nslookup -timeout=2 -retry=1 www.baidu.com 127.0.0.1 >/dev/null 2>&1; then
			# 开机 10 分钟后不再等（NTP 早就校过了，或者这台机器根本没有 NTP——别每次重启服务都白等 30 秒）
			j=0; while [ $j -lt 30 ] && [ ! -f /tmp/kel-timesync ] && [ "$(cut -d. -f1 /proc/uptime)" -lt 600 ]; do nap 2; j=$((j+2)); done
			return 0
		fi
		nap 3; i=$((i+3))
	done
	return 1
}

# ------------------------------------------------------------------ 程序包下载（只放内存）
# 镜像速度忽快忽慢、随时有挂的，固定分配会被最慢的一段拖住：
#   ① 先并行探测每个镜像的速度（5 秒内），按快慢排序，挂了的丢掉；
#   ② 切成 ~1.2MB 一块，4 个工人「谁做完谁领下一块」（mkdir 抢锁），快镜像自然多干；
#   ③ 每块只接受 HTTP 206 且大小恰好对得上（不支持 Range 的镜像会回整个文件，绝不能拼进去）；失败的块释放，别的工人换镜像再领；
#   ④ 全部到齐后整体校验 sha256，通过才交给调用方。
dl_worker() {	# dl_worker <工人号>
	w=$1; k=0
	while :; do
		i=0; got=""
		while [ $i -lt $NC ]; do
			if [ ! -f $D/parts/done.$i ] && mkdir $D/parts/lock.$i 2>/dev/null; then got=$i; break; fi
			i=$((i+1))
		done
		[ -z "$got" ] && return 0
		start=$((got*CH)); end=$((start+CH-1)); [ $end -ge $size ] && end=$((size-1)); want=$((end-start+1))
		m=$(echo $ORDER | cut -d' ' -f$(( (w+k) % NORD + 1 )))
		u=$(echo "$m" | sed "s#{url}#$url#")
		code=$(curl -sL --connect-timeout 6 --speed-limit 10000 --speed-time 12 -m 150 -r $start-$end -o $D/parts/c$got.tmp -w '%{http_code}' "$u" 2>/dev/null)
		have=$([ -f $D/parts/c$got.tmp ] && wc -c < $D/parts/c$got.tmp); have=${have:-0}	# 先判文件在不在：块下载失败时文件根本没建，直接 wc < 不存在的文件会让 shell 往日志里刷「can't open」
		if [ "$code" = 206 ] && [ "$have" -eq "$want" ]; then
			mv $D/parts/c$got.tmp $D/parts/c$got; touch $D/parts/done.$got
		else
			rm -f $D/parts/c$got.tmp; k=$((k+1))		# 这块失败：换个镜像，块放回池子
		fi
		rmdir $D/parts/lock.$got 2>/dev/null
	done
}

# fetch_pkg <原始URL> <字节数> <sha256> <输出文件> <镜像列表（含 {url} 占位）> <给人看的名字>
# 成功返回 0，输出文件已通过 sha256 校验；失败返回 1（调用方写 phase failed）
fetch_pkg() {
	url=$1; size=$2; sum=$3; out=$4; mirrors=$5; label=$6
	case "$size" in ''|*[!0-9]*|0) return 1;; esac
	rm -rf $D/parts; mkdir -p $D/parts
	phase downloading "正在下载$label"
	# ① 探速
	idx=0; pids=""
	for m in $mirrors; do
		u=$(echo "$m" | sed "s#{url}#$url#")
		( curl -sL --connect-timeout 4 -r 0-131071 -o /dev/null -m 6 -w '%{http_code} %{size_download} %{speed_download}' "$u" > $D/parts/probe.$idx 2>/dev/null ) &
		pids="$pids $!"; idx=$((idx+1))
	done
	for pd in $pids; do wait $pd; done
	ORDER=""; idx=0
	for m in $mirrors; do
		set -- $(cat $D/parts/probe.$idx 2>/dev/null); idx=$((idx+1))
		[ "$1" = 206 ] && [ "${2:-0}" -ge 131072 ] && echo "${3%.*} $m"
	done | sort -rn | cut -d' ' -f2- > $D/parts/rank
	# 最快的镜像占 2 个工人，其余各 1 个（不足 4 个则循环补齐）
	best=$(sed -n 1p $D/parts/rank); ORDER="$best"; for m in $(cat $D/parts/rank); do ORDER="$ORDER $m"; done
	[ -n "$best" ] || ORDER="$mirrors"
	NORD=$(echo $ORDER | wc -w)
	LOG "镜像探速：可用 $(grep -c . $D/parts/rank 2>/dev/null) 个，最快 ${best:-无}"
	CH=1310720; NC=$(( (size + CH - 1) / CH ))
	# ②③ 工人池，一轮没下齐就再来一轮（最多 6 轮，每轮重新排队）
	round=0
	while [ $round -lt 6 ]; do
		round=$((round+1)); pids=""; w=0
		while [ $w -lt 4 ]; do dl_worker $w & pids="$pids $!"; w=$((w+1)); done
		while :; do		# 下载期间定时刷新进度
			alive=0; for pd in $pids; do kill -0 $pd 2>/dev/null && alive=1; done
			n=$(ls $D/parts/done.* 2>/dev/null | wc -l); phase downloading "正在下载$label（$((n*100/NC))%）"
			[ $alive = 0 ] && break; nap 2
		done
		n=$(ls $D/parts/done.* 2>/dev/null | wc -l)
		[ "$n" -ge "$NC" ] || { rmdir $D/parts/lock.* 2>/dev/null; continue; }
		# ④ 拼接 + 校验
		: > $out; i=0; while [ $i -lt $NC ]; do cat $D/parts/c$i >> $out; i=$((i+1)); done
		rm -rf $D/parts
		[ "$(sha256sum $out | cut -d' ' -f1)" = "$sum" ] && return 0
		LOG "校验失败，丢弃重下"; rm -f $out; mkdir -p $D/parts
	done
	rm -rf $D/parts; rm -f $out
	return 1
}
