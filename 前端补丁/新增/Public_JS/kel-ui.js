/* 操作反馈层（代理加速 / 广告过滤页共用）——沿用原厂页面的做法：
   原厂（Wi-Fi 设置、上网设置等）保存时在页面正中弹出带遮罩的「加载中…」转圈框（hint.js 的 startLoading /
   hintProgressBar），完成后换成「配置成功」。这里用同一套样式（.HintDialog / .blackMask / .hintRadius，在顶层窗口里），
   区别只是：文字说明正在做什么，并且等到**真的完成**才关，而不是原厂那样固定等 N 秒。
   · 所有发往 /ubus 的写操作：超过 0.35 秒还没回来就弹出（很快的操作不闪一下）；
   · 需要后台生效的操作（热重载内核等）：页面用 KelUI.hold('文字') 主动挂起，生效后调用返回的函数关闭；
   · 被点的按钮同时置灰，防重复提交。 */
(function ($) {
	if (!$ || window.KelUI) return;
	var TEXT = {
		web_set_clash: '正在保存…', web_clash_mode: '正在切换分流方式…', web_clash_rules_update: '正在更新规则集，约需 10–30 秒…',
		web_clash_select: '正在切换节点…', web_clash_check_sub: '正在检查订阅…', web_clash_diagnose: '正在自检…', web_clash_refresh: '正在更新订阅…',
		web_set_adg: '正在保存…', web_adg_filter: '正在处理规则列表，下载规则最长约 1 分钟…', web_adg_rules: '正在保存规则…', web_adg_allow: '正在保存…',
		web_adg_diagnose: '正在自检…'
	};
	var T = null; try { T = window.top.jQuery; } catch (e) {} if (!T) T = $;
	var holds = [], pending = 0, showT = 0, tick = 0, since = 0, lastEl = null, lastAt = 0, marked = [];
	function isRead(m) { return /^web_get/.test(m) || /^web_(adg_(querylog|check|events)|clash_(live|nodes|events|logs|rules$))/.test(m); }
	function label() { return holds.length ? holds[holds.length - 1].text : (pending ? pendingText : ''); }
	var pendingText = '正在保存…';
	function paint() {
		var txt = label(); if (!txt) return;
		if (!T('.kel-wait').length) {
			T('body').append('<div class="HintDialog kel-wait"><div><table class="Hinttable"><tbody><tr><td class="hintDialogIcon" style="padding-top:16px;padding-bottom:16px"><span class="hintRadius"></span></td><td style="padding-left:16px"><span class="hintDialogText"></span></td></tr></tbody></table></div></div><div class="blackMask kel-wait"></div>');
			T('.blackMask.kel-wait').show();
		}
		var s = Math.round((Date.now() - since) / 1000);
		T('.HintDialog.kel-wait .hintDialogText').text(txt + (s >= 4 ? '（已 ' + s + ' 秒）' : ''));
		var $d = T('.HintDialog.kel-wait'), W = T(window.top);
		$d.css({ left: (W.width() - $d.width()) / 2 + 'px', top: (W.height() - $d.height()) / 2 + T(window.top.document).scrollTop() + 'px', display: 'block' });
	}
	function sync() {
		if (holds.length || pending) {
			if (!since) since = Date.now();
			if (holds.length) { clearTimeout(showT); showT = 0; paint(); tick = tick || setInterval(paint, 500); }
			else if (!showT && !tick) showT = setTimeout(function () { showT = 0; if (pending || holds.length) { paint(); tick = tick || setInterval(paint, 500); } }, 350);
		} else {
			clearTimeout(showT); showT = 0; clearInterval(tick); tick = 0; since = 0;
			T('.kel-wait').remove();
			$.each(marked, function (i, $e) { $e.removeClass('kel-busy'); }); marked = [];
		}
	}
	document.addEventListener('click', function (e) {
		var el = e.target.closest && e.target.closest('.cx-btn, .cx-seg span, .ag-sw, button, .cx-sw');
		if (!el) return;
		if (el.classList.contains('kel-busy')) { e.stopPropagation(); e.preventDefault(); return; }
		lastEl = el; lastAt = Date.now();
	}, true);
	$(document).ajaxSend(function (e, xhr, o) {
		if (!o || o.url !== '/ubus') return;
		/* params = [会话, 对象, 方法, 参数]：方法名是第 3 项。🔴 曾经取成第 4 项（参数对象），结果所有请求——包括每 4 秒一次的
		   状态轮询——都被当成写操作，等待框跟着轮询一闪一闪（2026-10-13 用户报「前端一直闪烁」）。取不到方法名一律不处理。 */
		var m = ''; try { m = JSON.parse(o.data).params[2]; } catch (x) {}
		if (typeof m !== 'string' || !m || isRead(m)) return;
		xhr.kelW = 1; pending++; pendingText = TEXT[m] || '正在保存…';
		if (lastEl && Date.now() - lastAt < 1500) { marked.push($(lastEl).addClass('kel-busy')); lastEl = null; }
		sync();
	}).ajaxComplete(function (e, xhr) { if (xhr.kelW) { xhr.kelW = 0; pending = Math.max(0, pending - 1); sync(); } });
	window.KelUI = {
		/* 挂起一个等待框，返回 release()；text 可以之后用 release.text('新文字') 换 */
		hold: function (text) {
			var h = { text: text }; holds.push(h); sync();
			var rel = function () { var i = holds.indexOf(h); if (i >= 0) holds.splice(i, 1); sync(); };
			rel.text = function (t) { h.text = t; paint(); };
			return rel;
		},
		busy: function () { return pending > 0 || holds.length > 0; },
		/* 弹窗放到「屏幕上看得见的那一段」里，并限制高度、内容多了在弹窗内部滚动。
		   页面嵌在主框架里、框架高度随内容变：弹窗按固定位置放，设备一多就比框架还高，底部按钮被截在框架外、外层也滚不到（2026-10-24 用户报）。 */
		place: function (el) {
			var $m = $(el), top = 24, h = 560;
			try {
				var fr = window.frameElement, W = window.top;
				if (fr && W !== window) { var r = fr.getBoundingClientRect(), vt = Math.max(0, -r.top), vb = Math.min(r.height, W.innerHeight - r.top); top = vt + 24; h = vb - vt - 48; }
				else { top = window.pageYOffset + 24; h = window.innerHeight - 48; }
			} catch (e) {}
			$m.css({ position: 'absolute', top: top + 'px', maxHeight: Math.max(260, h) + 'px', overflowY: 'auto' });
		},
		/* 把一串请求当成一次操作：期间只显示一个等待框，已有操作在进行时直接拒绝（防重复提交） */
		track: function (method, action) {
			if (pending > 0 || holds.length > 0) return $.Deferred().reject().promise();
			var rel = this.hold(TEXT[method] || '正在保存…');
			try { return action().always(rel); } catch (e) { rel(); throw e; }
		}
	};
})(window.jQuery);
