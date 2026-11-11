#!/usr/bin/ucode
/* Keel UI「取本机 MAC」端点（真实现，2026-09-23）。
 *
 * 背景：原厂固件里 /cgi-bin/get_clientmac.cgi 返回**发起请求的客户端**的
 *     MAC。前端有三处依赖它，缺了会各自静默退化（不会报错，所以最难发现）：
 *       1. PC/routerSet/internet.js   「MAC地址克隆」输入框 #macaddr 的预填值
 *          —— 拿不到就永远空着（原厂是预填好、点一下「克隆」即可）；
 *       2. PC/management/deviceList.js 在线设备列表里的「本机」蓝标
 *          —— 拿不到就不标；
 *       3. PC/management/access.js    「把本机加入黑/白名单」的种子 MAC
 *          —— 拿不到时前端硬编码降级成 00:00:00:00:00:00，逻辑直接跳过。
 *     OpenWrt 上这个文件不存在 → 404 → 上述三处全部失效。
 *
 * 实现：取 CGI 环境里的 REMOTE_ADDR（uhttpd 会设），按 IP 查 /proc/net/arp
 *     拿 MAC，查不到再退回 `ip neigh`。**纯只读，不碰任何配置、不改网络。**
 *     输出大小写按后端 normMac() 的规范用**大写**——与
 *     web_get_device_list[].id（如 02:00:00:00:00:01）保持一致。
 *
 * 注意：
 *   - ARP 表里 Flags=0x0 的行 MAC 是 00:00:00:00:00:00，必须跳过，
 *     否则会把这个假 MAC 当成本机 MAC 交给前端；
 *   - 最终拿不到时返回**空串**（前端各自有空值分支），绝不返回全零 MAC；
 *   - uhttpd 配了 rfc1918_filter=1，外网打不到这个端点。
 */
'use strict';

import { popen } from 'fs';

function sh(cmd) {
	let f = popen(cmd, 'r');
	if (f == null) return '';
	let s = '' + (f.read('all') ?? '');
	f.close();
	return s;
}

function out(mac) {
	print('Content-Type: text/plain; charset=utf-8\r\n');
	print('Cache-Control: no-store\r\n\r\n');
	print(mac);
	exit(0);
}

/* /proc/net/arp 里按 IP 找 MAC */
function arpMac(ip) {
	for (let line in split(sh('cat /proc/net/arp'), '\n')) {
		let c = split(trim('' + line), /\s+/);
		if (length(c) < 4 || c[0] !== ip) continue;
		let m = uc(c[3]);
		if (m === '00:00:00:00:00:00') continue;	/* Flags=0x0 的占位行 */
		return m;
	}
	return '';
}

/* 兜底：邻居表（IPv4 / IPv6 通用） */
function neighMac(ip, v6) {
	let txt = sh("ip " + (v6 ? '-6 ' : '') + "neigh show '" + ip + "' 2>/dev/null");
	for (let line in split(txt, '\n')) {
		let c = split(trim('' + line), /\s+/);
		if (length(c) < 5) continue;
		let m = uc(c[4]);
		if (match(m, /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/)) return m;
	}
	return '';
}

const MACRE = /^([0-9A-F]{2}:){5}[0-9A-F]{2}$/;

let ip = trim('' + (getenv('REMOTE_ADDR') ?? ''));
let v6 = (index(ip, ':') >= 0);
if (ip === '' || (!v6 && !match(ip, /^[0-9]{1,3}(\.[0-9]{1,3}){3}$/)))
	out('');

let mac = v6 ? '' : arpMac(ip);
if (!match(mac, MACRE)) mac = neighMac(ip, v6);
if (!match(mac, MACRE)) mac = '';

out(mac);
