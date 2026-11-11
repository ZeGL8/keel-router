#!/usr/bin/ucode
/* stats.uc —— 代理流量统计采集（常驻进程，由 kelclash 守护拉起和看管）
 *
 * 统计「走了代理的流量」（出口不是 DIRECT/REJECT 的连接），按天、按设备累计。
 *
 * 怎么算（为什么这样算）：
 *   mihomo 的 /connections 给出：① 精确的累计总量（含已关闭的连接）；② 活动连接各自的 upload/download 和 chains
 *   （chains[0] 是真正的出口：节点名 = 走了代理，DIRECT = 直连）。
 *   只累加活动连接的差值会漏掉「两次采样之间开了又关」的短连接（网页加载全是这种），所以：
 *     本区间精确总量 = 总量增量；已看到的 = 各连接差值之和；余量（没看到的）按本区间「已看到部分」的代理占比分摊。
 *   总量是精确的，只有占比是估算。设备分摊按同一比例放大。
 *
 * 存储：内存 /tmp/kelclash/stats.json（30 秒一写），闪存 /etc/kelclash/stats.json（30 分钟一写，只有内容变了才写，几 KB）。
 *       最多保留 62 天。时钟没校准（年份 < 2026）时先记在 pending，校准后并入当天。
 * 采样间隔 2 秒；单次采样耗时长（连接很多、CPU 紧）就自动放慢，绝不和转发抢 CPU。
 */
import { popen, readfile, writefile, rename, stat } from 'fs';

const D = '/tmp/kelclash', RAM = D + '/stats.json', FLASH_DIR = '/etc/kelclash', FLASH = FLASH_DIR + '/stats.json';
const KEEP_DAYS = 62, POLL_MS = 2000, RAM_EVERY = 30, FLASH_EVERY = 1800, ARP_EVERY = 30;
/* 测试用：KEL_STATS_FETCH 可以换成别的取数命令；正式运行取 mihomo 的管理接口 */
const FETCH_OVERRIDE = getenv('KEL_STATS_FETCH');

function sh1(cmd) {
	let p = popen(cmd, 'r');
	if (!p) return '';
	let s = p.read('all');
	p.close();
	return s ?? '';
}

let secret = trim(sh1('uci -q get kelclash.main.secret'));
if (!FETCH_OVERRIDE && match(secret, /^[0-9a-f]{16,64}$/) == null) {
	warn('kelclash stats: 没有有效的控制口密钥，退出\n');
	exit(1);
}
const FETCH = FETCH_OVERRIDE ?? ("curl -s -m 4 -H 'Authorization: Bearer " + secret + "' http://127.0.0.1:9090/connections");

function newState() { return { v: 1, days: {}, total: { pu: 0, pd: 0 } }; }
function load(p) {
	try { let j = json(readfile(p)); if (j?.v === 1 && type(j.days) == 'object') return j; } catch (e) {}
	return null;
}
let st = load(RAM) ?? load(FLASH) ?? newState();

function dayKey() {
	let t = localtime(time());
	return (t.year < 2026) ? 'pending' : sprintf('%04d%02d%02d', t.year, t.mon, t.mday);
}
function bucket(k) {
	if (st.days[k] == null) st.days[k] = { pu: 0, pd: 0, du: 0, dd: 0, dev: {} };
	return st.days[k];
}
function flushPending() {
	let p = st.days['pending'];
	if (p == null) return;
	let k = dayKey();
	if (k == 'pending') return;
	let b = bucket(k);
	b.pu += p.pu; b.pd += p.pd; b.du += p.du; b.dd += p.dd;
	for (let m in keys(p.dev)) {
		let e = b.dev[m] ?? [0, 0];
		b.dev[m] = [e[0] + p.dev[m][0], e[1] + p.dev[m][1]];
	}
	delete st.days['pending'];
}
function prune() {
	let ks = sort(filter(keys(st.days), (k) => k != 'pending'));
	while (length(ks) > KEEP_DAYS) delete st.days[shift(ks)];
}

/* 源地址 → MAC（设备按 MAC 记，DHCP 换地址、IPv6 隐私地址轮换都不会拆成多个设备） */
let ip2mac = {}, arpAt = 0;
function refreshArp() {
	let m = {};
	/* /proc/net/arp 各列：IP、类型、flags、MAC、掩码、网卡；flags 为 0x0 的是失效条目 */
	for (let l in split(readfile('/proc/net/arp') ?? '', '\n')) {
		let f = split(trim(l), /\s+/);
		if (length(f) >= 6 && f[2] != '0x0' && match(f[3], /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i) != null) m[f[0]] = lc(f[3]);
	}
	for (let l in split(sh1('ip -6 neigh show 2>/dev/null'), '\n')) {
		let mm = match(l, /^(\S+) dev \S+ lladdr (([0-9a-f]{2}:){5}[0-9a-f]{2})/i);
		if (mm != null) m[mm[1]] = lc(mm[2]);
	}
	ip2mac = m; arpAt = time();
}
function who(ip) { return ip2mac[ip] ?? (ip == '' ? 'unknown' : ip); }

function proxied(ch) {
	let a = (type(ch) == 'array' && length(ch) > 0) ? ch[0] : '';
	return a != '' && a != 'DIRECT' && a != 'REJECT' && a != 'REJECT-DROP' && a != 'COMPATIBLE' && a != 'PASS';
}

let prev = null, pTU = 0, pTD = 0;		/* prev: id → [up, down]；null = 还没有基线 */
let ratioU = 0, ratioD = 0;				/* 上一个有数据的区间的代理占比，没有「已看到」数据时用它分摊余量 */
let dirty = false, lastRam = 0, lastFlash = 0, wait = POLL_MS;

function step(snap) {
	let conns = snap.connections ?? [];
	let tu = snap.uploadTotal ?? 0, td = snap.downloadTotal ?? 0;
	let cur = {};
	if (prev == null) {		/* 第一次：只建基线，之前已经传过的字节不算 */
		for (let c in conns) cur[c.id] = [c.upload ?? 0, c.download ?? 0];
		prev = cur; pTU = tu; pTD = td;
		return;
	}
	if (tu < pTU || td < pTD) { prev = {}; pTU = 0; pTD = 0; }		/* 内核重启过：总量清零了 */
	let dTU = tu - pTU, dTD = td - pTD;
	let sPu = 0, sPd = 0, sDu = 0, sDd = 0, dev = {};
	for (let c in conns) {
		let u = c.upload ?? 0, d = c.download ?? 0;
		cur[c.id] = [u, d];
		let p = prev[c.id];
		let du = (p == null) ? u : (u >= p[0] ? u - p[0] : 0);
		let dd = (p == null) ? d : (d >= p[1] ? d - p[1] : 0);
		if (proxied(c.chains)) {
			sPu += du; sPd += dd;
			let w = who(c.metadata?.sourceIP ?? '');
			let e = dev[w] ?? [0, 0];
			dev[w] = [e[0] + du, e[1] + dd];
		} else {
			sDu += du; sDd += dd;
		}
	}
	prev = cur; pTU = tu; pTD = td;
	if (dTU <= 0 && dTD <= 0) return;

	/* 精确总量里分出代理部分：已看到的 + 余量按占比分摊（看到的比总量还多——时间点错位——就按比例缩小） */
	let sU = sPu + sDu, sD = sPd + sDd;
	/* ucode 的 / 对整数是整数除法（200/300 得 0），占比必须乘 1.0 变成浮点 */
	if (sU > 0) ratioU = sPu * 1.0 / sU;
	if (sD > 0) ratioD = sPd * 1.0 / sD;
	let Pu = (sU > dTU) ? (sU > 0 ? sPu * dTU / sU : 0) : sPu + (dTU - sU) * ratioU;
	let Pd = (sD > dTD) ? (sD > 0 ? sPd * dTD / sD : 0) : sPd + (dTD - sD) * ratioD;
	Pu = int(Pu); Pd = int(Pd);

	let k = dayKey();
	let b = bucket(k);
	b.pu += Pu; b.pd += Pd; b.du += dTU - Pu; b.dd += dTD - Pd;
	st.total.pu += Pu; st.total.pd += Pd;
	let ku = (sPu > 0) ? Pu * 1.0 / sPu : 1, kd = (sPd > 0) ? Pd * 1.0 / sPd : 1;
	for (let w in keys(dev)) {
		let e = b.dev[w] ?? [0, 0];
		b.dev[w] = [e[0] + int(dev[w][0] * ku), e[1] + int(dev[w][1] * kd)];
	}
	/* 分摊出来的余量（没法归到具体设备）记在 other，设备合计才等于总量 */
	let devU = 0, devD = 0;
	for (let w in keys(dev)) { devU += int(dev[w][0] * ku); devD += int(dev[w][1] * kd); }
	if (Pu - devU > 0 || Pd - devD > 0) {
		let e = b.dev['other'] ?? [0, 0];
		b.dev['other'] = [e[0] + max(0, Pu - devU), e[1] + max(0, Pd - devD)];
	}
	dirty = true;
}

function save() {
	let now = time();
	flushPending();
	if (dirty && now - lastRam >= RAM_EVERY) {
		prune();
		let s = sprintf('%J', st);
		writefile(RAM + '.new', s); rename(RAM + '.new', RAM);
		lastRam = now;
		if (now - lastFlash >= FLASH_EVERY) {
			let free = int(trim(sh1("df -k /overlay 2>/dev/null | awk 'NR==2{print $4}'"))) || 0;
			if (free > 400 && stat(FLASH_DIR) != null && s != readfile(FLASH)) {
				writefile(FLASH + '.new', s); rename(FLASH + '.new', FLASH);
			}
			lastFlash = now;
		}
		dirty = false;
	}
}

refreshArp();
lastFlash = time();		/* 启动时刚读过闪存，不用马上又写 */
for (;;) {
	let t0 = clock(true);
	try {
		if (time() - arpAt >= ARP_EVERY) refreshArp();
		let out = sh1(FETCH);
		let snap = (out != '') ? json(out) : null;
		if (snap != null) step(snap); else prev = null;		/* 取不到（内核重启中）：下次重新建基线 */
		save();
	} catch (e) {
		warn('kelclash stats: ' + e + '\n');
		prev = null;
	}
	let t1 = clock(true), ms = (t1[0] - t0[0]) * 1000 + (t1[1] - t0[1]) / 1000000;
	wait = max(POLL_MS, int(ms * 10));		/* 单次耗时 ≤ 20% 的 CPU */
	sleep(min(wait, 20000));
}
