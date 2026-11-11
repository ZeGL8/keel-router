/* 设备唯一配置入口：名称、限速、IPv6；访问控制只读。 */
(function ($) {
    'use strict';
    var sid = $.cookie('sessionid'), devices = {}, loading = false, modal = null, edit = null, saving = false, timer, modalHost, restoreFocus, readFailed = false, loaded = false;
    if (!sid) { top.location.href = '/index.html'; return; }
    var sources = { alias: '用户命名', dhcp: 'DHCP 名称', mdns: '设备广播', fingerprint: '指纹推测', random: '尚未识别', none: '尚未识别' };
    var scopes = { global: '公网地址', ula: '本地地址', link: '链路本地' };
    function esc(value) { return $('<span>').text(value == null ? '' : String(value)).html(); }
    function rpc(method, args) {
        if (method === 'web_get_device_list' && !args) args = { stats: '0' };
        return $.ajax({ url: '/ubus', type: 'POST', contentType: 'application/json', dataType: 'json',
            data: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'call', params: [sid, 'kelapi.static', method, args || {}] })
        }).then(function (r) {
            if (!r.result || r.result[0] !== 0) throw new Error(r.error && r.error.code === -32002 ? '登录已失效，请重新登录' : '系统未返回有效结果');
            var data = r.result[1] || {}; if (method === 'web_get_device_list' && !Array.isArray(data.device_list)) throw new Error('设备接口未返回有效列表'); return data;
        });
    }
    function inboundText(list) { return (list || []).map(function (x) { return x.proto === 'all' ? '全部端口' : x.proto.toUpperCase() + ' ' + x.port; }).join('、'); }
    function rate(v) { v = Number(v); return Number.isFinite(v) ? (v >= 1024 ? (v / 1024).toFixed(2) + ' MB/s' : v.toFixed(2) + ' KB/s') : '未知'; }
    function row(d) {
        var addrs = (d.ipv6_addresses || []).filter(function (a) { return a.scope === 'global' && /^[23][0-9a-f]{0,3}:/i.test(a.address); }).slice().sort(function (a, b) { var scope = ['global', 'ula', 'link'].indexOf(a.scope) - ['global', 'ula', 'link'].indexOf(b.scope); return scope || (a.state === 'REACHABLE' ? -1 : 0) - (b.state === 'REACHABLE' ? -1 : 0); });
        var mac = esc(d.id), html = '<article class="dv-grid dv-row" data-mac="' + mac + '"><div><div class="dv-name" title="' + esc(d.name) + '">' + esc(d.name || '名称未识别') + '</div>' + (d.reported_name && d.reported_name !== d.name ? '<div class="dv-meta" title="设备自己上报的名字">设备上报：' + esc(d.reported_name) + '</div>' : '');
        html += '</div><div><div class="dv-line"><span class="dv-key">MAC</span><code class="dv-address">' + mac + '</code></div><div class="dv-line"><span class="dv-key">IPv4</span><code class="dv-address">' + esc(d.ip || '暂未发现') + '</code></div>';
        if (addrs.length) {
            html += '<details class="dv-addresses" data-mac="' + mac + '"><summary><span class="dv-key">公网IPv6</span><code class="dv-address" title="' + esc(addrs[0].address) + '">' + esc(addrs[0].address) + '</code><span class="dv-more">详情</span></summary>';
            addrs.forEach(function (a) { html += '<div class="dv-address-full"><button class="dv-copy" data-address="' + esc(a.address) + '">复制</button><small>' + esc(scopes[a.scope] || '地址') + '</small><code>' + esc(a.address) + '</code></div>'; });
            html += '</details>';
        } else html += '<div class="dv-line"><span class="dv-key">IPv6</span><span class="dv-meta">未发现公网地址</span></div>';
        html += '</div><div><div class="dv-state">' + esc(d.online === '1' ? (d.type === 'wire' ? '有线 / 局域网' : d.type) : '离线或历史记录') + (d.is_guest ? ' · 访客' : '') + '</div>';
        if (d.access_known === false) html += '<div class="dv-chip dv-warn">OpenWrt 自定义访问规则</div>';
        else if (d.net_enable === '0') html += '<div><span class="dv-chip dv-warn">访问受限</span></div>';
        html += '<div><span class="dv-chip' + (!d.ipv6_applied ? ' dv-warn' : d.ipv6_enabled ? ' dv-good' : '') + '">IPv6上网：' + (!d.ipv6_applied ? '待确认' : d.ipv6_enabled ? '允许' : '关闭') + '</span></div>';
        if (d.qos_enable === '1') html += '<span class="dv-chip">已设置限速</span>';
        if ((d.inbound || []).length) html += '<div><a class="dv-chip dv-warn dv-fw" href="../seniorManagement/ipv6fw.html" title="外网可以经 IPv6 访问这台设备的这些端口；点击到「IPv6 防火墙」管理">对外开放 ' + esc(inboundText(d.inbound)) + '</a></div>';
        html += '</div><div class="dv-speed">' + (d.online === '1' ? d.traffic_pending ? '正在读取…' : '<img src="/P_IMG/top.png" alt="上传">' + rate(d.uplink) + '<br><img src="/P_IMG/bottom.png" alt="下载">' + rate(d.downlink) : '—') + '</div><div><button class="dv-btn dv-edit" data-mac="' + mac + '">编辑</button></div></article>';
        return html;
    }
    function render(data) {
        var open = {}; $('.dv-addresses[open]').each(function () { open[this.dataset.mac] = true; });
        var on = [], off = []; devices = {};
        (data.device_list || []).forEach(function (d) { devices[d.id] = d; (d.online === '1' ? on : off).push(row(d)); });
        $('#dv-online').html(on.length ? on.join('') : '<div class="dv-empty">暂无在线设备</div>');
        $('#dv-offline').html(off.length ? off.join('') : '<div class="dv-empty">暂无离线记录</div>');
        $('.dv-addresses').each(function () { this.open = !!open[this.dataset.mac]; });
        $('#dv-count').text('在线 ' + on.length + ' · 历史 ' + off.length);
        $('#dv-updated').text('更新于 ' + new Date().toLocaleTimeString() + '');
        try { if (parent.setHeight) parent.setHeight(document.documentElement.scrollHeight, 400); } catch (e) {}
    }
    function load() {
        if (loading || modal || saving || document.hidden || KelUI.busy() || (window.getSelection() && !window.getSelection().isCollapsed)) return;
        loading = true;
        var stats = loaded;
        rpc('web_get_device_list', { stats: stats ? '1' : '0' }).then(function (data) { render(data); loaded = true; if (!stats) setTimeout(load, 1500); if (readFailed) $('#dv-message').text(''); readFailed = false; }, function () { readFailed = true; $('#dv-message').text('设备数据未能更新，当前显示上次结果，请稍后重试'); }).always(function () { loading = false; });
    }
    function close() { if (saving) return; if (modal) modal.remove(); if (modalHost) $(modalHost).off('keydown.kelDevices'); modal = null; edit = null; if (restoreFocus) restoreFocus.focus(); load(); }
    function open(mac) {
        if (modal || saving) return;
        restoreFocus = document.activeElement; var host = document;
        try { if (parent !== window && parent.document.body) host = parent.document; } catch (e) {}
        if (!host.querySelector('link[data-kel-devices]')) $('<link rel="stylesheet" data-kel-devices href="/PC/css/kel-devices.css?v=20261007e">').appendTo(host.head);
        modal = $('<div class="dv-overlay"><section class="dv-dialog" role="dialog" aria-modal="true" aria-labelledby="dv-dialog-title"><div class="dv-dialog-top"><h2 id="dv-dialog-title">设备信息</h2><button type="button" class="dv-close" aria-label="关闭"><img src="/P_IMG/off.png" alt=""></button></div><div class="dv-description dv-identity"></div><form><fieldset disabled><label><span>设备名</span><input name="name" type="text" maxlength="63" autocomplete="off"></label><div class="dv-description dv-recognition"></div><div class="dv-description" style="margin-top:12px">联网许可由“访问控制”统一管理，本页只显示状态。</div><div class="dv-description dv-access"></div><label class="dv-check"><span>IPv6 上网</span><input name="ipv6" type="checkbox" aria-label="允许 IPv6 上网"></label><div class="dv-description">关闭后仍可能获得 IPv6 地址，IPv4 和访问路由器不受影响。</div><label class="dv-check"><span>限速</span><input name="limit" type="checkbox" aria-label="启用单设备限速"></label><div class="dv-limits"><label><span>上传速度</span><input name="upload" type="number" min="20" max="10240000" step="1"><small>KB/S</small></label><label><span>下载速度</span><input name="download" type="number" min="20" max="10240000" step="1"><small>KB/S</small></label></div></fieldset><div class="dv-result" role="status">正在读取最新设置…</div><div class="dv-actions"><button type="button" class="dv-btn dv-cancel">取消</button><button type="submit" class="dv-btn primary dv-save" disabled>保存</button></div></form></section></div>').appendTo(host.body);
        modalHost = host; $(host).on('keydown.kelDevices', function (e) { if (e.key === 'Escape') close(); if (e.key === 'Tab' && modal) { var items = modal.find('input:enabled,button:enabled'); var first = items[0], last = items[items.length - 1]; if (e.shiftKey && host.activeElement === first) { e.preventDefault(); last.focus(); } else if (!e.shiftKey && host.activeElement === last) { e.preventDefault(); first.focus(); } } });
        modal.find('.dv-cancel,.dv-close').on('click', close);
        modal.find('[name=limit]').on('change', function () { modal.find('[name=upload],[name=download]').prop('disabled', !this.checked); });
        modal.find('form').on('submit', function (e) { e.preventDefault(); save(); });
        rpc('web_get_device_list').then(function (data) {
            if (!modal) return;
            var d = (data.device_list || []).find(function (d) { return d.id === mac; });
            if (!d) { modal.find('.dv-result').text('设备记录暂不可见，请关闭后重试'); return; }
            edit = d; modal.find('.dv-identity').text(d.id + ' · ' + (d.ip || '暂未发现 IPv4'));
            modal.find('[name=name]').val(d.name).attr('placeholder', '未获取真实名称，可手动命名');
            modal.find('.dv-recognition').text([sources[d.dev_src], d.dev_vendor ? '登记厂商：' + d.dev_vendor : '', d.dev_model ? '广播型号：' + d.dev_model : ''].filter(Boolean).join(' · '));
            modal.find('.dv-access').text('当前访问策略：' + (d.net_enable === '0' ? '受限' : '允许'));
            modal.find('[name=ipv6]').prop('checked', !!d.ipv6_enabled).prop('disabled', !d.ipv6_applied);
            modal.find('[name=limit]').prop('checked', d.qos_enable === '1');
            modal.find('[name=upload]').val(d.qos_upload); modal.find('[name=download]').val(d.qos_download);
            modal.find('fieldset').prop('disabled', false); modal.find('[name=limit]').trigger('change');
            modal.find('.dv-save').prop('disabled', false);
            modal.find('.dv-result').text(d.ipv6_applied ? '' : 'IPv6规则尚未确认，该开关暂不可修改');
            modal.find('[name=name]').trigger('focus');
        }, function () { if (modal) modal.find('.dv-result').text('无法读取设置，请关闭后重试'); });
    }
    function save() {
        if (saving || !edit) return;
        var name = $.trim(modal.find('[name=name]').val()), ipv6 = modal.find('[name=ipv6]').prop('checked'), limit = modal.find('[name=limit]').prop('checked');
        var upload = modal.find('[name=upload]').val(), download = modal.find('[name=download]').val(), changes = [];
        if (name !== edit.name && (!name || name.length > 63)) { modal.find('.dv-result').text('名称不能为空，最多63个字符'); return; }
        if (limit && [upload, download].some(function (v) { return !/^\d+$/.test(v) || +v < 20 || +v > 10240000; })) { modal.find('.dv-result').text('限速请输入20–10240000之间的整数，单位KB/s'); return; }
        if (name !== edit.name) changes.push({ method: 'web_set_station_name', args: { uid: edit.id, name: name }, label: '设备名称' });
        if ((limit ? '1' : '0') !== edit.qos_enable || (limit && (String(upload) !== String(edit.qos_upload) || String(download) !== String(edit.qos_download)))) {
            var args = { uid: edit.id, enable: limit ? '1' : '0' }; if (limit) { args.upload = upload; args.download = download; }
            changes.push({ method: 'web_set_device_limit_speed', args: args, label: '限速设置' });
        }
        if (ipv6 !== edit.ipv6_enabled) changes.push({ method: 'web_set_device_ipv6', args: { uid: edit.id, enable: ipv6 ? '1' : '0' }, label: 'IPv6设置' });
        if (!changes.length) { modal.find('.dv-result').text('没有修改，无需保存'); return; }
        saving = true; modal.find('fieldset,.dv-save,.dv-cancel,.dv-close').prop('disabled', true);
        var completed = [];
        KelUI.track(changes[0].method, function () {
            var chain = $.Deferred().resolve().promise();
            changes.forEach(function (change) { chain = chain.then(function () {
                return rpc(change.method, change.args).then(function (r) {
                    if (r.status !== 0) throw new Error(change.label + (r.saved ? '已保存，但规则未成功应用' : '未成功保存'));
                    completed.push(change.label);
                });
            }); });
            return chain.then(function () { return rpc('web_get_device_list'); }).then(function (data) {
                var d = (data.device_list || []).find(function (d) { return d.id === edit.id; });
                if (!d || changes.some(function (c) { return c.method === 'web_set_station_name' ? d.name !== name : c.method === 'web_set_device_limit_speed' ? d.qos_enable !== (limit ? '1' : '0') || (limit && (+d.qos_upload !== +upload || +d.qos_download !== +download)) : d.ipv6_enabled !== ipv6 || !d.ipv6_applied; })) throw new Error('设置已提交，但读回结果尚未确认');
                render(data); return data;
            });
        }).then(function () {
            saving = false; close(); $('#dv-message').text(completed.join('、') + '已保存并读回确认');
        }, function (error) {
            if (modal) modal.find('.dv-result').text((completed.length ? completed.join('、') + '已保存；' : '') + (error && error.message ? error.message : '连接中断，保存结果未确认，请关闭后查看最新状态'));
        }).always(function () {
            saving = false;
            if (modal) { modal.find('fieldset,.dv-save,.dv-cancel,.dv-close').prop('disabled', false); modal.find('[name=limit]').trigger('change'); modal.find('[name=ipv6]').prop('disabled', !edit.ipv6_applied); }
        });
    }
    $(document).on('click', '.dv-edit', function () { open(this.dataset.mac); });
    $(document).on('click', '.dv-copy', function () {
        var area = $('<textarea>').val(this.dataset.address).css({ position: 'fixed', opacity: 0 }).appendTo('body'); area[0].select();
        try { if (!document.execCommand('copy')) throw new Error(); $('#dv-message').text('已复制完整地址'); } catch (e) { $('#dv-message').text('复制失败，请展开地址后手动选择复制'); }
        area.remove();
    });
    window.addEventListener('pagehide', function () { clearInterval(timer); if (modal) modal.remove(); });
    load(); timer = setInterval(load, 6000);
})(window.jQuery);
