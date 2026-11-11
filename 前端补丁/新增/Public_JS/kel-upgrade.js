/* kel-upgrade.js —— 「路由设置 → 系统」页的「系统升级」（2026-10-13）
   选一个打包好的固件文件 → 上传到路由器内存 → 路由器自己校验、保留配置刷入、重启 → 页面等它回来。
   上传走系统自带的 /cgi-bin/cgi-upload（写到 /tmp/firmware.bin）；其余全部由后端 web_upgrade_local / web_upgrade_start /
   web_upgrade_status（/usr/sbin/kel-upgrade）完成——刷写阶段路由器会断线，页面不参与，只负责如实显示和等待。
   版式沿用本页原厂写法（title-one + partition_line + row list），等待框用 KelUI.hold（原厂 .HintDialog 样式）。 */
(function ($) {
	if (!$ || !$('.block').length) return;
	var sid = $.cookie('sessionid'), file = null, busy = false;
	function ubus(m, a) {
		return $.ajax({ url: '/ubus', type: 'POST', dataType: 'json', contentType: 'application/json', timeout: 60000,
			data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [sid, 'kelapi.static', m, a || {}] })
		}).then(function (r) { return (r.result && r.result[0] === 0) ? (r.result[1] || {}) : $.Deferred().reject(r); });
	}
	function toast(msg, ok) { if (window.parent && window.parent.hintShaed) window.parent.hintShaed(msg, ok ? 'icon-duigouxuanzhong' : 'icon-gantanhao-yuankuang'); }
	function mb(n) { return (n / 1048576).toFixed(1) + ' MB'; }
	$('.block').append(
		'<div class="kel-upgrade-module" style="margin-top:34px">' +
		'<div class="row list"><div class="col-lg-4 col-sm-12 col-xs-12 form_left text-left"><span class="title-one">系统升级</span></div></div>' +
		'<div class="partition_line"></div>' +
		'<div class="row list"><div class="col-lg-2 col-sm-2 col-xs-4 form_left text-left"><span>当前版本</span></div><div class="col-lg-8 col-sm-8 col-xs-12 form_right" style="line-height:44px"><span id="ju_ver" style="color:#333">—</span><span id="ju_last" style="margin-left:14px;font-size:12px"></span></div></div>' +
		'<div class="row list"><div class="col-lg-2 col-sm-2 col-xs-4 form_left text-left"><span>固件文件</span></div><div class="col-lg-8 col-sm-8 col-xs-12 form_right">' +
			'<input type="file" id="ju_file" accept=".bin" style="display:none"><button type="button" class="btn btn-default btn-lg" id="ju_pick" style="outline:none;min-width:150px">选择固件文件</button>' +
			'<span id="ju_name" style="margin-left:14px;color:#333"></span></div></div>' +
		'<div class="row list"><div class="col-lg-4 col-sm-4 col-xs-12 col-lg-offset-2 col-sm-offset-2 form_right"><button type="button" class="btn btn-primary btn-lg btn-block" id="ju_go" style="outline:none" disabled>上传并升级</button></div></div>' +
		'<div class="row list"><div class="col-lg-10 col-sm-10 col-xs-12 col-lg-offset-2 col-sm-offset-2" style="font-size:12px;line-height:20px;color:#999">' +
			'选择为本机打包的固件（文件名形如 openwrt-…-kel-版本号-…-sysupgrade.bin）。升级会保留现有设置；过程中全家断网约 5 分钟，<b style="color:#f04a45;font-weight:500">请不要给路由器断电</b>，也不要关闭本页面。' +
		'</div></div></div>');
	function load() {
		ubus('web_upgrade_status').then(function (d) {
			$('#ju_ver').text(d.current ? d.current : '未知（不是本系统打包的固件）');
			var h = (d.history || []).filter(function (x) { return /booted/.test(x); }).pop();
			$('#ju_last').text(h ? '上次升级 ' + h.slice(0, 16) : '');
		});
	}
	$('#ju_pick').on('click', function () { if (!busy) $('#ju_file').click(); });
	$('#ju_file').on('change', function () {
		file = this.files && this.files[0] || null;
		if (!file) { $('#ju_name').text(''); $('#ju_go').prop('disabled', true); return; }
		var bad = !/\.bin$/i.test(file.name) ? '不是 .bin 固件文件' : (file.size < 1000000 || file.size > 16187392) ? '大小不对，不像是本机的固件' : '';
		$('#ju_name').css('color', bad ? '#f04a45' : '#333').text(file.name + '（' + mb(file.size) + '）' + (bad ? ' —— ' + bad : ''));
		$('#ju_go').prop('disabled', !!bad);
	});
	$('#ju_go').on('click', function () {
		if (busy || !file) return;
		var ver = (file.name.match(/-kel-([0-9.]+)-/) || [])[1] || '';
		if (!ver && !confirm('这个文件名不像是为本系统打包的固件。\n刷入官方固件或别的固件后，这套管理界面会消失。\n\n仍然继续吗？')) return;
		if (!confirm('确定升级' + (ver ? '到 ' + ver : '') + '吗？\n\n· 现有设置会保留\n· 全家断网约 5 分钟\n· 期间不要给路由器断电')) return;
		busy = true;
		var rel = KelUI.hold('正在上传固件…'), fd = new FormData();
		fd.append('sessionid', sid); fd.append('filename', '/tmp/firmware.bin'); fd.append('filedata', file);
		function fail(msg) { busy = false; rel(); toast(msg); }
		$.ajax({ url: '/cgi-bin/cgi-upload', type: 'POST', data: fd, processData: false, contentType: false, dataType: 'json', timeout: 300000,
			xhr: function () { var x = $.ajaxSettings.xhr(); if (x.upload) x.upload.addEventListener('progress', function (e) { if (e.lengthComputable) rel.text('正在上传固件… ' + Math.round(e.loaded * 100 / e.total) + '%'); }); return x; }
		}).then(function (u) {
			if (!u || +u.size !== file.size) return $.Deferred().reject('up');
			rel.text('正在校验固件…');
			return ubus('web_upgrade_local');
		}).then(function (c) {
			if (c.status !== 0) { fail(c.error || '这个文件不是本机可用的固件'); return $.Deferred().reject('handled'); }
			return ubus('web_upgrade_start', { local: '1', ver: ver });
		}).then(function (s) {
			if (s.status !== 0) { fail(s.error || '升级没有启动，请重试'); return; }
			watch(rel, ver);
		}, function (e) { if (e !== 'handled') fail(e === 'up' ? '上传不完整，请重试' : '上传或校验失败，请重试'); });
	});
	/* 路由器自己在做；这里先跟着它的进度显示，等它断线（开始刷写）后改成等它回来 */
	function watch(rel, ver) {
		var t0 = Date.now(), gone = 0, flashing = false, back = 0;
		(function tick() {
			if (!flashing) {
				ubus('web_upgrade_status').then(function (d) {
					gone = 0;
					if (d.phase === 'error') { busy = false; rel(); toast('升级没有进行：' + d.msg + '。系统没有被改动'); return; }
					rel.text(d.msg || '正在准备升级…'); if (d.phase === 'flashing') flashing = true;
					setTimeout(tick, 1500);
				}, function () { if (++gone >= 2) flashing = true; setTimeout(tick, 1500); });
				return;
			}
			var s = Math.round((Date.now() - t0) / 1000);
			rel.text('正在刷写固件并重启，约需 3–5 分钟，请不要断电');
			if (s > 900) { busy = false; rel(); alert('等了 15 分钟路由器还没有回来。\n请确认电脑仍连着路由器，然后手动打开管理地址；仍打不开就需要到路由器旁边处理。'); return; }
			if (s < 45) { setTimeout(tick, 3000); return; }	/* 刚断线的头几十秒不用探测 */
			/* 🔴 「页面又能打开了」不等于「升级成功」：刷写没进行、路由器根本没重启时页面一直打得开；刷写失败退回旧系统时也打得开。
			   以前只要首页能打开两次就提示「升级完成，当前版本 X」（X 取自文件名）。现在问路由器本身（免登录接口）：
			   开机时间比我们等的时间短 = 确实重启过；再看它报的版本是不是目标版本。 */
			$.ajax({ url: '/ubus', type: 'POST', dataType: 'json', contentType: 'application/json', timeout: 4000,
				data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: ['00000000000000000000000000000000', 'kelapi.static', 'get_initialization_info', {}] })
			}).then(function (r) {
				var d = (r.result && r.result[0] === 0) ? (r.result[1] || {}) : null;
				if (!d) { back = 0; setTimeout(tick, 3000); return; }
				if (d.uptime != null && !(+d.uptime > 0 && +d.uptime < s + 30)) {		/* 还是升级前那次开机 */
					back = 0;
					if (s > 300) { busy = false; rel(); alert('路由器一直没有重启：升级没有进行，系统没有被改动。\n可以重新选择固件再试一次。'); load(); return; }
					setTimeout(tick, 3000); return;
				}
				if (++back < 2) { setTimeout(tick, 3000); return; }
				busy = false; rel();
				var now = d.kel_version || '';
				if (ver && d.uptime != null && now !== ver) alert('路由器已经重启，但当前版本是 ' + (now || '未知') + '，不是 ' + ver + '：升级没有成功。\n请重新登录后查看。');
				else alert('升级完成' + ((now || ver) ? '，当前版本 ' + (now || ver) : '') + '。\n请重新登录。');
				top.location.href = 'http://' + location.host + '/index.html';
			}, function () { back = 0; setTimeout(tick, 3000); });
		})();
	}
	load();
})(window.jQuery);
