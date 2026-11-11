#!/bin/sh
# 对新增/高风险写接口发非法参数和 shell 注入串：必须被拒绝、不产生副作用（不创建 /tmp/pwn、配置不变）。
rm -f /tmp/pwn; for c in kelclash keladg firewall dhcp; do uci export $c | md5sum > /tmp/inj.$c; done
P=0; F=0
t() { # t 说明 方法 参数 期望状态(逗号分隔可接受值)
	r=$(ubus call kelapi.static "$2" "$3" 2>&1 | tr -d '\n\t'); s=$(echo "$r" | jsonfilter -e '@.status' 2>/dev/null)
	case ",$4," in *",${s:-ERR},"*) P=$((P+1)); echo "PASS $1 -> status=${s:-ERR}";; *) F=$((F+1)); echo "FAIL $1 -> $r";; esac; }
U="$(uci get kelclash.main.sub_url)"
t "clash 订阅链接含 \$(…)"         web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"rule\",\"scope\":\"all\",\"sub_url\":\"https://x.com/\$(touch /tmp/pwn)\"}" 2
t "clash 订阅链接含反引号"          web_set_clash '{"enabled":"1","transparent":"1","mode":"rule","scope":"all","sub_url":"https://x.com/`touch /tmp/pwn`"}' 2
t "clash 模式非法"                  web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"x;reboot\",\"scope\":\"all\",\"sub_url\":\"$U\"}" 2
t "clash 范围非法"                  web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"rule\",\"scope\":\"me\",\"sub_url\":\"$U\"}" 2
t "clash 指定设备但 MAC 非法"       web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"rule\",\"scope\":\"some\",\"client_macs\":\"zz:zz;touch /tmp/pwn\",\"sub_url\":\"$U\"}" 5
t "clash 自定义规则含注入"          web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"rule\",\"scope\":\"all\",\"sub_url\":\"$U\",\"rules_text\":\"DOMAIN,a.com;touch /tmp/pwn,DIRECT\"}" 4
t "clash 自定义规则类型非法"        web_set_clash "{\"enabled\":\"1\",\"transparent\":\"1\",\"mode\":\"rule\",\"scope\":\"all\",\"sub_url\":\"$U\",\"rules_text\":\"EVIL,a.com,DIRECT\"}" 4
t "clash 选线路名含单引号注入"      web_clash_select "{\"name\":\"x'; touch /tmp/pwn; '\"}" 1,3,4
t "clash 检查订阅 URL 含空格/引号"  web_clash_check_sub '{"url":"https://a.com/ \"; touch /tmp/pwn"}' 2
t "adg 过滤订阅 URL 含 \$()"        web_adg_filter '{"op":"add","url":"https://a.com/$(touch /tmp/pwn)","name":"x"}' 2
t "adg 过滤名字含引号"              web_adg_filter '{"op":"add","url":"https://a.com/x.txt","name":"a\"b"}' 2
t "adg 非法 op"                     web_adg_filter '{"op":"drop","url":"https://a.com/x.txt"}' 2
t "adg 放行域名含分号"              web_adg_allow '{"domain":"a.com;touch /tmp/pwn","mode":"allow"}' 2
t "adg 放行域名含空格"              web_adg_allow '{"domain":"a b.com","mode":"allow"}' 2
t "adg 放行 mode 非法"              web_adg_allow '{"domain":"a.com","mode":"nuke"}' 2
t "adg 域名只有一段(无点)"          web_adg_allow '{"domain":"localhost","mode":"block"}' 2
t "adg 检查域名含注入"              web_adg_check '{"domain":"a.com&x=1;touch /tmp/pwn"}' 2
t "adg 规则含控制字符"              web_adg_rules '{"rules_text":"ok\u0007bad"}' 2
t "adg 规则单行超长"                web_adg_rules "{\"rules_text\":\"$(head -c 600 /dev/zero | tr '\0' a)\"}" 2
t "adg 开关值非法"                  web_set_adg '{"enabled":"2"}' 2
t "adg 强制DNS 值非法"              web_set_adg '{"force_dns":"yes"}' 2
t "adg 查询记录搜索串含注入"        web_adg_querylog '{"search":"a&b=1;touch /tmp/pwn"}' 0
t "ddns 占位符不覆盖旧密码(读侧)"   web_get_ddns '{"ddns_name":"none-such"}' 0
sleep 1
[ -e /tmp/pwn ] && { F=$((F+1)); echo "FAIL 注入成功：/tmp/pwn 被创建！"; rm -f /tmp/pwn; } || { P=$((P+1)); echo "PASS 没有任何注入副作用（/tmp/pwn 不存在）"; }
for c in kelclash keladg firewall dhcp; do [ "$(uci export $c | md5sum)" = "$(cat /tmp/inj.$c)" ] && P=$((P+1)) || { F=$((F+1)); echo "FAIL 配置 $c 被改动"; }; done
echo "合计 PASS=$P FAIL=$F"
