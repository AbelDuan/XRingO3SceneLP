const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function mkEl(){ return { _html:'', _text:'', style:{}, dataset:{}, children:[],
  set innerHTML(v){ this._html=v; }, get innerHTML(){ return this._html; },
  set textContent(v){ this._text=String(v); }, get textContent(){ return this._text; },
  classList:{add(){},remove(){},contains(){return false;}},
  closest(){return null;}, querySelectorAll(){return [];},
  appendChild(){}, addEventListener(){}, observe(){}, unobserve(){} }; }
const byId = {};
global.document = { getElementById(id){ return byId[id] || (byId[id]=mkEl()); }, querySelectorAll(){return [];}, addEventListener(){}, removeEventListener(){}, createElement(){return mkEl();} };
global.window = { addEventListener(){}, ksu:null };
global.IntersectionObserver = undefined; global.setTimeout=()=>0;
let wrapped = src + '\n;global.__T={renderAetherCard,S,esc};';
eval(wrapped);
const T = global.__T;
let fails=0;
function ok(c,m){ if(c){console.log('  ✓ '+m);} else {console.log('  ✗ '+m);fails++;} }
console.log('[renderAetherCard feature 区块]');
const m = { ON:'on', RUNNING:'1', PID:'123', RULES:'378', TOPO_E:'0-3', TOPO_P1:'4-7', TOPO_HP:'8-9', TOPO_CLUSTERS:'3',
  FEAT_ebpf:'true', FEAT_auto_for_none:'true', FEAT_foreground:'true', FEAT_load_aware:'true', FEAT_render_guard:'true', FEAT_min_cpus:'4' };
T.renderAetherCard(m);
const feats = byId['aether-feats']._html;
ok(/eBPF 加速/.test(feats), '渲染 eBPF 加速开关');
ok(/checked/.test(feats), 'true 值的开关默认 checked');
ok(/最小在线核数/.test(feats), 'min_cpus 作为 KV 渲染');
ok(/<b>4<\/b>/.test(feats), 'min_cpus 值=4 显示');
ok(/data-feat="ebpf"/.test(feats), '开关带 data-feat=ebpf');
ok(/data-feat="render_guard"/.test(feats), 'render_guard 开关存在');
// 拓扑
ok(/小核 0-3/.test(byId['aether-topo']._text), '拓扑 小核 0-3');
ok(/大核 8-9/.test(byId['aether-topo']._text), '拓扑 大核 8-9');
console.log(fails? ('\n❌ 失败 '+fails+' 项') : '\n✅ 全部通过');
process.exit(fails?1:0);
