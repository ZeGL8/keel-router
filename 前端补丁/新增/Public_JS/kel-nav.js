/* kel-nav.js —— 顶部导航增加两个菜单（2026-10-12）
   原来「高级功能」下有 10 个入口，太挤。拆成三个顶部菜单：
     外网访问（tabListData[3]）：DDNS / 端口转发 / DMZ / UPnP / NAT设置
     网络服务（tabListData[4]）：代理加速 / 广告过滤
     高级功能（tabListData[2]）：自定义Hosts / 网口自定义 / OpenWrt高级设置 —— 仍由原厂 main.js 渲染
   本脚本在原厂 main.js（defer）之前执行，新加的 <a> 会被它的通用导航点击处理（清空 .list、切换高亮、加载 iframe），
   但它不认识这两个菜单、不会渲染二级入口——这里在它处理完之后补渲染（所以用 setTimeout 0），
   标记和原厂一致（.list > ul > li > a[target=main-iframe]），原厂对 .list 的点击代理（变色、移动小三角）照常生效。 */
(function () {
	var $ = window.jQuery || window.$; if (!$ || typeof tabListData === 'undefined') return;
	var MENUS = [ { id: 'kel_wanacc', title: '外网访问', idx: 3 }, { id: 'kel_netsvc', title: '网络服务', idx: 4 } ];
	/* 小三角位置：入口整体居中在 1200 宽的内容区里（与原厂 4 个入口时 207+250*t 的算法一致，原厂没给 2 个入口的情况） */
	function wOf(n) { return n >= 5 ? 200 : 250; }
	function tri(n, t) { var W = wOf(n); $('#triangle_up').css('left', ((1200 - n * W) / 2 + W / 2 - 16 + W * t) + 'px'); }
	MENUS.forEach(function (m) {
		var items = tabListData[m.idx] || []; if (!items.length || $('#' + m.id).length) return;
		var $box = $('<div><a href="' + items[0].url + '" target="main-iframe" id="' + m.id + '">' + m.title + '</a><div class="line"></div></div>');
		$('#advanced_Li').before($box);
		$box.find('a').on('click', function () {
			var a = this;
			setTimeout(function () {
				var W = wOf(items.length), html = '<ul>';
				items.forEach(function (it) { html += "<li style='width:" + W + "px;'><a href=" + it.url + " target='main-iframe'><div class='image' style='background-image:url(" + it.img + ");'></div>" + it.title + '</a></li>'; });
				$('.list').html(html + '</ul>');
				$('.triangle_up').show(); tri(items.length, 0);
				$('.nav-box .right a').removeClass('active'); $(a).addClass('active');
				$('.nav-box .right .line').removeClass('block'); $(a).next().addClass('block');
			}, 0);
		});
	});
	/* 原厂点击代理只会算 7/6/5/4/3/1 个入口的小三角位置；2 个入口时由这里补上 */
	$('.list').on('click', 'li a', function () {
		var n = $('.list li').length; if (n === 2) tri(n, $('.list li').index($(this).closest('li')));
	});
})();
