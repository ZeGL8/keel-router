'use strict';
import { cursor } from 'uci';
import { readfile, writefile, rename } from 'fs';
let f=cursor(getenv('KEL_POLICY_CONFIG')),j=cursor(getenv('KEL_POLICY_CONFIG')),n=cursor(getenv('KEL_POLICY_CONFIG')); f.load('firewall'); j.load('kel');n.load('network');
let devices=[];for(let section in ['lan','guest']) {let d=n.get('network',section,'device')??(section==='lan'?'br-lan':'br-guest'); for(let v in (type(d)==='array'?d:[d]))if(index(devices,v)<0)push(devices,v);}
let interfaces='{ '+join(', ',map(devices,d=>sprintf('%J',d)))+' }';
function norm(m) { let x=lc(replace(''+(m??''),/[-:]/g,'')); return match(x,/^[0-9a-f]{12}$/) ? join(':',map(match(x,/[0-9a-f]{2}/g),m=>m[0])) : ''; }
function write(path, data) { path=(getenv('KEL_POLICY_OUTPUT')??'')+path; if(readfile(path)===data)return; let result=writefile(path+'.new',data); if(result===null||result===false||!rename(path+'.new',path)) die('Unable to write policy include\n'); }
let enabled=f.get('firewall','kel_noipv6_rule')==='rule' && f.get('firewall','kel_noipv6_rule','enabled')!=='0' && f.get('firewall','kel_noipv6_rule','target')==='REJECT' && f.get('firewall','kel_noipv6_rule','ipset')==='kel_noipv6';
if(f.get('firewall','kel_noipv6_rule','family')!=='ipv6'||join(' ',(type(f.get('firewall','kel_noipv6_rule','proto'))==='array'?f.get('firewall','kel_noipv6_rule','proto'):[f.get('firewall','kel_noipv6_rule','proto')]))!=='all'||f.get('firewall','kel_noipv6_rule','src')!=='*'||f.get('firewall','kel_noipv6_rule','dest')!=='*')enabled=false;
for(let opt in ['src_ip','dest_ip','src_port','dest_port','src_mac','dest_mac','icmp_type','mark','weekdays','monthdays','start_time','stop_time','start_date','stop_date','helper','limit','limit_burst','device','direction','extra'])if(f.get('firewall','kel_noipv6_rule',opt)!=null&&f.get('firewall','kel_noipv6_rule',opt)!=='')enabled=false;
let forward=enabled?'iifname '+interfaces+' meta nfproto ipv6 ether saddr @kel_noipv6 counter reject with icmpv6 type admin-prohibited comment "KEL-Device-No-IPv6-Early"\n':'';
let input=enabled?'iifname '+interfaces+' meta nfproto ipv6 ether saddr @kel_noipv6 ct status dnat meta l4proto tcp tcp dport 7892 counter reject with tcp reset comment "KEL-Device-No-IPv6-Proxy"\n':'';
let rules=[],up=[],down=[],learn=[];
j.foreach('kel','qos',s=>{
 if(s.enable!=='1')return;
 let mac=norm(s.mac),u=int(s.upload),d=int(s.download);
 if(!match(''+s.upload,/^[0-9]+$/)||!match(''+s.download,/^[0-9]+$/))die('Device limits must be integers\n');
 if(mac===''||u<20||d<20||u>10240000||d>10240000)die('Invalid device speed limit\n');
 let key=replace(mac,/:/g,'');
 push(rules,'set kel_dl4_'+key+' { type ipv4_addr; flags dynamic,timeout; timeout 10m; }');
 push(rules,'set kel_dl6_'+key+' { type ipv6_addr; flags dynamic,timeout; timeout 10m; }');
 push(learn,'ether saddr '+mac+' update @kel_dl4_'+key+' { ip saddr }');
 push(learn,'ether saddr '+mac+' update @kel_dl6_'+key+' { ip6 saddr }');
 push(up,'ether saddr '+mac+' limit rate over '+u+' kbytes/second counter drop');
 push(rules,'chain kel_limit_bucket_'+key+' { limit rate over '+d+' kbytes/second counter drop; }');
 push(down,'ip daddr @kel_dl4_'+key+' jump kel_limit_bucket_'+key);
 push(down,'ip6 daddr @kel_dl6_'+key+' jump kel_limit_bucket_'+key);
});
let offload=false; f.foreach('firewall','defaults',s=>{if(s.flow_offloading==='1'||s.flow_offloading_hw==='1')offload=true;});
if(length(up)&&offload)die('Device speed limits require flow offloading to be disabled in OpenWrt firewall settings\n');
if(length(up)) {
 push(rules,'chain kel_limit_learn { type filter hook prerouting priority -130; policy accept; iifname '+interfaces+' jump kel_limit_learn_rules; }');
 push(rules,'chain kel_limit_learn_rules { '+join('; ',learn)+'; }');
 push(rules,'chain kel_limit_up { type filter hook prerouting priority -120; policy accept; iifname '+interfaces+' jump kel_limit_up_rules; }');
 push(rules,'chain kel_limit_up_rules { '+join('; ',up)+'; }');
 push(rules,'chain kel_limit_down { type filter hook postrouting priority -110; policy accept; oifname '+interfaces+' jump kel_limit_down_rules; }');
 push(rules,'chain kel_limit_down_rules { '+join('; ',down)+'; }');
}
write('/usr/share/nftables.d/chain-pre/forward/30-kel-device-ipv6.nft',forward);
write('/usr/share/nftables.d/chain-pre/input/30-kel-device-ipv6.nft',input);
write('/usr/share/nftables.d/table-post/30-kel-device-limits.nft',join('\n',rules)+'\n');
