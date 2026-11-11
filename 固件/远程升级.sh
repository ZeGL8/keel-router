#!/bin/zsh
# 远程升级.sh —— 一条命令完成整次升级并验收，全程无人值守。
#
# 路由器自己完成 检查→下载→校验→刷入→重启（/usr/sbin/kel-upgrade）；本脚本负责：
#   刷之前：核对固件、备份、把升级程序放到路由器上、在本机开一个临时下载地址、发出升级指令；
#   刷的时候：路由器会断网 3–5 分钟，本脚本只是等，不需要任何人操作，也不需要外网；
#   刷完后：自己把路由器找回来（原地址 → 当前网关 → 192.168.1.1），逐项验收，写出结论。
# 所有输出同时写进 固件/升级记录/<时间>.log；最后一行是 RESULT=OK / RESULT=FAIL:<原因>。
#
# 用法：./远程升级.sh <路由器IP> [--演练]      （--演练：做到「下载并校验」为止，不刷写）
H="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$H/.." && pwd)"
HOST=$1; DRY=0; [[ "$2" == "--演练" ]] && DRY=1
[[ -n "$HOST" ]] || { echo "用法：$0 <路由器IP> [--演练]"; exit 2; }
VER=$(cat "$H/版本.txt"); OUT="$H/输出/$VER"
TS=$(date +%Y%m%d-%H%M%S); mkdir -p "$H/升级记录"; LOG="$H/升级记录/$TS.log"
exec > >(tee -a "$LOG") 2>&1
S=(-i "$P/部署工具/.deploykey" -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes -o ConnectTimeout=5)
say() { echo "[$(date +%H:%M:%S)] $*"; }
r() { ssh $S root@$HOST "$@"; }
HTTPD=0
finish() { [[ $HTTPD != 0 ]] && kill $HTTPD 2>/dev/null; echo "RESULT=$1"; [[ "$1" == OK* ]] && exit 0 || exit 1; }

# ---------- 1. 刷之前 ----------
say "目标：把 $HOST 升级到 $VER  $([[ $DRY == 1 ]] && echo '（演练，不刷写）')"
BIN=$(find "$OUT" -name "*squashfs-sysupgrade.bin" | head -1)
[[ -f "$BIN" && -f "$OUT/latest.json" ]] || finish "FAIL:本地没有 $VER 的固件，先运行 ./构建.sh"
[[ "$(shasum -a 256 "$BIN" | cut -d' ' -f1)" == "$(python3 -c "import json;print(json.load(open('$OUT/latest.json'))['sha256'])")" ]] || finish "FAIL:本地固件与版本清单的校验和不一致"
r true || finish "FAIL:连不上路由器 $HOST（ssh 密钥登录）"
BEFORE_VER=$(r "sed -n 's/^version=//p' /etc/kel_version 2>/dev/null"); BEFORE_BOOT=$(r "cut -d' ' -f1 /proc/uptime | cut -d. -f1")
BEFORE_WAN=$(r "ubus call network.interface.wan status | jsonfilter -e '@.up'"); BEFORE_PROXY=$(r "uci -q get kelclash.main.enabled"); BEFORE_ADG=$(r "uci -q get keladg.main.enabled")
say "升级前：版本=${BEFORE_VER:-（官方固件+事后安装）} 已运行=${BEFORE_BOOT}s 外网=$BEFORE_WAN 代理开关=$BEFORE_PROXY 广告过滤开关=$BEFORE_ADG"
[[ "$BEFORE_WAN" == true ]] || say "⚠️ 升级前外网就不通，升级后的「能上网」检查会失败"

BK="$H/救援备份-$TS"; mkdir -p "$BK"
r 'sysupgrade -b - 2>/dev/null' > "$BK/配置备份-sysupgrade.tar.gz"
[[ $(stat -f %z "$BK/配置备份-sysupgrade.tar.gz") -gt 1000 ]] || finish "FAIL:配置备份失败"
if [[ $DRY == 0 ]]; then
	r 'cat /dev/mtd3ro' > "$BK/mtd3-firmware.bin"
	[[ $(stat -f %z "$BK/mtd3-firmware.bin") == 16187392 ]] || finish "FAIL:系统分区备份大小不对"
fi
say "已备份到 $BK"

# 升级程序放到路由器上（新固件里自带；从旧系统第一次迁移时路由器上还没有）
scp -O $S "$P/后端插件/kel-upgrade" root@$HOST:/usr/sbin/kel-upgrade >/dev/null && r 'chmod 755 /usr/sbin/kel-upgrade; sh -n /usr/sbin/kel-upgrade' || finish "FAIL:升级程序没放上去"

# 本机临时下载地址：路由器从这里取版本清单和固件（和以后放到公网走的是同一条路）
MYIP=$(r 'echo $SSH_CLIENT' | awk '{print $1}')
[[ -n "$MYIP" ]] || finish "FAIL:取不到本机在局域网里的地址"
PORT=18080
( cd "$OUT" && exec python3 -m http.server $PORT --bind 0.0.0.0 >/dev/null 2>&1 ) & HTTPD=$!
sleep 1
URL="http://$MYIP:$PORT"
CHK=$(r "kel-upgrade check '$URL'"); say "路由器检查更新：$CHK"
echo "$CHK" | grep -q '"status":0' || finish "FAIL:路由器取不到版本清单（$URL）"
echo "$CHK" | grep -q '"board_ok":1' || finish "FAIL:固件型号与路由器不符"

# ---------- 2. 发出指令，之后路由器自己做 ----------
FLAGS="--same"; [[ $DRY == 1 ]] && FLAGS="--same --dry"
r "kel-upgrade start '$URL' $FLAGS" | grep -q '"status":0' || finish "FAIL:升级没有启动"
say "已发出升级指令，路由器开始自己执行"
LAST=""; GONE=0
for i in {1..300}; do
	ST=$(r 'kel-upgrade status' 2>/dev/null)
	if [[ -z "$ST" ]]; then GONE=$((GONE+1)); [[ $GONE -ge 3 ]] && break; sleep 2; continue; fi
	GONE=0; PH=$(echo "$ST" | sed -n 's/.*"phase":"\([^"]*\)".*/\1/p'); MSG=$(echo "$ST" | sed -n 's/.*"msg":"\([^"]*\)".*/\1/p')
	[[ "$PH|$MSG" != "$LAST" ]] && { say "路由器：[$PH] $MSG"; LAST="$PH|$MSG"; }
	[[ "$PH" == error ]] && finish "FAIL:路由器在刷写之前停下了（$MSG）。系统没有被改动，仍在原样运行"
	[[ "$PH" == dry-ok ]] && finish "OK:演练通过（$MSG）"
	sleep 2
done
[[ $DRY == 1 ]] && finish "FAIL:演练没有给出结论"
[[ "$PH" == flashing || "$PH" == stopping ]] || finish "FAIL:路由器失联时并不在刷写阶段（最后状态：$LAST）"
kill $HTTPD 2>/dev/null; HTTPD=0
say "路由器已进入刷写并断开。接下来只是等它回来（通常 3–5 分钟），期间这台电脑没有网络是正常的。"

# ---------- 3. 把它找回来 ----------
FOUND=""; T0=$(date +%s)
while (( $(date +%s) - T0 < 900 )); do
	sleep 5
	GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
	for ip in $HOST $GW 192.168.1.1; do
		[[ -n "$ip" ]] || continue
		if ssh $S root@$ip 'cat /proc/uptime' >/dev/null 2>&1; then FOUND=$ip; break 2; fi
	done
	(( ($(date +%s) - T0) % 30 < 6 )) && say "还在等…已 $(( $(date +%s) - T0 )) 秒（当前网关 ${GW:-无}）"
done
if [[ -z "$FOUND" ]]; then
	GW=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
	if [[ -n "$GW" ]] && ping -c 2 -t 3 $GW >/dev/null 2>&1; then finish "FAIL:15 分钟内没能用密钥登录路由器，但网关 $GW 能 ping 通——系统多半起来了，只是配置（含登录密钥）没有恢复。用浏览器打开 http://$GW 检查"; fi
	finish "FAIL:15 分钟内找不到路由器。需要到路由器旁边：按住 reset 上电进入恢复页面（http://192.168.1.1），上传 固件/下载/ 里的官方固件或本固件；配置在 $BK"
fi
say "找到了：$FOUND（用时 $(( $(date +%s) - T0 )) 秒）"
[[ "$FOUND" == "$HOST" ]] || say "⚠️ 地址变了（原来 $HOST）：配置可能没有完整恢复"
HOST=$FOUND

# ---------- 4. 验收 ----------
FAILS=()
ok() { say "  ✓ $1"; }; no() { say "  ✗ $1"; FAILS+=("$1"); }
sleep 20	# 刚能登录时服务还在陆续启动
NOW_VER=$(r "sed -n 's/^version=//p' /etc/kel_version"); UP=$(r "cut -d' ' -f1 /proc/uptime | cut -d. -f1")
[[ "$NOW_VER" == "$VER" ]] && ok "版本是 $VER" || no "版本不对：现在是「$NOW_VER」，应为 $VER"
[[ "$UP" -lt 900 ]] && ok "确实重启过（已运行 ${UP}s）" || no "路由器没有重启过（已运行 ${UP}s）"
r "grep -q 'booted version=$VER' /etc/kel_upgrade.log" && ok "新系统的首次启动脚本已执行" || no "升级记录里没有新系统的启动标记"
r "[ -f /rom/usr/share/rpcd/ucode/kelapi ] && [ ! -e /overlay/upper/www/PC ]" && ok "程序在固件只读区，可写区里没有旧网页" || no "程序不在只读区，或可写区里还有旧网页"
FREE=$(r "df -k /overlay | awk 'NR==2{print \$4}'"); [[ "$FREE" -gt 1500 ]] && ok "可写区剩余 ${FREE}KB" || no "可写区只剩 ${FREE}KB"
for i in {1..24}; do [[ "$(r "ubus call network.interface.wan status | jsonfilter -e '@.up'")" == true ]] && break; sleep 5; done
[[ "$(r "ubus call network.interface.wan status | jsonfilter -e '@.up'")" == true ]] && ok "外网接口已连上" || no "外网接口没有连上"
r "ping -c 2 -W 3 223.5.5.5 >/dev/null" && ok "路由器能访问外网" || no "路由器访问不了外网"
r "nslookup www.baidu.com 127.0.0.1 >/dev/null 2>&1" && ok "域名解析正常" || no "域名解析失败"
[[ "$(curl -s -m 8 -o /dev/null -w '%{http_code}' http://$HOST/)" == 200 ]] && ok "管理界面能打开" || no "管理界面打不开"
r "ubus -t 15 call kelapi.static get_hostname >/dev/null 2>&1" && ok "界面后端有响应" || no "界面后端没有响应"
r "iwinfo 2>/dev/null | grep -q 'Mode: Master'" && ok "无线在工作" || no "无线没有起来"
[[ "$(r 'uci -q get kelclash.main.enabled')" == "$BEFORE_PROXY" && "$(r 'uci -q get keladg.main.enabled')" == "$BEFORE_ADG" ]] && ok "代理和广告过滤的开关与升级前一致" || no "代理/广告过滤的开关变了"
r "[ -n \"\$(uci -q get kelclash.main.sub_url)\" ]" && ok "订阅等个人设置还在" || { [[ "$BEFORE_PROXY" == 1 ]] && no "订阅设置丢了"; }
ping -c 2 -t 4 223.5.5.5 >/dev/null 2>&1 && ok "这台电脑能上网" || no "这台电脑还上不了网"
if [[ "$BEFORE_PROXY" == 1 ]]; then
	say "  代理内核要重新下载到内存，最多等 6 分钟…"
	for i in {1..36}; do r "/usr/share/kelclash/run.sh status 2>/dev/null | grep -q '\"core\":\"running\"'" && break; sleep 10; done
	r "/usr/share/kelclash/run.sh status 2>/dev/null | grep -q '\"core\":\"running\"'" && ok "代理内核已恢复运行" || say "  · 代理内核还没起来（不算升级失败：它每次开机都要重新下载，可稍后在界面上看）"
fi
(( ${#FAILS} == 0 )) && finish "OK:已升级到 $VER，全部检查通过（路由器 $HOST）" || finish "FAIL:已刷入并找回路由器（$HOST），但有 ${#FAILS} 项检查没过：${(j:；:)FAILS}"
