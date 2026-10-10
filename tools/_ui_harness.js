const fs = require('fs');
const src = fs.readFileSync(process.argv[2], 'utf8');
function mkEl(){
  return { _html:'', _text:'', style:{}, dataset:{}, children:[],
    set innerHTML(v){ this._html=v; }, get innerHTML(){ return this._html; },
    set textContent(v){ this._text=String(v); }, get textContent(){ return this._text; },
    classList:{add(){},remove(){},contains(){return false;}},
    closest(){return null;}, querySelectorAll(){return [];},
    appendChild(){}, addEventListener(){}, observe(){}, unobserve(){} };
}
const byId = {};
global.document = { getElementById(id){ return byId[id] || (byId[id]=mkEl()); }, querySelectorAll(){return [];}, addEventListener(){}, removeEventListener(){}, createElement(){return mkEl();} };
global.window = { addEventListener(){}, ksu:null };
global.IntersectionObserver = undefined;
global.setTimeout = ()=>0;
let wrapped = src + '\n;global.__T={renderAppFreq,renderApps,renderAetherCard,S,Meta,Api,esc};';
eval(wrapped);
const T = global.__T;
let fails=0;
function ok(c,m){ if(c){console.log('  ✓ '+m);} else {console.log('  ✗ '+m);fails++;} }
T.S.appList=[{pkg:'com.miui.home',sys:'0'},{pkg:'com.tencent.mm',sys:'1'},{pkg:'com.sina.weibo',sys:'0'}];
T.S.appfreq={'com.miui.home':'performance'};
T.Meta.cache['com.miui.home']={label:'系统桌面',sys:0,icon:''};
T.Meta.cache['com.tencent.mm']={label:'微信',sys:1,icon:''};
T.Meta.cache['com.sina.weibo']={label:'微博',sys:0,icon:''};
T.S.appShow=40; T.S.selSet=new Set();
console.log('[renderAppFreq]');
T.renderAppFreq(true,true);
const af = byId['appfreq-win']._html;
ok(af.indexOf('系统桌面')>=0, '中文名 系统桌面 渲染');
ok(af.indexOf('微信')>=0, '中文名 微信 渲染');
ok(af.indexOf('微博')>=0, '中文名 微博 渲染');
ok(af.indexOf('data-ico="com.miui.home"')>=0, '图标懒加载包裹 data-ico 存在');
ok(af.indexOf('ksu://icon/com.miui.home')>=0, 'ksu://icon 直出');
ok(af.indexOf('data-appfreq="com.miui.home"')>=0, '单档 <select> 存在');
ok(af.indexOf('已设')>=0, '已配置标签存在');
console.log('[renderApps 单行布局]');
T.S.apps=[{pkg:'com.miui.home',sys:0,defined:'1',tpl:'game',custom:'0'},{pkg:'com.tencent.mm',sys:1,defined:'0',tpl:'',custom:'0'}];
T.S.showCount=40; T.S.sel=new Set();
T.renderApps(true);
const th = byId['apps-card']._html;
ok(th.indexOf('display:flex;align-items:center')>=0, '线程行单行 flex（不换行）');
ok(th.indexOf('data-set="com.miui.home"')>=0, '线程档位 <select> 内联');
console.log('[renderAetherCard 拓扑]');
T.renderAetherCard({TOPO_E:'0-3',TOPO_P1:'4-7',TOPO_HP:'8-9',TOPO_CLUSTERS:'3',RULES:'379'});
const topo = byId['aether-topo'];
ok(/小核 0-3/.test(topo._text), '拓扑显示 小核 0-3');
ok(/中核 4-7/.test(topo._text), '拓扑显示 中核 4-7');
ok(/大核 8-9/.test(topo._text), '拓扑显示 大核 8-9');
ok(/3簇/.test(topo._text), '拓扑显示 簇数');
console.log(fails? ('\n❌ 失败 '+fails+' 项') : '\n✅ 全部通过');
process.exit(fails?1:0);
