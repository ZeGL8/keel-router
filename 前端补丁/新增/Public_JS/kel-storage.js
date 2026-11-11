/* kel-storage.js —— 路由状态页「存储状态」卡：内存 / 闪存（后端 web_get_storage_info）
 * 环形图配置照搬原厂首页右侧的存储卡（颜色、尺寸、中间「已用」）；页面在后台时不刷新。 */
(function ($) {
    var data = null, cur = 'memory', chart = null;
    var NOTE = {
        memory: function (d) { return '可用 ' + fmt(d.total - d.used); },
        flash: function (d) { return '可写区剩余 ' + fmt(d.total - d.used) + '（存放设置与缓存）'; }
    };

    /* 与原厂同一套换算：两位小数，单位 G/M/K/B */
    function fmt(n) {
        return n > Math.pow(1024, 3) ? (n / Math.pow(1024, 3)).toFixed(2) + 'G'
            : n > Math.pow(1024, 2) ? (n / Math.pow(1024, 2)).toFixed(2) + 'M'
            : n > 1024 ? (n / 1024).toFixed(2) + 'K' : n + 'B';
    }

    function render() {
        var d = data && data[cur];
        if (!d || !d.total) { $('#kel_st_note').text(''); $('#kel_st_total, #kel_st_used').text('—'); return; }
        $('#kel_st_note').text(NOTE[cur](d));
        $('#kel_st_total').text(fmt(d.total));
        $('#kel_st_used').text(fmt(d.used) + '（' + Math.round(d.used * 100 / d.total) + '%）');
        chart = chart || echarts.init(document.getElementById('kel_st_ec'));
        chart.setOption({
            color: ['#E2E2E2', '#00DCF0'],
            title: { text: '已用', subtext: fmt(d.used), left: 'center', top: '25%',
                textStyle: { color: '#999999', fontSize: 12, align: 'center', fontWeight: 500 },
                subtextStyle: { color: '#666666', fontSize: 20, align: 'center', fontWeight: 550 } },
            series: [{ type: 'pie', radius: ['80%', '100%'], avoidLabelOverlap: false, hoverAnimation: false, silent: true,
                label: { normal: { show: false } },
                data: [{ value: d.total - d.used, itemStyle: { normal: { color: '#E2E2E2' } } },
                       { value: d.used, itemStyle: { normal: { color: '#00DCF0' } } }] }]
        }, true);
    }

    function load() {
        if (document.hidden) return;
        $.ajax({ url: '/ubus', type: 'POST', contentType: 'application/json', dataType: 'json',
            data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call',
                params: [$.cookie('sessionid'), 'kelapi.static', 'web_get_storage_info', {}] }),
            success: function (r) { if (r && r.result && r.result[0] === 0 && r.result[1]) { data = r.result[1]; render(); } }
        });
    }

    $(function () {
        $('#kel_st_tabs').on('click', '.kel-st-tab', function () {
            $('.kel-st-tab').removeClass('click'); $(this).addClass('click');
            cur = $(this).data('k'); render();
        });
        load();
        setInterval(load, 10000);
        document.addEventListener('visibilitychange', load);
    });
})(jQuery);
