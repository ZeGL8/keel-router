/* kel-adv.js —— 高级功能各页的「家庭用户友好」增强（DDNS / 端口转发 / DMZ / UPnP / NAT / Hosts）
   只做展示层：页面标题+一句话用途、字段旁边的说明、从设备列表选择目标设备；不改原页面的保存逻辑。 */
(function () {
	var $ = window.$; if (!$) return;
	var page = (location.pathname.split('/').pop() || '').replace(/[.?].*$/, '').toLowerCase();
	var META = {
		ddns: ['固定访问域名（DDNS）', '家里的上网地址经常会变。DDNS 会把它和一个固定域名绑在一起，之后在外面用这个域名就能找到家里的路由器。'],
		portforward: ['从外网访问家中设备（端口转发）', '让外面的人（或你自己出门后）能访问家里某台设备上的服务，例如 NAS、摄像头。需要你的宽带有公网地址；如果上级还有一台光猫在拨号，还要在光猫里也设置一次。'],
		dmz: ['把外网访问转交给一台设备（DMZ）'],
		upnp: ['应用自动申请端口（UPnP）', '打开后，游戏、下载软件等可以自己向路由器申请需要的端口，不用手动设置。下面列出的是它们当前申请的端口；列表为空表示暂时没有应用申请，不代表出错。'],
		natset: ['网络连接兼容性（NAT）', '一般保持默认即可；只有联机游戏提示「NAT 类型受限」时才需要改。'],
		customhosts: ['自定义域名指向（Hosts）']
	};
	var m = META[page]; if (!m) return;
	$('head').append('<style>.kel-intro{color:#8a90a2;font-size:14px;line-height:22px;margin:10px 0 22px;max-width:860px}.kel-help{color:#8a90a2;font-size:12px;line-height:18px;margin:4px 0 0 0;clear:both}.kel-pick{display:flex;align-items:center;margin:0 0 20px}.kel-pick .l{flex:none;width:137px;color:#888;font-size:14px;font-weight:600}.kel-sel{height:36px;width:340px;max-width:100%;border:1px solid #ddd;border-radius:6px;padding:0 10px;background:#fff;font-size:14px}</style>');
	var top = $('.seniorManagement_top').first();
	var sp = top.find('span').first(); (sp.length ? sp : top).text(m[0]);
	if (m[1] && !top.next('.kel-intro').length) top.after('<p class="kel-intro">' + m[1] + '</p>');

	if (page === 'ddns') {
		$('.no-data').text('还没有添加服务。点击下方「添加服务」，选择你的域名服务商并填写账号信息。');
		$('#password').closest('.proDialog_content_div_ip').after('<div class="kel-help" style="margin:-8px 0 12px 137px">出于安全，已保存的密码不会显示；编辑时不想改密码，保持不动即可。</div>');
		$('#statusCheck').closest('.proDialog_content_div_ip').after('<div class="kel-help" style="margin:-8px 0 12px 137px">每隔多久检查一次上网地址有没有变化。</div>');
		$('#duressUpdate').closest('.proDialog_content_div_ip').after('<div class="kel-help" style="margin:-8px 0 12px 137px">即使地址没变，也每隔这么久重新登记一次，避免服务商认为你已离线。</div>');
	}
	if (page === 'natset') {
		/* 本固件内核没有 fullcone 模块，NAT1 无法开启（后端会明确拒绝）：不给用户一个点了必失败的选项 */
		$('.NETSet_label_mode[target=1]').css({ opacity: .45, pointerEvents: 'none' }).attr('title', '本路由器的系统不支持 NAT1').css({ width: 'auto', whiteSpace: 'nowrap', paddingRight: '14px' }).append('<span class="kel-help" style="display:inline;margin-left:8px">（不支持）</span>');
	}
	if (page === 'portforward') {
		$('#outPort').closest('.proDialog_content_div_ip').append('<div class="kel-help" style="margin-left:137px">互联网上的人访问你家时使用的端口。</div>');
		$('#insidePort').closest('.proDialog_content_div_ip').append('<div class="kel-help" style="margin-left:137px">设备上实际提供服务的端口，通常和外部端口相同。</div>');
	}

	/* 端口转发 / DMZ：从设备列表选目标设备，代替手敲 IP 尾号 */
	if (page === 'portforward' || page === 'dmz') {
		var sid = $.cookie && $.cookie('sessionid');
		var row = $('#DMZIpAddr').closest('.proDialog_content_div_ip, .seniorManagement_content_div');
		if (sid && row.length) {
			var box = $('<div class="kel-pick"><span class="l">选择设备</span><select class="kel-sel"><option value="">读取设备列表…</option></select></div>');
			row.before(box);
			/* 目标行被原页面隐藏时（如 DMZ 关闭）选择框跟着隐藏 */
			setInterval(function () { box.toggle(row.css('display') !== 'none'); }, 400);
			$.ajax({ url: '/ubus', type: 'POST', dataType: 'json', contentType: 'application/json',
				data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [sid, 'kelapi.static', 'web_get_device_list', {}] })
			}).done(function (r) {
				var list = (r.result && r.result[1] && r.result[1].device_list) || [], sel = box.find('select');
				var html = '<option value="">— 或在右边手动填写 —</option>';
				list.forEach(function (d) { if (d.online === '1' && d.is_guest !== 1 && d.ip) html += '<option value="' + d.ip + '">' + $('<div>').text(d.name).html() + '（' + d.ip + '）</option>'; });
				sel.html(html);
				sel.on('change', function () {
					var ip = this.value, pre = $.trim($('.DMZIpAddr_sp i').first().text());
					if (!ip) return;
					if (pre && ip.indexOf(pre) === 0) $('#DMZIpAddr').val(ip.slice(pre.length)).trigger('input').trigger('change').trigger('blur');
				});
			}).fail(function () { box.find('select').html('<option value="">读取设备列表失败，请手动填写</option>'); });
		}
	}
})();
