#!/bin/zsh
# 远程推送.sh —— 用 SSH 密钥把后端/前端推到路由器（不打固件的日常迭代用），不碰网络、不重启代理。
# 走 SSH 密钥，局域网地址和公网 IPv6 都能用。
# 用法：./远程推送.sh <路由器地址> [后端|前端|全部]        （默认 全部）
#       KEL_BIND=en1 ./远程推送.sh 240e:...     本机开着代理 TUN 时要绑定物理网卡，否则连接被代理截走
# 推上去的文件落在可写区，会盖住固件只读区里的同名文件；下次打固件前路由器与 git 主线必须一致。
set -e
T="$(cd "$(dirname "$0")" && pwd)"; P="$(cd "$T/.." && pwd)"
HOST=$1; WHAT=${2:-全部}
[[ -n "$HOST" ]] || { echo "用法：$0 <路由器地址> [后端|前端|全部]"; exit 2; }
S=(-o BatchMode=yes -o ConnectTimeout=10); [[ -n "$KEL_BIND" ]] && S+=(-B "$KEL_BIND")
r() { ssh $S root@$HOST "$@"; }
put() { ssh $S root@$HOST "cat > '$2'" < "$1"; }	# 不用 scp：IPv6 字面地址在 scp 里要另写一套方括号
[[ -z "$(git -C "$P" status --porcelain)" ]] || { echo "!! git 主线有未提交的改动：先提交再推，路由器上只允许出现提交过的内容"; exit 1; }
r true || { echo "!! 连不上 $HOST"; exit 1; }
# 这份代码用的是 kel 命名；路由器上如果还是旧命名的固件，热推送会让新旧两套后端并存、前端找不到接口——必须先升级固件
r 'test -f /etc/kel_version' || { echo "!! 路由器上的固件还是旧版本（没有 /etc/kel_version），名字对不上，不能热推送；请先升级固件"; exit 1; }

if [[ $WHAT == 后端 || $WHAT == 全部 ]]; then
	echo "==> 后端：定义顺序检查"
	uv run --no-project python "$T/检查定义顺序.py" "$P/后端插件/kelapi" | tail -2
	put "$P/后端插件/kelapi" /tmp/kelapi.new; put "$P/后端插件/kelapi.json" /tmp/kelapi.acl.new
	put "$P/后端插件/kelclash/run.sh" /tmp/kelclash.run.new; put "$P/后端插件/keladg/run.sh" /tmp/keladg.run.new; put "$P/后端插件/kel-watchdog" /tmp/kel-watchdog.new; put "$P/后端插件/kelclash/stats.uc" /tmp/kelclash.stats.new
	echo "==> 后端：语法检查 → 安装 → 重启 rpcd（接口没起来就自动退回）"
	r '
		cd /tmp && ucode -c -o /dev/null /tmp/kelapi.new || { echo "!! ucode 语法不通过，路由器未被改动"; exit 1; }
		sh -n /tmp/kelclash.run.new && sh -n /tmp/keladg.run.new && sh -n /tmp/kel-watchdog.new || { echo "!! 守护脚本语法不通过，路由器未被改动"; exit 1; }
		U=/usr/share/rpcd/ucode/kelapi; A=/usr/share/rpcd/acl.d/kelapi.json
		cp -f $U /tmp/kelapi.bak; cp -f $A /tmp/kelapi.acl.bak
		cp -f /tmp/kelapi.new $U; cp -f /tmp/kelapi.acl.new $A; chmod 644 $U $A
		/etc/init.d/rpcd restart >/dev/null 2>&1; sleep 7
		if ! ubus -t 15 call kelapi.static get_hostname >/dev/null 2>&1; then
			cp -f /tmp/kelapi.bak $U; cp -f /tmp/kelapi.acl.bak $A; /etc/init.d/rpcd restart >/dev/null 2>&1; sleep 7
			echo "!! 新后端没有起来，已退回原版本（原版本接口：$(ubus -v list kelapi.static 2>/dev/null | wc -l) 行）"; exit 1
		fi
		# 守护脚本：先写到旁边再改名替换，正在运行的那份不受影响，下次被调用时才用新的；不重启代理和广告过滤
		for n in kelclash keladg; do
			cmp -s /tmp/$n.run.new /usr/share/$n/run.sh || { cp -f /tmp/$n.run.new /usr/share/$n/run.sh.new && chmod 755 /usr/share/$n/run.sh.new && mv -f /usr/share/$n/run.sh.new /usr/share/$n/run.sh; echo "   已更新 $n/run.sh"; }
		done
		# 流量统计采集器：语法检查通过才替换；正在跑的进程不动，内核下次重启（或进程被守护重拉）时用新的
		ucode -c -o /dev/null /tmp/kelclash.stats.new && { cmp -s /tmp/kelclash.stats.new /usr/share/kelclash/stats.uc || { cp -f /tmp/kelclash.stats.new /usr/share/kelclash/stats.uc.new && mv -f /usr/share/kelclash/stats.uc.new /usr/share/kelclash/stats.uc; echo "   已更新 kelclash/stats.uc"; }; }
		# 看门狗由 cron 每分钟调用：同样先写旁边再改名替换
		cmp -s /tmp/kel-watchdog.new /usr/sbin/kel-watchdog || { cp -f /tmp/kel-watchdog.new /usr/sbin/kel-watchdog.new && chmod 755 /usr/sbin/kel-watchdog.new && mv -f /usr/sbin/kel-watchdog.new /usr/sbin/kel-watchdog; echo "   已更新 kel-watchdog"; }
		rm -f /tmp/kelapi.new /tmp/kelapi.acl.new /tmp/kelclash.run.new /tmp/keladg.run.new /tmp/kel-watchdog.new /tmp/kelclash.stats.new
		echo "   后端已注册方法：$(ubus -v list kelapi.static 2>/dev/null | grep -c "^	\"")"
	'
fi

if [[ $WHAT == 前端 || $WHAT == 全部 ]]; then
	PKG="$P/前端静态包/kelweb.tar.gz"
	echo "==> 前端：包纯净校验"
	for mark in SDCardTools 存储设置 web_storage_exter_get_all web_storage_inter_get_mode 内置存储大小; do
		tar xzOf "$PKG" 2>/dev/null | grep -q -- "$mark" && { echo "!! 前端包仍含脏标记「$mark」，拒绝部署"; exit 1; }
	done
	tar tzf "$PKG" | grep -qE '\.orig$|\._|\.DS_Store' && { echo "!! 前端包混入了 .orig / macOS 垃圾文件，拒绝部署"; exit 1; }
	# 已废弃的文件清单取自 打包前端.py 的 REMOVED（唯一来源）
	REMOVED=$(uv run --no-project python -c "import re,sys;s=open(sys.argv[1],encoding='utf-8').read();print(' '.join(re.findall(r'\"([^\"]+)\"',re.search(r'REMOVED = \[(.*?)\]',s,re.S).group(1))))" "$T/打包前端.py")
	put "$PKG" /tmp/kelweb.tar.gz
	echo "==> 前端：只替换内容有变化的文件"
	r "
		set -e
		rm -rf /tmp/wwwnew && mkdir -p /tmp/wwwnew && tar xzf /tmp/kelweb.tar.gz -C /tmp/wwwnew
		n=0; cd /tmp/wwwnew
		for f in \$(find . -type f ! -name '._*'); do
			d=\"/www/\${f#./}\"
			if ! cmp -s \"\$f\" \"\$d\"; then mkdir -p \"\$(dirname \"\$d\")\"; cp -f \"\$f\" \"\$d\"; n=\$((n+1)); fi
		done
		cd /; rm -rf /tmp/wwwnew /tmp/kelweb.tar.gz
		chmod 755 /www/cgi-bin/* 2>/dev/null || true
		for f in $REMOVED; do rm -f \"/www/\$f\"; done
		echo \"   更新文件：\$n 个；/www 文件数：\$(find /www -type f | wc -l)；可写区剩余：\$(df -k /overlay | awk 'NR==2{print \$4}')KB\"
		wget -q -O /tmp/.idx http://127.0.0.1/ && grep -q Keel /tmp/.idx && echo '   首页自检 OK' || echo '!! 首页自检异常'; rm -f /tmp/.idx
	"
fi
echo "==> 完成（未触碰网络）。已推送的提交：$(git -C "$P" log --oneline -1)"
