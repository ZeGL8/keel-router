'use strict';
'require view';
'require form';
'require uci';
return view.extend({
 load:function(){return Promise.all([uci.load('kel'),uci.load('firewall')]);},
 render:function(){
  var m=new form.Map('kel','设备名称与限速','与 Keel 设备页共用同一份 OpenWrt UCI 配置。名称由用户设置；单设备限速由 firewall4 扩展应用。IPv6 和访问控制请在原生防火墙的 IP 集、通信规则中管理。');
  var s=m.section(form.TypedSection,'qos','设备设置');s.anonymous=true;s.addremove=true;
  var o=s.option(form.Value,'mac','MAC 地址');o.datatype='macaddr';o.rmempty=false;o.validate=function(section,value){var key=value.toLowerCase().replace(/[:-]/g,'');return uci.sections('kel','qos').some(function(s){return s['.name']!==section&&String(s.mac||'').toLowerCase().replace(/[:-]/g,'')===key;})?'该 MAC 地址已有设备设置':true;};
  o=s.option(form.Value,'name','用户名称');o.maxlength=63;o.rmempty=true;
  o=s.option(form.Flag,'enable','启用单设备限速');o.default='0';o.rmempty=false;o.validate=function(section,value){if(value==='1'&&uci.sections('firewall','defaults').some(function(s){return s.flow_offloading==='1'||s.flow_offloading_hw==='1';}))return '请先在 OpenWrt 防火墙中关闭流量卸载，再启用设备限速';return true;};
  ['upload','download'].forEach(function(key){var v=s.option(form.Value,key,key==='upload'?'上传速度 KB/s':'下载速度 KB/s');v.datatype='and(uinteger,range(20,10240000))';v.depends('enable','1');v.rmempty=false;});
  return m.render();
 }
});
