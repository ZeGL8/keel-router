#!/bin/sh
# /usr/share/kelclash/run.sh —— kelclash（mihomo 代理加速）的全部动作
#   guard / fetch / rules-off / core-stop / reconfig / deadman / api / status
#
# 设计底线：**代理出任何问题都不能让全家断网**。
#   ① 透明代理规则是 fw4 include（/var/run/kelclash/redir.nft，内存盘）——文件不存在 fw4 就忽略，
#      「删文件 + fw4 reload」= 一键直连；规则装上之前先用 nft -c 做语法检查，装不上就回滚。
#   ② 规则只在「内核活着 + 监听在 + 经代理真能出去」时存在；内核有病立即撤，节点有病连续几次才撤（防抖），
#      恢复后要连续通过才重新接管（防来回抖）。
#   ③ 范围按设备 MAC 匹配（不是 IP）：DHCP 换址后不会误伤别的设备。
#   ④ 内核在受限环境里跑：句柄数、内存上限、低优先级、钉在网络软中断之外的 CPU 线程上，
#      代理再吃满也饿不死路由器本身（DNS/DHCP/Wi-Fi 认证）。
#   ⑤ 独立看门狗（kel-watchdog，cron）不依赖本脚本：发现「规则在、守护/内核不在」会自己撤规则。
D=/tmp/kelclash
BIN=$D/mihomo
NFT=/var/run/kelclash/redir.nft
FLASH=/etc/kelclash
REDIR=7892
MIXED=7890
CTL=127.0.0.1:9090

TAG=kelclash
. /usr/share/kel/lib.sh
cfg() { uci -q get kelclash.main.$1; }

lan_ip() { ubus call network.interface.lan status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address'; }

# ------------------------------------------------------------------ 内核程序（只放内存）
fetch() {
	ver=$(cfg version)
	[ -x "$BIN" ] && [ -f "$D/.ok-$ver" ] && return 0
	rm -f $BIN $D/.ok-*
	url="https://github.com/MetaCubeX/mihomo/releases/download/$ver/mihomo-linux-mipsle-softfloat-$ver.gz"
	if fetch_pkg "$url" "$(cfg size)" "$(cfg sha256)" $D/m.gz "$(uci -q get kelclash.main.mirror)" "代理内核" \
		&& gunzip -c $D/m.gz > $BIN && chmod +x $BIN && rm -f $D/m.gz; then
		touch $D/.ok-$ver; LOG "程序就绪 $ver"; return 0
	fi
	rm -f $BIN $D/m.gz
	phase failed "内核下载失败（镜像都连不上），60 秒后自动重试"; LOG "所有下载源都失败"; return 1
}

# 控制接口密钥：首次生成后存 uci；控制接口只监听 127.0.0.1，密钥是第二道锁
secret() {
	s=$(cfg secret)
	if [ -z "$s" ]; then
		s=$(tr -d '-' < /proc/sys/kernel/random/uuid)
		uci set kelclash.main.secret="$s"; uci commit kelclash
	fi
	echo "$s"
}

# api METHOD PATH [json文件]  —— 调 mihomo 控制接口；传输失败或 HTTP 非 2xx 都返回非 0
api() {
	if [ -n "$3" ]; then
		curl -sf -m ${API_TMO:-10} -X "$1" -H "Authorization: Bearer $(cfg secret)" -H 'Content-Type: application/json' --data-binary "@$3" "http://$CTL$2"
	else
		curl -sf -m ${API_TMO:-10} -X "$1" -H "Authorization: Bearer $(cfg secret)" "http://$CTL$2"
	fi
}

# 关掉内核里已有的连接：路由决定（模式/节点/规则/接管范围）变了，已经建好的连接还按旧决定走，设备不会「跟着变」
# （长连接、正在看的视频、挂着的 App 会一直走旧路径，页面上切了也「不精准」）。关掉后客户端自动重连，新连接按新决定走。
# 只影响经过代理内核的连接；内核不在、接口不通就什么也不做。
conn_reset() { core_ready || return 0; API_TMO=4 api DELETE /connections >/dev/null 2>&1; return 0; }

# 把页面上选过的节点恢复回去（重启/开机后 mihomo 默认选第一个）
apply_saved_node() {
	n=$(cfg node); [ -n "$n" ] || { grp_check; return 0; }
	printf '{"name":%s}' "$(json_str "$n")" > $D/sel.json
	api PUT "/proxies/%E4%BB%A3%E7%90%86" $D/sel.json >/dev/null 2>&1
	rm -f $D/sel.json
	grp_check
}

# 主动触发「智能回退」组检测：它是懒检测组，刚启动/久未使用时状态是过期的（会先当成直连）；
# 启动后、以及下结论「已回退直连」之前都先复检一次，避免误报和头几个连接误走直连
grp_check() {
	api GET "/group/%E6%99%BA%E8%83%BD%E5%9B%9E%E9%80%80/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000" >/dev/null 2>&1
	# 服务组里的 url-test：刚建好时还没测过，会先停在名单第一个（可能是坏的），主动测一次让它选出最快的可用节点
	for g in $(for it in $SVC_LIST; do echo "${it#*:}-选择"; done); do
		api GET "/group/$(urlenc "$g")/delay?url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=3000" >/dev/null 2>&1
	done
}

# ------------------------------------------------------------------ 节点选择（页面和守护共用同一条路径）
# 页面上手动点一条节点、页面上点「切到最快节点」、守护进程发现当前节点失效自动切换——全都走 select_proxy，
# 所以 uci 里记的、mihomo 里实际用的、页面上显示的三者永远一致。
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/'; }
urlenc() { printf '%s' "$1" | ucode -e 'import {stdin} from "fs"; let s=stdin.read("all"); let o=""; for (let i=0;i<length(s);i++){let c=ord(s,i); o+=(c>=48&&c<=57||c>=65&&c<=90||c>=97&&c<=122||c==45||c==46||c==95||c==126)?chr(c):sprintf("%%%02X",c);} print(o);'; }
select_proxy() {	# select_proxy <名字>：先让 mihomo 切换，成功后才写 uci；加锁，页面操作和守护自动切换不会同时改
	i=0; while ! mkdir $D/sw.lock 2>/dev/null; do
		i=$((i+1)); [ $i -gt 20 ] && { [ $(( $(date +%s) - $(cat $D/sw.lock/ts 2>/dev/null || echo 0) )) -gt 30 ] && rm -rf $D/sw.lock; [ $i -gt 24 ] && return 1; }
		sleep 1
	done
	date +%s > $D/sw.lock/ts
	printf '{"name":%s}' "$(json_str "$1")" > $D/sel.json
	api PUT "/proxies/%E4%BB%A3%E7%90%86" $D/sel.json >/dev/null 2>&1
	rm -f $D/sel.json
	spn=$(api GET "/proxies/%E4%BB%A3%E7%90%86" | jsonfilter -e '@.now' 2>/dev/null)
	r=1
	if [ "$spn" = "$1" ]; then uci set kelclash.main.node="$1"; uci commit kelclash; conn_reset; r=0; fi
	rm -rf $D/sw.lock
	return $r
}
# best_node：订阅里当前延迟最低且可用的节点，输出「名字<TAB>延迟」
best_node() {
	api GET "/providers/proxies/sub" | ucode -e 'import {stdin} from "fs"; let j=json(stdin.read("all")); let b=null; for (let p in (j?.proxies ?? [])) { let h=p.history ?? []; let d=length(h)?(h[length(h)-1].delay ?? 0):0; if (d>0 && (b==null || d<b.d)) b={n:p.name,d:d}; } if (b) print(b.n+"\t"+b.d);' 2>/dev/null
}
# 自动切换节点（保守版，2026-09-30 加固）——只在「确凿」时才动，宁可不切也不乱切：
#   ① 只看当前手动选的具体节点，且用「国内直连不通」的地址测（gstatic 会直连，测不出节点好坏）
#   ② 连续 4 次不通（约 2 分钟）才算数；网络整体断了（所有节点都不通）不切——切了也没用，只会来回抖
#   ③ 备选节点必须刚刚实测通过；没有就什么都不做（智能回退组自己会兜底）
#   ④ 冷却 10 分钟、每小时最多 3 次；超过就冻结自动切换 1 小时并写一条事件，绝不来回拉锯
autoswitch_check() {
	[ "$(cfg auto_switch)" = "0" ] && { nbad=0; return; }
	[ -d $D/sw.lock ] && return
	cur=$(api GET "/proxies/%E4%BB%A3%E7%90%86" | jsonfilter -e '@.now' 2>/dev/null)
	case "$cur" in ''|智能回退|自动选择|DIRECT) nbad=0; return;; esac
	hu=$(cfg health_urls | awk '{print $1}'); [ -n "$hu" ] || hu="https://www.google.com/generate_204"
	enc=$(printf '%s' "$hu" | sed 's/%/%25/g; s/:/%3A/g; s#/#%2F#g; s/?/%3F/g; s/=/%3D/g; s/&/%26/g')
	api GET /version >/dev/null || return		# 控制接口本身不通≠节点不通，不计数
	r=$(api GET "/providers/proxies/sub/$(urlenc "$cur")/healthcheck?url=$enc&timeout=5000" | jsonfilter -e '@.delay' 2>/dev/null)
	if [ -n "$r" ] && [ "$r" -gt 0 ] 2>/dev/null; then nbad=0; return; fi
	nbad=$((nbad+1)); [ "$nbad" -ge 4 ] || return
	nbad=0
	now=$(date +%s)
	[ $((now - $(cat $D/sw.frozen 2>/dev/null || echo 0))) -lt 3600 ] && return
	[ $((now - $(cat $D/sw.last 2>/dev/null || echo 0))) -lt 600 ] && return
	: > $D/sw.hist.new; for t in $(cat $D/sw.hist 2>/dev/null); do [ $((now - t)) -lt 3600 ] && echo $t >> $D/sw.hist.new; done; mv $D/sw.hist.new $D/sw.hist
	if [ "$(wc -l < $D/sw.hist)" -ge 3 ]; then
		echo $now > $D/sw.frozen; LOGK switch_freeze "自动切换节点 1 小时内已触发 3 次，暂停 1 小时（仍可手动选择节点）"; return
	fi
	# 备选必须现测：先跑一轮全体检测，再取最快的；一条都测不通说明是整体网络问题，不切
	# 整批检测本身失败（超时/接口错）就放弃——否则会读到旧记录里「曾经可用」的节点
	api GET "/providers/proxies/sub/healthcheck" >/dev/null || return
	b=$(best_node); nn=$(echo "$b" | cut -f1); nd=$(echo "$b" | cut -f2)
	[ -n "$nn" ] && [ "$nn" != "$cur" ] || return
	# 检测期间用户可能已手动换了节点：以现在的选择为准，不用旧决定覆盖用户
	[ "$(api GET "/proxies/%E4%BB%A3%E7%90%86" | jsonfilter -e '@.now' 2>/dev/null)" = "$cur" ] || return
	if select_proxy "$nn"; then
		echo $now > $D/sw.last; echo $now >> $D/sw.hist
		LOGK switch "节点「$cur」连续约 2 分钟测不通，已切换到实测可用的「$nn」（${nd}ms）"
	fi
}

# ------------------------------------------------------------------ 订阅缓存（闪存里留一份最后一次好的）
# 开机时订阅站可能连不上（网络刚起来 / 站点故障），有缓存内核照样有节点可用；只在内容变化时才写闪存
# 订阅指纹：只看节点的 服务器:端口 集合——订阅里常带「剩余流量/到期时间」这类每次都变的信息行，
# 按整份文件比的话每 6 小时必写一次闪存、事件里刷屏（2026-10-12 发现）。提取不到（非单行格式）时退回整份比较。
sub_sig() {
	sig=$(sed -n 's/.*server: *\([^,} ]*\).*port: *\([0-9]*\).*/\1:\2/p' $D/sub.yaml | sort -u | md5sum | cut -d' ' -f1)
	[ "$sig" = d41d8cd98f00b204e9800998ecf8427e ] && sig=$(md5sum < $D/sub.yaml | cut -d' ' -f1)
	echo "$sig"
}
sub_restore() {
	[ -s $D/sub.yaml ] && return 0
	[ -s $FLASH/sub.last.gz ] || return 0
	# 指纹必须和 sub_persist 用同一种算法：以前这里记的是整份文件的 md5，和保存时算的对不上，每次开机都白写一次闪存（2026-10-13）
	gunzip -c $FLASH/sub.last.gz > $D/sub.yaml 2>/dev/null && [ -s $D/sub.yaml ] && { sub_sig > $D/sub.md5; LOG "已从闪存恢复上次的订阅缓存"; }
}
sub_persist() {
	[ -s $D/sub.yaml ] || return 0
	if grep -q '^proxies:' $D/sub.yaml; then
		# 全是指向本机回环地址的「公告节点」（机场停用了这类客户端）：不是可用的订阅，绝不能拿它覆盖闪存里上一份好的缓存
		grep 'server:' $D/sub.yaml | grep -qvE 'server: *.?(127\.|localhost|0\.0\.0\.0|::1)' || return 0
	else
		# 链接列表格式（base64 编码的 vless:// 等）：以前只认上面那种格式，这种订阅从来不在闪存留缓存，
		# 开机时订阅站连不上就一个节点都没有（2026-10-30 发现）。解出来能看到真节点（不是 127.0.0.1 公告）才算数
		ucode -e 'import {readfile} from "fs"; let d=b64dec(replace(readfile(ARGV[0]) ?? "", /[\r\n]/g, "")) ?? ""; let ok=false; for (let l in split(d, "\n")) if (match(l, /^[a-z0-9]+:\/\//) && !match(l, /@(127\.|localhost|0\.0\.0\.0)/)) ok=true; exit(ok ? 0 : 1);' $D/sub.yaml 2>/dev/null || return 0
	fi
	new=$(sub_sig)
	[ "$new" = "$(cat $D/sub.md5 2>/dev/null)" ] && return 0
	free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 400 ] || return 0
	mkdir -p $FLASH; gzip -c $D/sub.yaml > $FLASH/sub.last.gz.new && mv $FLASH/sub.last.gz.new $FLASH/sub.last.gz \
		&& { echo "$new" > $D/sub.md5; LOG "订阅缓存已保存到闪存（重启后即使订阅站连不上也有节点）"; }
}

# ------------------------------------------------------------------ IP 地址库（判断「国内 / 国外」用）
# 以前交给内核自己下载，而内核只认一个地址：那个镜像一出问题（2026-10-24 ghfast.top 回 403「Forbidden by black list」，
# 只写下 24 字节），内核加载失败、每次重试都失败，代理整个起不来。现在由这里按多个下载源依次取、校验完整才用，
# 并在闪存留一份（约 300KB）：开机时所有下载源都连不上也有得用。
MMDB_SRC="https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb https://fastly.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb https://gh-proxy.com/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb https://ghproxy.net/https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country-lite.mmdb"
mmdb_ok() { [ "$(wc -c 2>/dev/null < "$1" || echo 0)" -gt 100000 ] && tail -c 20000 "$1" | grep -q "MaxMind.com"; }	# 地址库文件末尾的元数据里有这个标记
mmdb_ready() {
	mmdb_ok $D/geoip.metadb && return 0
	rm -f $D/geoip.metadb
	[ -s $FLASH/geoip.metadb.gz ] && gunzip -c $FLASH/geoip.metadb.gz > $D/geoip.metadb 2>/dev/null && mmdb_ok $D/geoip.metadb && return 0
	for u in $MMDB_SRC; do
		curl -sL -m 40 --max-filesize 3000000 -o $D/geoip.metadb.new "$u" 2>/dev/null
		mmdb_ok $D/geoip.metadb.new || continue
		mv $D/geoip.metadb.new $D/geoip.metadb
		free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 1200 ] && mkdir -p $FLASH && gzip -c $D/geoip.metadb > $FLASH/geoip.metadb.gz
		LOG "IP 地址库就绪（来源 ${u%%/gh/*}…）"; return 0
	done
	rm -f $D/geoip.metadb $D/geoip.metadb.new; return 1
}

# ------------------------------------------------------------------ 配置生成
# ------------------------------------------------------------------ 社区规则集订阅（MetaCubeX/meta-rules-dat，社区维护、每天更新）
# 「哪些网站该走代理」不再靠我们自己判断，而是订阅社区维护的规则集（mrs 二进制格式，最大的也只有几十 KB）。
# 🔴 规则文件由本脚本下载并做基本校验，只有确实存在的才写进配置——下载失败绝不影响内核启动（mihomo 自己下载失败会拒绝启动）。
RULEDIR=$D/rules
RULESETS="ai:category-ai-!cn google:google youtube:youtube netflix:netflix disney:disney spotify:spotify telegram:telegram twitter:twitter github:github gfw:gfw"
RMIRRORS="https://cdn.jsdelivr.net https://fastly.jsdelivr.net https://gcore.jsdelivr.net"
rules_restore() {
	[ -d $RULEDIR ] && [ -n "$(ls $RULEDIR 2>/dev/null)" ] && return 0
	[ -s $FLASH/rules.tgz ] || return 0
	mkdir -p $RULEDIR; tar -xzf $FLASH/rules.tgz -C $RULEDIR 2>/dev/null
}
# 返回 0 = 有文件更新
rules_sync() {
	mkdir -p $RULEDIR; chg=1
	for it in $RULESETS; do
		n=${it%%:*}; f=${it#*:}; fe=$(printf '%s' "$f" | sed 's/!/%21/g')
		for m in $RMIRRORS; do
			curl -sL -m 25 --max-filesize 600000 -o $RULEDIR/$n.new "$m/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/$fe.mrs" 2>/dev/null
			sz=$(wc -c 2>/dev/null < $RULEDIR/$n.new); [ "${sz:-0}" -gt 100 ] && ! head -c 20 $RULEDIR/$n.new | grep -qi '<html\|<!doc' && break
			rm -f $RULEDIR/$n.new
		done
		if [ -s $RULEDIR/$n.new ]; then
			if cmp -s $RULEDIR/$n.new $RULEDIR/$n.mrs 2>/dev/null; then rm -f $RULEDIR/$n.new; else mv $RULEDIR/$n.new $RULEDIR/$n.mrs; chg=0; fi
		fi
	done
	date +%s > $D/rules.ts
	if [ $chg = 0 ]; then
		free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')
		[ "${free:-0}" -gt 600 ] && tar -czf $FLASH/rules.tgz -C $RULEDIR $(cd $RULEDIR && ls *.mrs) 2>/dev/null
	fi
	return $chg
}

# ------------------------------------------------------------------ 按服务选节点（每个服务一个策略组）
# 服务清单：<键>:<策略组名>。键对应 uci svc_<键>；新增服务只改这里和下面两个映射函数（页面/后端各有一份同名清单）。
SVC_LIST="ai:AI google:Google media:流媒体 telegram:Telegram twitter:X github:GitHub"
# 订阅里不是节点的信息条目（按名字排除）：内核的 exclude-filter 和 sub_names 共用这一份
SUB_EXCL='官网|网址|域名|状态|余额|到期|剩余|流量|套餐|重置|订阅|欠费|账户|账号|过期|公告|客服|防失联|续费|购买|expire|traffic|remaining|balance|website|renew|account'
# 规则集 -> 服务键（不属于任何服务的规则集走「代理」）。AI 规则集排在 google 之前，Gemini 等 Google 的 AI 域名归 AI。
svc_of_ruleset() {
	case "$1" in ai) echo ai;; google|youtube) echo google;; netflix|disney|spotify) echo media;; telegram) echo telegram;; twitter) echo twitter;; github) echo github;; esac
}
# 服务键 -> 内置域名兜底规则里属于它的域名（sed 基本正则的或表达式）
svc_domains() {
	case "$1" in
		ai) echo 'openai\.com\|chatgpt\.com\|oaistatic\.com\|oaiusercontent\.com\|anthropic\.com\|claude\.ai';;
		google) echo 'google\.com\|googleapis\.com\|gstatic\.com\|googlevideo\.com\|ggpht\.com\|youtube\.com\|ytimg\.com';;
		media) echo 'netflix\.com\|nflxvideo\.net\|nflximg\.net\|nflxso\.net\|disneyplus\.com\|disney-plus\.net\|bamgrid\.com\|hulu\.com\|primevideo\.com\|spotify\.com';;
		telegram) echo 'telegram\.org\|t\.me';;
		twitter) echo 'twitter\.com\|x\.com\|twimg\.com';;
		github) echo 'github\.com\|githubusercontent\.com';;
	esac
}
# uci svc_<键>：
#   follow（默认）             —— 沿用「代理」组（全局选中的节点/智能回退）
#   region:美国,日本           —— 只在这些地区的节点里自动选延迟最低的（url-test，filter 按节点名匹配）
#   node:<节点名>              —— 固定用这一个节点
# 🔴 指定的地区/节点在订阅里找不到时退回 follow 并记事件——空的 filter 会让 mihomo 拒绝整份配置。
# 正则用 ERE/RE2 都认的写法（不用 \b），这样同一份既拿来 grep 校验，也写进配置给 mihomo。
region_re() {
	case "$1" in
		美国) echo '美国|🇺🇸|(^|[^A-Za-z])(US|USA)([^A-Za-z]|$)';;
		日本) echo '日本|🇯🇵|(^|[^A-Za-z])JP([^A-Za-z]|$)';;
		新加坡) echo '新加坡|🇸🇬|(^|[^A-Za-z])(SG|Singapore)([^A-Za-z]|$)';;
		香港) echo '香港|🇭🇰|(^|[^A-Za-z])HK([^A-Za-z]|$)';;
		台湾) echo '台湾|🇹🇼|(^|[^A-Za-z])TW([^A-Za-z]|$)';;
		韩国) echo '韩国|🇰🇷|(^|[^A-Za-z])KR([^A-Za-z]|$)';;
		英国) echo '英国|🇬🇧|(^|[^A-Za-z])(UK|GB)([^A-Za-z]|$)';;
		德国) echo '德国|🇩🇪|(^|[^A-Za-z])DE([^A-Za-z]|$)';;
	esac
}
# 订阅里的节点名，一行一个（已去掉「官网/剩余流量」这类信息条目）。
# 内核在跑就问内核（它解析过了，任何订阅格式都认）；没在跑（冷启动）才自己从文件里取。
# 🔴 以前直接在整份订阅文件里找「美国 / US」这类字样：订阅是完整配置时，密码、域名、规则里碰巧带这些字母也算数，
#    而内核只按节点名筛——两边对不上时组里一个节点都没有，这个服务就悄悄走了直连；不是 Clash 格式的订阅则永远匹配不上（2026-10-13）。
sub_names() {
	if core_alive; then
		ns=$(API_TMO=6 api GET "/providers/proxies/sub" 2>/dev/null | ucode -e 'import {stdin} from "fs"; let j=json(stdin.read("all")); for (let p in (j?.proxies ?? [])) print(p.name, "\n");' 2>/dev/null)
		[ -n "$ns" ] && { echo "$ns"; return 0; }
	fi
	[ -s $D/sub.yaml ] || return 0
	sed -n '/^proxies:/,/^[A-Za-z]/p' $D/sub.yaml | sed -n "s/^[ \t]*-[ \t]*{\{0,1\}[ \t]*[\"']\{0,1\}name[\"']\{0,1\}[ \t]*:[ \t]*//p" \
		| sed "s/^[\"']\([^\"']*\)[\"'].*/\1/; s/[ \t]*[,}].*//" | grep -viE "$SUB_EXCL"
}

# 服务组一律 lazy（只有真有流量走它时才定时检测）、间隔放宽：6 个服务都指定地区时，非 lazy 的组会让 MIPS 内核
# 一直在测速，控制接口变得很慢，页面跟着卡（2026-10-13）。刚建好时的第一次检测由 grp_check 主动触发。
# 服务组外面再套一层 fallback：指定的地区/节点全部不可用时自动退回「代理」组（它自带智能回退），不会因为选的地区挂了就整个服务不通
svc_fallback() {
	printf "  - { name: %s, type: fallback, proxies: [%s-选择, 代理], url: \"%s\", interval: 30, timeout: 3000, max-failed-times: 2, lazy: true }\n" "$1" "$1" "$2" >> $D/config.yaml
}
# svc_group <组名> <uci 值>：需要时往 config.yaml 追加一个组，stdout 输出规则该指向的组名（组不成立就是「代理」）
svc_group() {
	g=$1; v=$2; purl="https://www.gstatic.com/generate_204"
	case "$v" in
		region:*)
			re=""; for r in $(echo "${v#region:}" | tr ',' ' '); do x=$(region_re "$r"); [ -n "$x" ] && re="${re:+$re|}$x"; done
			if [ -n "$re" ] && echo "$SUBN" | grep -qiE "$re"; then
				printf "  - { name: %s-选择, type: url-test, use: [sub], filter: '(?i)%s', url: \"%s\", interval: 120, tolerance: 80, timeout: 4000, max-failed-times: 2, lazy: true }\n" "$g" "$re" "$purl" >> $D/config.yaml
				svc_fallback "$g" "$purl"; echo "$g"; return 0
			fi
			[ -n "$SUBN" ] && ev info "「$g」指定的地区（${v#region:}）在当前订阅里没有节点，已退回跟随「代理」组"
			;;
		node:*)
			n=${v#node:}
			if [ -n "$n" ] && echo "$SUBN" | grep -qxF -- "$n"; then
				q=$(printf '%s' "$n" | sed 's/[][\.*^$(){}?+|]/\\&/g')
				printf "  - { name: %s-选择, type: select, use: [sub], filter: '^%s\$' }\n" "$g" "$q" >> $D/config.yaml
				svc_fallback "$g" "$purl"; echo "$g"; return 0
			fi
			[ -n "$SUBN" ] && ev info "「$g」指定的节点「$n」在当前订阅里不存在，已退回跟随「代理」组"
			;;
	esac
	echo 代理
}

genconf() {
	mode=$(cfg mode); sub=$(cfg sub_url); ua=$(cfg ua); sec=$(secret)
	[ -n "$mode" ] || mode=rule
	[ -n "$ua" ] || ua=clash.meta
	purl="https://www.gstatic.com/generate_204"
	cat > $D/config.yaml <<EOC
redir-port: $REDIR
mixed-port: $MIXED
allow-lan: true
bind-address: "*"
# IPv6 客户端的源地址是运营商委派前缀里的公网地址（会变），不能写死；WAN 侧入站由 fw4 的 wan 区拒绝，这里放开 ::/0 不会暴露到外网
lan-allowed-ips: [127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, '::/0']
mode: $mode
log-level: info
ipv6: true
external-controller: $CTL
secret: "$sec"
unified-delay: true
tcp-concurrent: true
geodata-mode: false
geo-auto-update: false
geox-url:
  mmdb: "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country-lite.mmdb"
sniffer:
  enable: true
  override-destination: true
  sniff:
    HTTP: { ports: [80, 8080-8880] }
    TLS: { ports: [443, 8443] }
  skip-domain:
    - "Mijia Cloud"
    - "+.push.apple.com"
    - "dlg.io.mi.com"
dns:
  enable: true
  ipv6: false
  nameserver: [223.5.5.5, 119.29.29.29]
  # 🔴 智能分流的地区限制问题（2026-09-30）：国内 DNS 解析国外站常返回「国内就近节点」的 IP，被 GEOIP,CN 判成国内而直连，
  #    结果 Netflix/OpenAI/检测站这类有地区限制的站点看起来「不在国外」。加一路国外 DNS（经代理节点解析）：
  #    国内 DNS 给出非国内 IP 时以它为准；国内 IP 但域名其实是国外服务时由下面的域名规则先一步走代理。
  fallback: [tls://8.8.8.8, tls://1.1.1.1]
  fallback-filter: { geoip: true, geoip-code: CN, ipcidr: [240.0.0.0/4, 0.0.0.0/32] }
EOC
	if [ -n "$sub" ]; then
		cat >> $D/config.yaml <<EOC
proxy-providers:
  sub:
    type: http
    url: "$sub"
    path: ./sub.yaml
    interval: 21600
    header:
      User-Agent: ["$ua"]
    exclude-filter: "(?i)($SUB_EXCL)"
    health-check: { enable: true, url: "$purl", interval: 300 }
proxy-groups:
  - { name: 自动选择, type: url-test, use: [sub], url: "$purl", interval: 60, tolerance: 80, timeout: 4000, max-failed-times: 2, lazy: false }
EOC
		# 智能回退：优选节点全部不可用时，该连接自动改走直连（不再卡死）；节点恢复后自动切回
		cat >> $D/config.yaml <<EOC
  - { name: 智能回退, type: fallback, proxies: [自动选择, DIRECT], url: "$purl", interval: 10, timeout: 3000, max-failed-times: 2, lazy: false }
  - { name: 代理, type: select, proxies: [智能回退, 自动选择], use: [sub] }
EOC
	else
		# 没填订阅：只有直连，保证配置合法、mihomo 能起来（用于验证转发链路）
		cat >> $D/config.yaml <<EOC
proxy-groups:
  - { name: 代理, type: select, proxies: [DIRECT] }
EOC
	fi
	SUBN=""; [ -n "$sub" ] && SUBN=$(sub_names)
	for it in $SVC_LIST; do
		k=${it%%:*}; g=代理
		[ -n "$sub" ] && g=$(svc_group "${it#*:}" "$(cfg svc_$k)")
		eval "G_$k=\$g"
	done
	# 🔴 「全部代理」模式：mihomo 全局模式走内置的 GLOBAL 组，默认选的是 DIRECT——不显式定义的话
	#    「全部代理」实际是「全部直连」，国外站全部 i/o timeout（2026-09-29 用户实测踩到）。
	#    定义同名 GLOBAL 组，默认指向「代理」组（含智能回退/节点选择）。
	cat >> $D/config.yaml <<EOC
  - { name: GLOBAL, type: select, proxies: [代理, DIRECT] }
EOC
	rp=""
	for it in $RULESETS; do
		nm=${it%%:*}
		[ -s $RULEDIR/$nm.mrs ] && rp="$rp $nm"
	done
	if [ -n "$rp" ]; then
		echo "rule-providers:" >> $D/config.yaml
		for nm in $rp; do echo "  rs_$nm: { type: file, behavior: domain, format: mrs, path: $RULEDIR/$nm.mrs }" >> $D/config.yaml
		done
	fi
	cat >> $D/config.yaml <<EOC
rules:
EOC
	[ -f $FLASH/rules.txt ] && grep -E '^[A-Z-]+,' $FLASH/rules.txt | sed 's/^/  - /' >> $D/config.yaml
	cat >> $D/config.yaml <<'EOC'
  # 局域网地址不解析；国内 IP 必须允许解析域名——手动代理口收到的是域名，不解析就匹配不上「国内」，会白白走代理节点
  - GEOIP,LAN,DIRECT,no-resolve
EOC
	for nm in $rp; do
		k=$(svc_of_ruleset $nm); g=代理; [ -n "$k" ] && eval "g=\$G_$k"
		echo "  - RULE-SET,rs_$nm,$g" >> $D/config.yaml
	done
	cat >> $D/config.yaml <<'EOC'
  # 有地区限制/常被「就近解析」误判成国内的服务：按域名直接走代理，不依赖 IP 归属地判断（智能分流的关键）
  - DOMAIN-SUFFIX,google.com,代理
  - DOMAIN-SUFFIX,googleapis.com,代理
  - DOMAIN-SUFFIX,gstatic.com,代理
  - DOMAIN-SUFFIX,googlevideo.com,代理
  - DOMAIN-SUFFIX,ggpht.com,代理
  - DOMAIN-SUFFIX,youtube.com,代理
  - DOMAIN-SUFFIX,ytimg.com,代理
  - DOMAIN-SUFFIX,openai.com,代理
  - DOMAIN-SUFFIX,chatgpt.com,代理
  - DOMAIN-SUFFIX,oaistatic.com,代理
  - DOMAIN-SUFFIX,oaiusercontent.com,代理
  - DOMAIN-SUFFIX,anthropic.com,代理
  - DOMAIN-SUFFIX,claude.ai,代理
  - DOMAIN-SUFFIX,netflix.com,代理
  - DOMAIN-SUFFIX,nflxvideo.net,代理
  - DOMAIN-SUFFIX,nflximg.net,代理
  - DOMAIN-SUFFIX,nflxso.net,代理
  - DOMAIN-SUFFIX,disneyplus.com,代理
  - DOMAIN-SUFFIX,disney-plus.net,代理
  - DOMAIN-SUFFIX,bamgrid.com,代理
  - DOMAIN-SUFFIX,hulu.com,代理
  - DOMAIN-SUFFIX,primevideo.com,代理
  - DOMAIN-SUFFIX,spotify.com,代理
  - DOMAIN-SUFFIX,twitter.com,代理
  - DOMAIN-SUFFIX,x.com,代理
  - DOMAIN-SUFFIX,twimg.com,代理
  - DOMAIN-SUFFIX,facebook.com,代理
  - DOMAIN-SUFFIX,fbcdn.net,代理
  - DOMAIN-SUFFIX,instagram.com,代理
  - DOMAIN-SUFFIX,whatsapp.com,代理
  - DOMAIN-SUFFIX,telegram.org,代理
  - DOMAIN-SUFFIX,t.me,代理
  - DOMAIN-SUFFIX,discord.com,代理
  - DOMAIN-SUFFIX,discordapp.com,代理
  - DOMAIN-SUFFIX,github.com,代理
  - DOMAIN-SUFFIX,githubusercontent.com,代理
  - DOMAIN-SUFFIX,wikipedia.org,代理
  - DOMAIN-SUFFIX,reddit.com,代理
  - DOMAIN-SUFFIX,medium.com,代理
  - DOMAIN-SUFFIX,twitch.tv,代理
  - DOMAIN-SUFFIX,cloudflare.com,代理
  - DOMAIN-SUFFIX,ipinfo.io,代理
  - DOMAIN-SUFFIX,ip.sb,代理
  - DOMAIN-SUFFIX,ipify.org,代理
  - DOMAIN-SUFFIX,ifconfig.me,代理
  - DOMAIN-SUFFIX,browserleaks.com,代理
  - DOMAIN-SUFFIX,whoer.net,代理
  - DOMAIN-SUFFIX,ipleak.net,代理
  - DOMAIN-SUFFIX,fast.com,代理
  - DOMAIN-SUFFIX,speedtest.net,代理
  - GEOIP,CN,DIRECT
  - MATCH,代理
EOC
	# 内置域名兜底规则里属于某个服务的，改指向它的组（组不成立时它们就是「代理」，不用改）
	for it in $SVC_LIST; do
		k=${it%%:*}; eval "g=\$G_$k"
		[ "$g" = 代理 ] || sed -i "s/^\(  - DOMAIN-SUFFIX,\($(svc_domains $k)\),\)代理$/\1$g/" $D/config.yaml
	done
}

# 配置自检：不通过就不启动/不热重载（防止坏配置让内核崩溃循环）
conf_test() {
	t=""; command -v timeout >/dev/null 2>&1 && t="timeout 90"
	out=$($t $BIN -t -d $D -f $D/config.yaml 2>&1) && return 0
	CONF_ERR=$(echo "$out" | grep -i -E "error|fatal|invalid|unmarshal" | tail -n 1 | sed 's/.*msg=//' | cut -c1-140)
	[ -n "$CONF_ERR" ] || CONF_ERR=$(echo "$out" | tail -n 1 | cut -c1-140)
	return 1
}

# ------------------------------------------------------------------ 透明代理规则（fw4 include）
# 范围：uci list only_mac（按 MAC）；空 = 全部局域网设备。
# 🔴 配了范围却一个都解析不出来时必须拒绝安装——否则「仅本设备」会悄悄变成「全家」。
# ------------------------------------------------------------------ 国内 IP 在内核层面直连（不经过代理内核）
# 「智能分流」下国内网站本来就走直连，但以前要先进代理内核、由它判断再直连出去——代理内核一卡（节点全挂时大量连接堆积、
# 内存或 CPU 吃紧），国内网站也跟着慢或打不开。把国内 IP 段并进转发规则的「不转」清单：发往国内的连接在内核里直接放行，
# 根本不经过代理，代理出任何问题都碰不到它们。清单按多个来源取、校验后才用，闪存留一份，每天更新一次。
# 只在「智能分流」模式下生效：「全部代理」是用户要求全部走代理，不绕过。
# 🔴 IPv6 也必须有（2026-11-10 补）：以前只有 IPv4 清单，国内 IPv6 连接也被转进代理内核、由路由器「代为」直连出去——
#    对方看到的来源地址就成了路由器的。飞牛 NAS 的 DDNS 靠访问 ipv6.fnnas.com 看自己的公网地址，结果把域名更新成了
#    路由器的地址，外网访问 NAS 全部失败。凡是要「对方看到我真实地址」的（DDNS、按 IP 校验的服务、P2P）都会这样。
CN_SRC="https://cdn.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt https://fastly.jsdelivr.net/gh/17mon/china_ip_list@master/china_ip_list.txt https://gh-proxy.com/https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt https://cdn.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china.txt"
CN6_SRC="https://cdn.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china6.txt https://fastly.jsdelivr.net/gh/gaoyifan/china-operator-ip@ip-lists/china6.txt https://gh-proxy.com/https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china6.txt"
CN4=$D/cn4.txt
CN6=$D/cn6.txt
cn6_ok() { [ "$(grep -cE '^[0-9a-fA-F:]+/[0-9]+$' "$1" 2>/dev/null)" -gt 1000 ] 2>/dev/null; }
cn_ok() { [ "$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$1" 2>/dev/null)" -gt 3000 ] 2>/dev/null; }	# 文件还不存在时计数为空，不加 2>/dev/null 会往日志刷「out of range」
cn_restore() {
	cn_ok $CN4 || { [ -s $FLASH/cn4.gz ] && gunzip -c $FLASH/cn4.gz > $CN4 2>/dev/null; }
	cn6_ok $CN6 || { [ -s $FLASH/cn6.gz ] && gunzip -c $FLASH/cn6.gz > $CN6 2>/dev/null; }
	cn_ok $CN4 && cn6_ok $CN6
}
cn_sync() { r=1; cn4_sync && r=0; cn6_sync && r=0; return $r; }	# 返回 0 = 有一份清单有变化
cn6_sync() {
	for u in $CN6_SRC; do
		curl -sL -m 30 --max-filesize 2000000 -o $CN6.new "$u" 2>/dev/null
		cn6_ok $CN6.new || continue
		grep -E '^[0-9a-fA-F:]+/[0-9]+$' $CN6.new > $CN6.clean; rm -f $CN6.new
		if cmp -s $CN6.clean $CN6; then rm -f $CN6.clean; return 1; fi
		mv $CN6.clean $CN6; rm -f $D/cn.off
		free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 1200 ] && mkdir -p $FLASH && gzip -c $CN6 > $FLASH/cn6.gz
		LOG "国内 IPv6 清单已更新（$(wc -l < $CN6) 段），国内 IPv6 站点在内核层面直连"; return 0
	done
	rm -f $CN6.new $CN6.clean; return 1
}
cn4_sync() {	# 返回 0 = 清单有变化
	for u in $CN_SRC; do
		curl -sL -m 30 --max-filesize 2000000 -o $CN4.new "$u" 2>/dev/null
		cn_ok $CN4.new || continue
		grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' $CN4.new > $CN4.clean; rm -f $CN4.new
		if cmp -s $CN4.clean $CN4; then rm -f $CN4.clean; return 1; fi
		mv $CN4.clean $CN4; rm -f $D/cn.off
		free=$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'); [ "${free:-0}" -gt 1200 ] && mkdir -p $FLASH && gzip -c $CN4 > $FLASH/cn4.gz
		LOG "国内 IP 清单已更新（$(wc -l < $CN4) 段），国内网站在内核层面直连"; return 0
	done
	rm -f $CN4.new $CN4.clean; return 1
}
# 国内段放在命名集合 kel_cn4 里（由防火墙 include kelclash_cn 在表级装入），规则只引用它。
# 🔴 不能把几千段直接写进规则：同一张表里只要有条规则带着大的内联集合，列这张表里任何一条链都要把它整个解析一遍——
#    实测每次 nft list chain 从 20ms 变成 370–510ms，设备列表、守护每轮的自检、看门狗、LuCI 全被拖慢（2026-10-30 发现）。
#    命名集合只有直接列集合或整张表时才读元素。
CNSET=/var/run/kelclash/cn.nft
# 规则里引用国内集合的那一段；不在智能分流模式、清单不可用、曾经装不上、或 include 没注册时为空（规则照常、只是不绕过）
cn_part() {
	[ "$(cfg mode)" = rule ] && [ ! -f $D/cn.off ] && uci -q get firewall.kelclash_cn >/dev/null && cn_ok $CN4 || return 0
	printf 'ip daddr != @kel_cn4 '
}
cn6_part() {
	[ "$(cfg mode)" = rule ] && [ ! -f $D/cn.off ] && uci -q get firewall.kelclash_cn >/dev/null && cn6_ok $CN6 || return 0
	printf 'ip6 daddr != @kel_cn6 '
}
cn_set() {
	cn_ok $CN4 && printf 'set kel_cn4 {\n\ttype ipv4_addr\n\tflags interval\n\tauto-merge\n\telements = { %s }\n}\n' "$(tr '\n' ',' < $CN4 | sed 's/,$//; s/,/, /g')"
	cn6_ok $CN6 && printf 'set kel_cn6 {\n\ttype ipv6_addr\n\tflags interval\n\tauto-merge\n\telements = { %s }\n}\n' "$(tr '\n' ',' < $CN6 | sed 's/,$//; s/,/, /g')"
	return 0
}

# ------------------------------------------------------------------ QUIC（UDP 443）拦截
# 透明代理的 redirect 只处理 TCP，UDP 不经过代理。用 HTTP/3 的 App（浏览器访问 Google/YouTube/Facebook/Cloudflare 的站点、
# 各种国外 App）会走 UDP 443 直连国外：被封锁时要等好几秒才回落到 TCP（设备「反应缓慢」），没被封时就悄悄绕过了代理。
# 对策（路由器通行做法）：用 ICMP「端口不可达」立刻拒绝 UDP 443，客户端马上回落到 TCP，TCP 才会被转入代理。
# 只拒绝「应该走代理」的目的地：智能分流下国内地址（内核直连集合）的 QUIC 照常放行，全部代理下不放行任何公网地址；
# 直连模式、用户选了「放行」、接管范围外的设备都不拦。只在 UDP 443 这一个端口上动手，其他 UDP（游戏/语音/VPN）不受影响。
QUICNFT=/var/run/kelclash/quic.nft
quic_body() {
	[ "$(cfg quic)" = allow ] && return 0
	[ "$(cfg mode)" = direct ] && return 0
	sel=$(scope_sel) || return 0
	[ -n "$sel" ] && sel="$sel "
	cn=""; [ -s $CNSET ] && cn=$(cn_part)
	cn6=""; grep -q kel_cn6 $CNSET 2>/dev/null && cn6=$(cn6_part)
	echo "iifname \"br-lan\" ${sel}udp dport 443 ip daddr != { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } ${cn}counter reject comment \"kelclash-quic\""
	[ "$(cfg ipv6)" = direct ] || echo "iifname \"br-lan\" ${sel}udp dport 443 ip6 daddr != { ::1/128, fc00::/7, fe80::/10, ff00::/8 } ${cn6}counter reject comment \"kelclash-quic6\""
}
# 放进临时表的 filter 链里做语法检查（不生效）。一份坏的拦截规则会让之后每一次防火墙重载都失败，所以通不过就不装
quic_ok() {
	{ printf 'table inet kelchk {\n'; cat $CNSET 2>/dev/null; printf ' chain forward { type filter hook forward priority 0; policy accept;\n'; cat "$1"; printf '\n }\n}\n'; } > $D/chk.nft
	nft -c -f $D/chk.nft >/dev/null 2>&1; r=$?; rm -f $D/chk.nft; return $r
}
# quic_sync：让 QUIC 拦截收敛到「按当前设置应有的」。只在透明代理规则已生效时才有；任何一步不对就不装（QUIC 放行，不影响上网）
quic_sync() {
	mkdir -p ${NFT%/*}
	quic_body > $QUICNFT.new 2>/dev/null
	if [ -s $QUICNFT.new ] && [ -f $NFT ] && nft_live kelclash; then
		cmp -s $QUICNFT.new $QUICNFT 2>/dev/null && { rm -f $QUICNFT.new; return 1; }
		quic_ok $QUICNFT.new || { rm -f $QUICNFT.new; [ -f $QUICNFT ] && { rm -f $QUICNFT; fw4 -q reload; }; LOG "QUIC 拦截规则自检未通过，这次不装（QUIC 放行，不影响上网）"; return 1; }
		mv $QUICNFT.new $QUICNFT
		fw4 -q reload && return 0
		rm -f $QUICNFT; fw4 -q reload; LOG "QUIC 拦截规则没能装进防火墙，已撤销"; return 1
	fi
	rm -f $QUICNFT.new
	[ -f $QUICNFT ] || return 1
	rm -f $QUICNFT; fw4 -q reload; return 0
}

# 接管范围：输出 nft 的源设备匹配（空 = 全部局域网设备）；配了范围却一个有效 MAC 都没有就返回 1（调用方必须拒绝安装）
scope_sel() {
	raw=$(uci -q get kelclash.main.only_mac)
	macs=$(echo "$raw" | tr ' ' '\n' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | tr 'A-F' 'a-f' | tr '\n' ',' | sed 's/,$//')
	[ -n "$raw" ] && [ -z "$macs" ] && return 1
	[ -n "$macs" ] && printf 'ether saddr { %s }' "$macs"
	return 0
}

rule_body() {
	sel=$(scope_sel) || return 1
	[ -n "$sel" ] && sel="$sel "
	# 目的端口 53 不转：明文 DNS 归广告过滤接管（它的规则在这条后面，不排除的话走 TCP 的 DNS 会被代理抢走、绕过过滤）
	echo "iifname \"br-lan\" ${sel}tcp dport != 53 ip daddr != { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/3 } $(cn_part)counter redirect to :$REDIR comment \"kelclash\""
	# 🔴 IPv6 也要接管（2026-10-01）：宽带（PPPoE）带来 IPv6 之后，claude.ai 等站点有 AAAA 记录，设备优先走 IPv6 直连出去——
	#    被封/被识别成国内 IP，而 IPv4 那条线却在走代理，「无论规则分流还是全部代理 Claude 都有问题」。
	#    本机/ULA(fc00::/7)/链路本地/组播不转。
	# IPv6 开关（uci ipv6）：proxy（默认）= 接管；direct = 不接管，设备的 IPv6 直连（有地区限制的服务会看到国内出口）
	[ "$(cfg ipv6)" = direct ] || echo "iifname \"br-lan\" ${sel}tcp dport != 53 ip6 daddr != { ::1/128, fc00::/7, fe80::/10, ff00::/8 } $(cn6_part)counter redirect to :$REDIR comment \"kelclash6\""
}

# 把规则体（连同它要引用的国内集合）放进一张临时表里做语法检查（不生效）
nft_ok() {
	s=$CNSET; [ -f $CNSET.new ] && s=$CNSET.new
	{ printf 'table inet kelchk {\n'; cat $s 2>/dev/null; printf ' chain dstnat { type nat hook prerouting priority -100; policy accept;\n'; cat "$1"; printf '\n }\n}\n'; } > $D/chk.nft
	nft -c -f $D/chk.nft >/dev/null 2>&1; r=$?; rm -f $D/chk.nft; return $r
}

# rules_on：让「实际生效的规则」收敛到「按当前设置应有的规则」。
# 每轮都会调用：规则一致就什么都不做；设置里的接管范围变了（全家↔指定设备）就替换并核对；任何一步失败都回到直连。
rules_on() {
	mkdir -p ${NFT%/*}
	if ! rule_body > $NFT.new; then rm -f $NFT.new; rules_off "透明代理未启用：接管设备（MAC）无效，为安全起见保持直连"; return 1; fi
	# 国内集合只在清单比已装的新时才重写（每轮重生成 100 多 KB 太费）；busybox 的 -nt 遇到不存在的文件为假，所以另判 -s
	newset=0; rm -f $CNSET.new
	if { [ -n "$(cn_part)" ] || [ -n "$(cn6_part)" ]; } && { [ ! -s $CNSET ] || [ $CN4 -nt $CNSET ] || [ $CN6 -nt $CNSET ] || { [ -n "$(cn6_part)" ] && ! grep -q kel_cn6 $CNSET; }; }; then cn_set > $CNSET.new; newset=1; fi
	rs=0; [ -f $NFT ] && cmp -s $NFT.new $NFT && rs=1
	same=$rs; [ $newset = 1 ] && same=0
	# 文件一致且防火墙里确实有这条规则才算「已生效」；文件在、规则丢了（被别的重载冲掉）要重新装
	if [ $same = 1 ] && nft_live kelclash; then rm -f $NFT.new; return 0; fi
	if ! nft_ok $NFT.new && [ ! -f $D/cn.off ] && [ -n "$(cn_part)$(cn6_part)" ]; then touch $D/cn.off; LOG "国内 IP 清单装不进防火墙规则，这次不带清单"; rule_body > $NFT.new; rm -f $CNSET.new; newset=0; fi
	if ! nft_ok $NFT.new; then rm -f $NFT.new $CNSET.new; rules_off "透明代理未启用：nft 规则自检未通过，保持直连"; return 1; fi
	had=0; [ -f $NFT ] && had=1
	[ $newset = 1 ] && mv $CNSET.new $CNSET
	mv $NFT.new $NFT
	if fw4 -q reload && nft_live kelclash; then
		if [ $same = 1 ]; then LOGK takeover_on "透明代理的 nft 规则被冲掉（fw4 重载等），已自动重新装入"
		elif [ $rs = 1 ]; then LOG "国内 IP 清单已装进防火墙"
		elif [ $had = 1 ]; then LOGK takeover_on "透明代理的接管范围已更新"; conn_reset
		else LOGK takeover_on "透明代理已启用：接管设备的 $([ "$(cfg ipv6)" = direct ] && echo 'IPv4（IPv6 按设置直连）' || echo 'IPv4/IPv6') TCP 流量转入内核（redir 7892）"; fi
		return 0
	fi
	rm -f $NFT $CNSET $QUICNFT; fw4 -q reload		# 集合文件、QUIC 拦截一起删：万一是它让重载失败，留着会让之后每次重载都失败
	if nft_live kelclash; then
		LOGK info "防火墙重载失败：旧的代理规则仍在生效，未恢复直连"; return 1
	fi
	LOGK takeover_off "透明代理未启用：fw4 没能加载规则，已回滚，保持直连"; return 1
}

# rules_off [原因]：撤销时把原因写进事件，用户看到的是「为什么恢复直连」而不是一句干巴巴的「已撤销」
# 以防火墙里的实际规则为准（不是文件）：reload 失败时文件已删但规则还在，下一轮必须继续撤，直到真的撤干净才算完成
rules_off() {
	had=0; [ -f $NFT ] && had=1; nft_live kelclash && had=1; [ -f $QUICNFT ] && had=1
	[ $had = 1 ] || return 0
	rm -f $NFT $QUICNFT
	fw4 -q reload; nft_live kelclash && fw4 -q reload
	nft_live kelclash && return 1
	LOGK takeover_off "${1:-已恢复直连}"
}

# ------------------------------------------------------------------ 内核进程
# info 级日志每条连接一行，限制在 1MB 内（内存盘）：超了只留最后 400 行
rotate_log() {
	sz=$(wc -c 2>/dev/null < $D/core.log); [ "${sz:-0}" -gt 1048576 ] || return 0
	tail -n 400 $D/core.log > $D/core.tail && cat $D/core.tail > $D/core.log; rm -f $D/core.tail
}

# core_alive：进程在不在；core_ready：进程在 + 透明代理端口在 LAN 地址上监听（能真正接流量）。
# 分开的原因：端口偶尔一次没看到（netstat 抖动/内核重建监听）就强杀内核太激进——守护里对「进程在但端口不在」
# 先撤接管规则（立即直连，不黑洞），连续 3 次才重启内核。
core_alive() {
	pid=$(cat $D/pid 2>/dev/null)
	[ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
core_ready() {
	core_alive || return 1
	# fw4 的 redirect 把连接送到「入口网卡的地址」（br-lan 的 IP）而不是 127.0.0.1，
	# 所以必须在 LAN 地址上探测；只探 127.0.0.1 会误判健康（2026-09-28 断网事故）
	ip=$(lan_ip); [ -n "$ip" ] || return 1
	netstat -lnt 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|::|:::|\*|$ip):$REDIR\$"
}

core_stop() {
	kill_hard "$(cat $D/pid 2>/dev/null)"
	killall -9 mihomo 2>/dev/null
	rm -f $D/pid
	stats_stop
}

# 流量统计采集器（stats.uc，常驻 ucode 进程）：内核在跑就保证它在，内核停了它也停。
# 它崩了由守护拉起；60 秒内最多拉一次，免得配置有问题时每轮都狂重启。
stats_stop() {
	kill_hard "$(cat $D/stats.pid 2>/dev/null)"
	rm -f $D/stats.pid
}
stats_ensure() {
	[ -f /usr/share/kelclash/stats.uc ] || return 0
	sp=$(cat $D/stats.pid 2>/dev/null)
	[ -n "$sp" ] && kill -0 "$sp" 2>/dev/null && return 0
	now=$(date +%s); last=$(cat $D/stats.ts 2>/dev/null)
	[ -n "$last" ] && [ $((now - last)) -lt 60 ] 2>/dev/null && return 0
	echo "$now" > $D/stats.ts
	ucode /usr/share/kelclash/stats.uc >/dev/null 2>&1 &
	echo $! > $D/stats.pid
}

guard_stop() {
	pid=$(cat $D/guard.pid 2>/dev/null)
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	rm -f $D/guard.pid
}

# 拉起内核：先自检配置，再放进「受限环境」——
#   句柄 4096（默认 1024，并发一多就 too many open files，全家新连接一起失败）
#   GOMEMLIMIT 让 Go 更积极回收；cgroup 内存上限保护路由器（超了只杀内核，不动别的）
#   nice 10 + 钉在 CPU1/CPU3：网卡中断和网络软中断都在 CPU0/CPU2，代理满载也挤不掉它们
core_launch() {
	# 订阅还没下载到本地（刚换订阅/首次启动且闪存无缓存）：此时「按服务选节点」无从匹配地区，只能先跟随「代理」组；
	# 记下来，等内核把订阅拉下来后守护补一次热重载（svc_late），否则服务组要等到下一次改设置才会建出来。
	svcfix=0; [ -s $D/sub.yaml ] || svcfix=1
	mmdb_ready || LOG "IP 地址库所有下载源都失败，交给内核自己再试一次"
	genconf
	# 订阅文件在、但从文件里没认出节点名（不是常见的单行写法 / 不是 Clash 格式）：服务组这次也建不出来，同样等内核解析完再补一次
	for it in $SVC_LIST; do k=${it%%:*}; eval "g=\$G_$k"; v=$(cfg svc_$k); [ "$g" = 代理 ] && [ -n "$v" ] && [ "$v" != follow ] && [ -z "$SUBN" ] && svcfix=1; done
	if ! conf_test; then
		LOGK engine_fail "配置自检未通过：$CONF_ERR"; phase failed "配置有误：$CONF_ERR"; return 1
	fi
	pin=""; command -v taskset >/dev/null 2>&1 && [ -d /sys/devices/system/cpu/cpu3 ] && pin="taskset -c 1,3"
	ulimit -n 4096 2>/dev/null
	( cd $D && export GOMEMLIMIT=150MiB && exec nice -n 10 $pin $BIN -d $D -f $D/config.yaml >> $D/core.log 2>&1 ) &
	echo $! > $D/pid
	cg_limit kelclash "$(cat $D/pid)" 170M 230M
	return 0
}

# ------------------------------------------------------------------ 健康检查
# probe URL 超时秒 期望状态码正则 —— 经 mihomo 的代理口访问；curl 放后台 + wait，收到停止信号能立刻响应
probe() {
	( curl -s -o /dev/null -m "$2" -x "http://$PXIP:$MIXED" -w '%{http_code}' "$1" > $D/probe.out 2>/dev/null ) & wait $!
	grep -qE "$3" $D/probe.out 2>/dev/null
}
# 内核自检：让 mihomo 用「直连出口」访问国内站（/proxies/DIRECT/delay）。
# 🔴 不能再用 curl -x 走代理口访问 baidu：「全部代理」模式下 baidu 也要绕国外节点，慢一点就超时，
#    被误判成「引擎坏了」而撤掉接管（2026-09-30 用户实测踩到）。这个测试只反映引擎本身，与模式、节点无关。
probe_direct() {
	( curl -s -m 6 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cfg secret)" "http://$CTL/proxies/DIRECT/delay?url=http%3A%2F%2Fwww.baidu.com%2F&timeout=4000" > $D/probe.dcode 2>/dev/null ) & wait $!
	[ "$(cat $D/probe.dcode 2>/dev/null)" = 200 ]
}

# 「经代理真能出去」的判断：让内核测「代理」组当前出口（含智能回退的选择）访问一个**国内直连不通**的地址。
# 🔴 不能用 curl -x 走代理口访问 gstatic：gstatic 在国内解析成 Google 国内节点 IP，被分流规则判成「国内」直连，
#    永远返回 204——测不出节点故障，也碰不到（懒检测的）智能回退组。这个接口还会顺带触发智能回退的检测。
# 「设备的流量真能过去吗」：经内核的代理口访问国内网站——走的是和设备一样的分流规则、内核里的域名解析和出口。
# 🔴 只靠 probe_direct 不够：它让内核用管理接口自己测直连，绕开了设备流量经过的那条路。节点全挂、内核被大量卡住的
#    连接拖垮时，它可能照样通过，而全家的国内网站都已经打不开（2026-10-29 用户实际遇到全家断网）。
# 两个站任一能打开即算通；「全部代理」模式下这一步要经过节点，节点全挂就该判不通、恢复直连——那正是我们要的。
DOMESTIC="http://www.baidu.com/ http://www.qq.com/"
probe_path() {
	for u in $DOMESTIC; do
		( curl -s -o /dev/null -m 5 -x "http://$PXIP:$MIXED" -w '%{http_code}' "$u" > $D/probe.pcode 2>/dev/null ) & wait $!
		case "$(cat $D/probe.pcode 2>/dev/null)" in 2*|3*) return 0;; esac
	done
	return 1
}
# 路由器自己直连能不能打开国内网站：不能说明是宽带本身断了，不是代理的问题，不撤不重启，免得白折腾
wan_ok() {
	for u in $DOMESTIC; do
		( curl -s -o /dev/null -m 4 -w '%{http_code}' "$u" > $D/probe.wcode 2>/dev/null ) & wait $!
		case "$(cat $D/probe.wcode 2>/dev/null)" in 2*|3*) return 0;; esac
	done
	return 1
}
# 独立保险丝（kel-watchdog）刚撤过规则：10 分钟内不重新接管，免得守护和保险丝来回拉锯
fuse_hold() { ts=$(cat $D/fuse.ts 2>/dev/null); [ -n "$ts" ] && [ $(( $(date +%s) - ts )) -lt 600 ] 2>/dev/null; }

probe_foreign() {
	for u in $(cfg health_urls); do
		enc=$(printf '%s' "$u" | sed 's/%/%25/g; s/:/%3A/g; s#/#%2F#g; s/?/%3F/g; s/=/%3D/g; s/&/%26/g')
		( curl -s -m 5 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cfg secret)" "http://$CTL/proxies/%E4%BB%A3%E7%90%86/delay?url=$enc&timeout=3500" > $D/probe.code 2>/dev/null ) & wait $!
		[ "$(cat $D/probe.code 2>/dev/null)" = 200 ] && return 0
	done
	return 1
}

# 智能回退当前是否已把流量切到直连（只在「代理」组选中了它时才有意义——它是懒检测组，没被用时状态是过期的）
fb_direct() {
	cur=$(api GET "/proxies/%E4%BB%A3%E7%90%86" | jsonfilter -e '@.now' 2>/dev/null)
	[ "$cur" = "智能回退" ] || return 1
	fbn=$(api GET "/proxies/%E6%99%BA%E8%83%BD%E5%9B%9E%E9%80%80" | jsonfilter -e '@.now' 2>/dev/null)
	[ "$fbn" = "DIRECT" ] || return 1
	grp_check; sleep 1		# 先复检再下结论：可能只是懒检测组还没测过
	[ "$(api GET "/proxies/%E6%99%BA%E8%83%BD%E5%9B%9E%E9%80%80" | jsonfilter -e '@.now' 2>/dev/null)" = "DIRECT" ]
}

# 服务组空了没有：订阅更新后，指定的地区/节点可能已经不在订阅里，这时组里一个节点都没有，内核拿一个「直连占位」(COMPATIBLE) 顶着，
# 外层的回退组测它是通的（直连能到测试地址），于是这个服务悄悄变成直连——AI、流媒体这类恰恰是直连用不了的。
# 发现空组就重新生成配置：genconf 会把找不到节点的服务退回跟随「代理」组并记一条事件。
svc_empty() {
	API_TMO=6 api GET /proxies 2>/dev/null | ucode -e 'import {stdin} from "fs"; let j=json(stdin.read("all"))?.proxies ?? {}; for (let k in keys(j)) if (length(k) > 7 && substr(k, -7) === "-选择" && j[k].now === "COMPATIBLE") exit(0); exit(1);' 2>/dev/null
}

# 刚热重载过（60 秒内）：节点检测结果还没出齐，这段时间的探测失败不作数
reconf_grace() {
	[ -d $D/reconf.lock ] && return 0	# 重载还在进行（或在排队）
	ts=$(cat $D/reconf.ts 2>/dev/null); [ -n "$ts" ] || return 1
	[ $(( $(date +%s) - ts )) -lt 60 ] 2>/dev/null
}

# ------------------------------------------------------------------ 守护
guard() {
	# 只允许一个 guard：旧的（含残留孤儿）先杀掉
	old=$(cat $D/guard.pid 2>/dev/null)
	[ -n "$old" ] && [ "$old" != "$$" ] && kill "$old" 2>/dev/null
	mkdir -p $D; echo $$ > $D/guard.pid
	trap 'rules_off; core_stop; rm -f $D/guard.pid; exit 0' TERM INT HUP
	# 一上来就把状态写成「正在启动」：否则等网络、下载内核这段时间里，页面读到的还是上一次留下的状态
	# （上次是「启动失败」的话，刚点开启就显示「启动遇到问题」）
	phase starting "正在启动"
	rules_off; health_note off
	wait_net 120
	n=0; until fetch; do n=$((n+1)); wait_net 30; nap $((n < 4 ? 20 : 60)); done
	sub_restore; rules_restore; cn_restore || ( cn_sync ) >/dev/null 2>&1 &
	phase starting "正在启动"
	fails=0; lr=0; tick=0; dbad=0; fbad=0; okst=0; sp=0; nbad=0; fbst=0; miss=0; pbad=0
	# 守护里调内核管理接口最多等 4 秒（默认 10 秒）：内核一卡，一轮检查里十几次调用会把「撤规则恢复直连」拖到好几分钟后
	API_TMO=4
	while :; do
		# 关闭后立刻退出（防孤儿 guard 在 enabled=0 后继续加规则）
		if [ "$(cfg enabled)" != "1" ]; then rules_off "内核已停止，透明代理撤销，所有设备恢复直连"; core_stop; rm -f $D/guard.pid; exit 0; fi
		if ! core_alive; then
			# 内核没了 → 先撤规则（立即直连），再拉起
			rules_off; okst=0; dbad=0; fbad=0
			core_stop
			phase starting "正在启动"
			if core_launch; then
				# 等端口起来（首次要下载 GeoIP 库）
				i=0; while [ $i -lt 60 ] && ! core_ready; do nap 2; i=$((i+1)); done
			fi
			if ! core_ready; then
				fails=$((fails+1)); LOGK engine_fail "内核启动失败（第 $fails 次），保持直连，稍后重试"; core_stop
				[ -n "$CONF_ERR" ] || phase failed "内核启动失败（第 $fails 次），保持直连；$(tail -n 1 $D/core.log 2>/dev/null | sed 's/.*msg=//' | cut -c1-120)"
				nap $((fails < 10 ? fails * 30 : 300)); continue
			fi
			fails=0; CONF_ERR=""; miss=0
			( nap 8; apply_saved_node ) &
			LOGK engine_start "内核已启动"
		fi
		if ! core_ready; then
			miss=$((miss+1)); okst=0
			rules_off "内核的透明代理端口没有在监听，已撤销透明代理，恢复直连"
			[ "$miss" -ge 3 ] && { LOGK engine_fail "内核进程在但端口连续 3 次不在监听，正在重启内核"; core_stop; miss=0; }
			nap 5; continue
		fi
		miss=0
		if [ "$svcfix" = 1 ] && [ -n "$(sub_names)" ]; then
			svcfix=0; ( reconfig ) >/dev/null 2>&1 &
		fi
		phase running "运行中"
		stats_ensure
		lr=$((lr+1)); [ $((lr % 2)) -eq 0 ] && rotate_log
		[ $((lr % 6)) -eq 3 ] && autoswitch_check
		sp=$((sp+1)); [ $((sp % 60)) -eq 0 ] && sub_persist
		if [ $((sp % 60)) -eq 30 ]; then ( reconf_grace || { svc_empty && reconfig; } ) >/dev/null 2>&1 & fi
		# 社区规则：启动后 1 分钟拉一次、之后每天一次；有变化才热重载（后台跑，不阻塞守护）
		if [ $((sp % 17280)) -eq 12 ]; then ( rules_sync && reconfig ) >/dev/null 2>&1 & ( cn_sync ) >/dev/null 2>&1 & fi

		# 「接管全家」是独立开关（uci transparent）：关着就永远只有代理端口、没有转发规则
		if [ "$(cfg transparent)" != "1" ]; then rules_off "透明代理已关闭，所有设备恢复直连"; health_note off; okst=0; nap 5; continue; fi

		# 健康检查（约每 10 秒）——区分两类问题：
		#   内核有病（经代理访问国内站失败）→ 立刻撤规则，连续 4 次重启内核
		#   节点有病（国内 OK、国外站经代理失败）→ 连续 3 次才撤规则（防抖）；国外站在不开代理时本来就不通，
		#     撤规则只影响「非封锁的国外站」，所以不必一抖就撤
		#   恢复后要连续 2 次全通过才重新接管（防来回抖）
		tick=$((tick+1))
		# 平时约 10 秒查一次；只要上一轮有过失败，就每轮都查——节点全挂时要尽快恢复直连（2026-10-30 演练：隔轮查 + 连续 3 次 = 约 105 秒才撤）
		if [ $((tick % 2)) -eq 1 ] || [ $((dbad + fbad + pbad)) -gt 0 ]; then
			PXIP=$(lan_ip)
			if reconf_grace; then
				:	# 热重载后的宽限期：不探测、不计数，保持现状
			elif ! probe_direct; then
				# 连续 2 次不通才撤规则（偶发抖动不撤）；连续 4 次才重启引擎
				dbad=$((dbad+1)); okst=0
				if [ "$dbad" -ge 2 ]; then rules_off "内核自检失败，已撤销透明代理，恢复直连"; health_note domestic-fail; fi
				if [ "$dbad" -ge 4 ]; then LOGK engine_fail "内核自检连续失败，正在重启内核（期间保持直连）"; core_stop; dbad=0; continue; fi
			elif ! probe_path && wan_ok; then
				# 设备的流量过不去（宽带本身是通的）：连续 2 次就撤，约 20 秒内恢复直连
				dbad=0; pbad=$((pbad+1)); okst=0
				if [ "$pbad" -ge 2 ]; then rules_off "国内网站经代理打不开（内核或节点卡住），已撤销透明代理，恢复直连"; health_note domestic-fail; fi
				if [ "$pbad" -ge 6 ]; then LOGK engine_fail "经代理一直打不开国内网站，正在重启内核（期间保持直连）"; core_stop; pbad=0; continue; fi
			else
				dbad=0; pbad=0
				if [ "$(cfg mode)" = "direct" ] || probe_foreign; then
					fbad=0; okst=$((okst+1))
				else
					fbad=$((fbad+1)); okst=0; health_note foreign-fail
					# 智能回退是懒检测组：主动测一次成员，让它尽快切到直连（节点故障时）/ 切回节点（节点恢复时）。放后台，不拖慢判断
					( grp_check ) >/dev/null 2>&1 &
					if [ "$fbad" -ge 2 ]; then rules_off "所有节点不可用，已撤销透明代理，恢复直连（节点恢复后自动重新启用）"; fb_direct && health_note fallback; fi
				fi
			fi
			if [ "$okst" -ge 2 ]; then
				if fb_direct; then
					health_note fallback; [ "$fbst" = 1 ] || { fbst=1; LOGK fallback "所有节点不可用，智能回退组已切到 DIRECT：直连可达的站点正常，需代理的站点暂不可用"; }
				else
					health_note ok; [ "$fbst" = 1 ] && { fbst=0; LOGK recover "节点已恢复，智能回退组切回代理节点"; }
				fi
			elif [ ! -f $NFT ] && [ "$fbad" -eq 0 ] && [ "$dbad" -eq 0 ]; then health_note warming
			fi
		fi
		if [ "$okst" -ge 2 ]; then
			if fuse_hold; then health_note warming; else rules_on && quic_sync; fi
		fi
		nap 5
	done
}

# 只切模式：PATCH 即时生效（<1 秒），同时刷新 config.yaml，下次重启/热重载仍是这个模式
mode_fast() {
	core_ready || return 1
	printf '{"mode":"%s"}' "$(cfg mode)" > $D/mode.json
	api PATCH /configs $D/mode.json >/dev/null 2>&1; rc=$?; rm -f $D/mode.json
	[ $rc = 0 ] || return 1
	[ "$(api GET /configs | jsonfilter -e '@.mode' 2>/dev/null)" = "$(cfg mode)" ] || return 1
	genconf; rc=$?
	conn_reset
	return $rc
}

# 改规则/模式/节点分组后热重载（不重启内核、不断连接）；先自检，坏配置绝不下发
# 内核里跑的是不是「现在这份设置」：模式一致，且每个服务组「该有的有、不该有的没有」。
# 热重载的成败以它为准，不看 PUT 请求本身的返回——MIPS 上重载常常比请求超时还久，请求超时不等于内核拒绝
# （2026-10-13：连续改两次设置，第二次被当成「内核拒绝」而回滚，页面上就是「选了又跳回去」）。
reconf_applied() {
	[ "$(api GET /configs | jsonfilter -e '@.mode' 2>/dev/null)" = "$(cfg mode)" ] || return 1
	API_TMO=8 api GET /proxies > $D/px.json 2>/dev/null || { rm -f $D/px.json; return 1; }
	rc=0
	for it in $SVC_LIST; do
		k=${it%%:*}; eval "g=\$G_$k"; has=0
		grep -q "\"${it#*:}-选择\":" $D/px.json && has=1
		if [ "$g" = 代理 ]; then [ $has = 0 ] || rc=1; else [ $has = 1 ] || rc=1; fi
	done
	rm -f $D/px.json
	return $rc
}
reconfig() {
	core_ready || return 1
	# 同一时间只做一次热重载（页面保存、规则集更新、订阅到达后的补建都会触发）：后来的排队等，最多等 90 秒
	i=0
	while ! mkdir $D/reconf.lock 2>/dev/null; do
		op=$(cat $D/reconf.lock/pid 2>/dev/null)
		{ [ -n "$op" ] && kill -0 "$op" 2>/dev/null; } || { rm -rf $D/reconf.lock; continue; }
		i=$((i+1)); [ $i -gt 90 ] && return 1
		sleep 1
	done
	echo $$ > $D/reconf.lock/pid
	reconfig_do; rc=$?
	rm -rf $D/reconf.lock
	return $rc
}
reconfig_do() {
	# 上一次热重载的后台节点检测还在跑的话先让它停：它占着内核的控制接口，这一次的重载会被拖到超时
	hp=$(cat $D/hc.pid 2>/dev/null); [ -n "$hp" ] && kill "$hp" 2>/dev/null; rm -f $D/hc.pid
	genconf
	conf_test || { LOGK engine_fail "设置被拒绝：配置自检未通过（$CONF_ERR），已保持原设置"; return 1; }
	date +%s > $D/reconf.ts
	printf '{"path":"%s"}' "$D/config.yaml" > $D/reload.json
	API_TMO=30 api PUT "/configs?force=true" $D/reload.json >/dev/null 2>&1
	rm -f $D/reload.json
	# 请求可能已超时而内核还在重载：最多再等 40 秒，直到内核里确实是新设置
	i=0; until reconf_applied; do i=$((i+1)); [ $i -gt 13 ] && { CONF_ERR="内核 70 秒内没有完成重载"; return 1; }; sleep 3; done
	# 热重载会把所有节点的检测结果清零，重新测一遍要 10–30 秒：放后台，并打「刚重载过」的时间戳，
	# 守护在宽限期内（reconf_grace）不把探测失败算作故障——否则会把「还没测完」误判成「所有节点不可用」而撤销透明代理。
	date +%s > $D/reconf.ts
	( sleep 1; api GET "/providers/proxies/sub/healthcheck" >/dev/null 2>&1; grp_check; rm -f $D/hc.pid ) >/dev/null 2>&1 &
	echo $! > $D/hc.pid
	return 0
}

# 页面改了模式/服务组/自定义规则后的「后台应用」：热重载在 MIPS 上要 10–40 秒，不能让页面请求干等。
# kelapi 把 uci 写好、留下快照（$D/apply.bak：键<TAB>值；$D/apply.rules：规则文本）后启动这里。
# 状态写 $D/apply.state：running / ok / fail:原因。应用期间又有新改动（apply.again）就再跑一轮，保证最后生效的是最新设置。
# 内核拒绝 → 按快照把 uci 和规则恢复成上一次确认生效的值，再重载回去。
apply_bg() {
	mkdir -p $D
	if ! mkdir $D/apply.lock 2>/dev/null; then
		op=$(cat $D/apply.lock/pid 2>/dev/null)
		if [ -n "$op" ] && kill -0 "$op" 2>/dev/null; then touch $D/apply.again; return 0; fi
		rm -rf $D/apply.lock; mkdir $D/apply.lock 2>/dev/null || return 0	# 上一轮异常退出留下的锁
	fi
	echo $$ > $D/apply.lock/pid
	while :; do
		rm -f $D/apply.again; echo running > $D/apply.state
		if reconfig; then
			[ -f $D/apply.again ] && continue
			conn_reset
			rm -f $D/apply.bak $D/apply.rules; echo ok > $D/apply.state; break
		fi
		[ -f $D/apply.again ] && continue
		why=${CONF_ERR:-内核没有接受新配置}
		if [ -f $D/apply.bak ]; then
			while IFS="	" read -r k v; do [ -n "$k" ] && uci set kelclash.main.$k="$v"; done < $D/apply.bak
			uci commit kelclash
			[ -f $D/apply.rules ] && cat $D/apply.rules > $FLASH/rules.txt
			reconfig >/dev/null 2>&1
		fi
		rm -f $D/apply.bak $D/apply.rules
		echo "fail:$why" > $D/apply.state
		ev engine_fail "设置没有生效：$why；已恢复为之前的设置"
		break
	done
	rm -rf $D/apply.lock
}

# 测试保护：/tmp/kelclash.deadman 里放一个到期时间戳，由 cron 每分钟调用本子命令检查。
# 必须走 cron（路由器自己的定时器）——用 ssh 里的后台 sleep 会在断线时被一起杀掉。
deadman() {
	f=/tmp/kelclash.deadman
	[ -f $f ] || exit 0
	[ "$(date +%s)" -ge "$(cat $f)" ] || exit 0
	LOG "测试保护到期：关闭代理并恢复直连"
	rm -f $f
	uci set kelclash.main.enabled=0; uci commit kelclash
	uci -q delete kelclash.main.only_mac; uci commit kelclash
	rules_off; guard_stop; core_stop
	/etc/init.d/kelclash stop >/dev/null 2>&1
}

case "$1" in
	deadman) deadman ;;
	reconfig) reconfig ;;
	apply-bg) apply_bg ;;
	mode) mode_fast ;;
	rules-sync) rules_sync && reconfig ;;
	api) shift; api "$@" ;;
	select) shift; select_proxy "$1" ;;
	best) b=$(best_node); nn=$(echo "$b" | cut -f1); [ -n "$nn" ] && select_proxy "$nn" && printf '%s\t%s\n' "$nn" "$(echo "$b" | cut -f2)" ;;
	guard) guard ;;
	fetch) fetch ;;
	rules-off) rules_off ;;
	core-stop) guard_stop; core_stop; rm -f $D/phase $D/health ;;
	status)
		st=stopped; core_ready && st=running
		ga=0; gp=$(cat $D/guard.pid 2>/dev/null); [ -n "$gp" ] && kill -0 "$gp" 2>/dev/null && ga=1
		# synced：已装进防火墙的接管规则是不是「按现在的设置应有的」那一份。改了接管范围/IPv6 开关后，守护要到下一轮才换规则，
		# 这几秒到十几秒里页面不能说「已按新设置接管」
		# 只比「设置决定的部分」（接管哪些设备、含不含 IPv6），不整份比对：规则的其它细节会随脚本版本变，
		# 新脚本装上后、守护重启前，已装的规则还是旧写法——整份比会一直报「未同步」
		sy=1
		if [ -f $NFT ]; then
			wm=$(uci -q get kelclash.main.only_mac | tr ' ' '\n' | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$' | tr 'A-F' 'a-f' | tr '\n' ',' | sed 's/,$//')
			lm=$(sed -n 's/.*ether saddr { \([^}]*\) }.*/\1/p' $NFT | head -n 1)
			[ "$wm" = "$lm" ] || sy=0
			w6=1; [ "$(cfg ipv6)" = direct ] && w6=0; l6=0; grep -q kelclash6 $NFT && l6=1
			[ $w6 = $l6 ] || sy=0
		fi
		printf '{"core":"%s","rules":%s,"binary":%s,"guard":%s,"synced":%s,"quic":%s}\n' $st $(nft_live kelclash && echo 1 || echo 0) $([ -x $BIN ] && echo 1 || echo 0) $ga $sy $(nft list chain inet fw4 forward 2>/dev/null | grep -q kelclash-quic && echo 1 || echo 0)
		;;
	*) echo "usage: $0 guard|fetch|rules-off|core-stop|reconfig|deadman|api|status"; exit 1 ;;
esac
