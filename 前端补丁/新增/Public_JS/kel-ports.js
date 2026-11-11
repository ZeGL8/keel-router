/* kel-ports.js —— 「网口自定义」页的网口设置（2026-09-27）
 *
 * 原厂该页在本机上只有 IPTV（原厂专有，已裁），网口信息只能看不能改。
 * 这里补上可操作的网口设置，全部落在 OpenWrt 的 uci network（后端 set_wire_port）：
 *   · 用途：局域网（br-lan）/ 访客网络（br-guest，与主网隔离）/ 关闭
 *   · 速率：自动协商 / 限 100M / 限 10M（netifd device speed/duplex，排查网线用）
 *   · WAN 口只能调速率，用途不可改（改了就断网）
 * 保护：后端按桥 FDB 判断你正通过哪个口连着，拒绝把它改成访客/关闭（status 3）。
 */
(function ($) {
	var sid = $.cookie('sessionid');
	var host = $.cookie('HostAddrIP') || location.host;

	/* 用数组保序：对象里 "100"/"10" 这种数字键会被 JS 排到最前 */
	var ROLE = [['wan', 'WAN（上网口）'], ['lan', '局域网'], ['guest', '访客网络'], ['off', '关闭']];
	var SPEED = [['auto', '自动协商'], ['100', '限速 100M'], ['10', '限速 10M']];

	function ubus(method, args) {
		return $.ajax({
			url: 'http://' + host + '/ubus', type: 'POST', dataType: 'json',
			contentType: 'application/json',
			data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call',
				params: [sid, 'kelapi.static', method, args || {}] })
		}).then(function (r) {
			if (r.error && r.error.code == -32002) {
				top.location.href = 'http://' + location.host + '/index.html';
				return $.Deferred().reject();
			}
			return (r.result && r.result[0] === 0) ? (r.result[1] || {}) : $.Deferred().reject();
		});
	}
	function hint(msg, ok) {
		if (window.parent && window.parent.hintShaed)
			window.parent.hintShaed(msg, ok ? 'icon-duigouxuanzhong' : 'icon-gantanhao-yuankuang');
	}
	/* 物理口名（面板丝印）：板级 WAN 口叫「WAN口」，其余 LANn；当前角色看「用途」列 */
	function portName(p) { return p.sp_name === 'wan' ? 'WAN口' : 'LAN' + p.sp_name; }
	function linkText(p) {
		if (!p.carrier) return '<span style="color:#999">未连接</span>';
		var m = /^(\d+)([FH]?)$/.exec(p.link || '');
		return '<span style="color:#22b573">' + (m ? m[1] + 'Mbps' + (m[2] === 'H' ? ' 半双工' : '') : '已连接') + '</span>';
	}
	function sel(cls, opts, cur, disabled) {
		var h = '<select class="jp-sel ' + cls + '"' + (disabled ? ' disabled' : '') + '>';
		for (var i = 0; i < opts.length; i++)
			h += '<option value="' + opts[i][0] + '"' + (opts[i][0] === cur ? ' selected' : '') + '>' + opts[i][1] + '</option>';
		return h + '</select>';
	}

	var myMac = '';
	function render(list) {
		var rows = '';
		list.sort(function (a, b) { return a.sp_name === 'wan' ? -1 : b.sp_name === 'wan' ? 1 : (+a.sp_name) - (+b.sp_name); });
		$.each(list, function (_, p) {
			var wan = p.role === 'wan';
			rows += '<tr data-port="' + p.ifname + '" data-name="' + portName(p) + '" data-role="' + p.role +
				'" data-speed="' + p.speed_cfg + '">' +
				'<td class="jp-name">' + portName(p) + (wan ? '<span class="jp-tag">上网口</span>' : '') + '</td>' +
				'<td>' + linkText(p) + '</td>' +
				'<td>' + sel('jp-role', ROLE, p.role, wan) + '</td>' +
				'<td>' + sel('jp-speed', SPEED, p.speed_cfg) + '</td>' +
				'<td class="jp-op"><button type="button" class="jp-save" disabled>保存</button></td></tr>';
		});
		$('#kel_ports tbody').html(rows);
		/* 顶部面板：按面板丝印顺序画出网口，颜色表示连接、角标表示用途 */
		var tag = { wan: 'WAN', lan: '局域网', guest: '访客', off: '关闭' };
		var panel = '';
		$.each(list.slice().sort(function (a, b) {
			return a.sp_name === 'wan' ? 1 : b.sp_name === 'wan' ? -1 : (+a.sp_name) - (+b.sp_name);
		}), function (_, p) {
			panel += '<div class="jp-port' + (p.role === 'wan' ? ' jp-port-wan' : '') + (p.role === 'off' ? ' jp-port-off' : '') + '">' +
				'<div class="jp-port-name">' + portName(p) + '</div>' +
				'<img src="../../P_IMG/' + (p.carrier ? 'lan-green.png' : 'lan-gray.png') + '">' +
				'<div class="jp-port-role">' + tag[p.role] + '</div>' +
				'<div class="jp-port-link">' + linkText(p) + '</div></div>';
		});
		$('#kel_port_panel').html(panel);
	}
	function load() { return ubus('get_wire_ports_info').then(function (d) { render(d.wan_lan_info || []); }); }

	$(function () {
		$('head').append('<style>' +
			'.kel-ports table{width:100%;table-layout:fixed;border-collapse:separate;border-spacing:0;border:1px solid #eee;border-radius:6px;font-size:14px}' +
			'.kel-ports th{background:#f7f8fa;color:#666;font-weight:400;text-align:left;padding:12px 20px;height:44px}' +
			'.kel-ports td{padding:0 20px;height:60px;border-top:1px solid #eee;color:#333;vertical-align:middle}' +
			'.kel-ports th:last-child,.kel-ports td.jp-op{text-align:right}' +
			'.kel-ports .jp-sel{width:100%;max-width:170px;height:34px;padding:0 10px;border:1px solid #ddd;border-radius:4px;background:#fff;color:#333}' +
			'.kel-ports .jp-sel:disabled{background:#f5f5f5;color:#999;cursor:not-allowed}' +
			'.kel-ports .jp-tag{display:inline-block;margin-left:8px;padding:0 6px;line-height:18px;font-size:12px;color:#4762FE;border:1px solid #4762FE;border-radius:3px}' +
			'.kel-ports .jp-save{min-width:72px;height:32px;background:#4762FE;color:#fff;border:0;border-radius:4px;cursor:pointer}' +
			'.kel-ports .jp-save:disabled{background:#c8d0ff;cursor:default}' +
			'.kel-ports .jp-note{color:#999;font-size:13px;line-height:22px;margin:14px 0 0;padding-left:16px}' +
			'.kel-ports .jp-note li{list-style:disc}' +
			'.kel-ports .jp-panel{display:flex;justify-content:center;gap:48px;padding:28px 0 24px;margin-bottom:20px;border:1px solid #eee;border-radius:6px;background:#fafbfc}' +
			'.kel-ports .jp-port{width:96px;text-align:center;font-size:13px}' +
			'.kel-ports .jp-port img{display:block;width:56px;height:56px;margin:10px auto;object-fit:contain}' +
			'.kel-ports .jp-port-name{color:#333;font-weight:500}' +
			'.kel-ports .jp-port-role{display:inline-block;padding:0 8px;line-height:20px;border-radius:10px;background:#eef0f5;color:#666;font-size:12px}' +
			'.kel-ports .jp-port-wan .jp-port-role{background:#4762FE;color:#fff}' +
			'.kel-ports .jp-port-off{opacity:.55}' +
			'.kel-ports .jp-port-link{margin-top:6px;font-size:12px}' +
			'.network-port{display:none!important}' +
			'</style>');
		var box = $('<div class="kel-ports">' +
			'<div class="seniorManagement_top DMZ_top">网口设置</div>' +
			'<div class="seniorManagement_content" style="padding-top:16px">' +
			'<div class="jp-panel" id="kel_port_panel"></div>' +
			'<table id="kel_ports"><colgroup><col style="width:18%"><col style="width:18%"><col style="width:24%"><col style="width:24%"><col style="width:16%"></colgroup>' +
			'<thead><tr><th>网口</th><th>连接状态</th><th>用途</th><th>速率</th><th>操作</th></tr></thead><tbody></tbody></table>' +
			'<ul class="jp-note">' +
			'<li>任一网口都可设为 WAN（上网口）；要更换上网口，请把新的口设为 WAN，原上网口会自动关闭。</li>' +
			'<li>「访客网络」口接入的设备与主网隔离，仅能上网；「关闭」后该口不工作。</li>' +
			'<li>你当前连接所用的网口不能改为 WAN、访客或关闭；限速仅用于排查网线/设备兼容问题。</li>' +
			'</ul></div></div>');
		$('.network-port').after(box);
		$.ajax({ url: '/cgi-bin/get_clientmac.cgi', type: 'POST', dataType: 'text' })
			.done(function (t) { myMac = $.trim(t || ''); });
		load();

		/* 有改动才可保存，避免误点、也让"改了没保存"一目了然 */
		$('#kel_ports').on('change', '.jp-sel', function () {
			var tr = $(this).closest('tr');
			tr.find('.jp-save').prop('disabled',
				tr.find('.jp-role').val() === tr.data('role') && tr.find('.jp-speed').val() === String(tr.data('speed')));
		});
		$('#kel_ports').on('click', '.jp-save', function () {
			var tr = $(this).closest('tr'), btn = $(this);
			var args = { port: tr.data('port'), speed: tr.find('.jp-speed').val(), client_mac: myMac };
			var role = tr.find('.jp-role').val();
			if (!tr.find('.jp-role').prop('disabled')) args.role = role;
			if (args.role === 'wan' && tr.data('role') !== 'wan') {
				var old = $('#kel_ports tr[data-role=wan]').data('name') || '原上网口';
				if (!confirm('将把上网口改为「' + tr.data('name') + '」。\n\n' +
					'· 外网会中断几秒；\n· 请把光猫/上级网线从「' + old + '」拔下，插到「' + tr.data('name') + '」；\n' +
					'· 「' + old + '」会被设为「关闭」，网线挪好后可再把它设为局域网。\n\n确定修改吗？')) return;
			}
			btn.prop('disabled', true).text('保存中');
			ubus('set_wire_port', args).then(function (r) {
				var msg = { 0: '配置成功', 1: '参数错误', 2: '当前上网口不能直接改用途，请把其它口设为 WAN',
					3: '你正通过该网口连接路由器，不能改为 WAN/访客/关闭', 4: '访客网络初始化失败',
					5: '至少要保留一个局域网口' };
				hint(msg[r.status] || '配置失败', r.status === 0);
				/* netifd 重载后链路要几秒才稳定，稍候刷新状态 */
				setTimeout(load, r.status === 0 ? 3000 : 0);
			}, function () { hint('系统错误，请重新操作'); btn.prop('disabled', false); })
			.always(function () { btn.text('保存'); });
		});
	});
})(jQuery);
