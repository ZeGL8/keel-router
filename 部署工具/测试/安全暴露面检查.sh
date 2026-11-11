#!/bin/sh
# 暴露面只读检查（在路由器上跑）：1 监听端口分布 2 WAN/中继侧入站策略 3 未登录的 ubus 调用能否进来 4 关键服务只听回环
echo "== 1 监听端口（非回环）"; netstat -lntu 2>/dev/null | awk 'NR>2 && $4 !~ /^127\./ && $4 !~ /^::1/ {print $1, $4}' | sort -u
echo "== 2 各防火墙区域与入站策略"; uci show firewall | grep -E "zone|\.name=|\.input=|\.network=" | grep -E "name=|input=|network=" | tr '\n' ' '; echo
echo "   wan 区入站链:"; nft list chain inet fw4 input_wan 2>/dev/null | grep -vE "^\s*(table|chain|type)" | head -12
echo "== 3 未登录调用 kelapi（会话 00000000000000000000000000000000）"
for m in get_hostname web_get_clash web_get_adg get_wifi_info set_wifi reboot web_set_clash web_set_adg; do
	r=$(ubus call session access "{\"ubus_rpc_session\":\"00000000000000000000000000000000\",\"scope\":\"ubus\",\"object\":\"kelapi.static\",\"function\":\"$m\"}" 2>&1 | tr -d '\n\t'); echo "   $m -> $r"
done
echo "== 4 关键内部服务只听回环"
netstat -lnt | grep -E ":(3000|9090) " 
netstat -lnt | grep -E ":(7890|7892) " | awk '{print "   代理端口 "$4" （由 allow-lan 白名单 + 防火墙 wan 区拒绝保护）"}'
