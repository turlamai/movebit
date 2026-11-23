// Run with jsdom and @sinonjs/fake-timers available on NODE_PATH.
// This executes the shipped entries and event handlers; it is not a browser layout test.
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { JSDOM, VirtualConsole } = require('jsdom');
const FakeTimers = require('@sinonjs/fake-timers');
const root = path.resolve(__dirname, '..');
const cases = [];
const test = (name, run) => cases.push({ name, run });
function fixture(entry='index.html', overrides={}) {
  const errors=[];
  const vc=new VirtualConsole();vc.on('jsdomError',e=>errors.push(e.message));
  const dom=new JSDOM(fs.readFileSync(path.join(root,entry),'utf8'),{url:'https://movebit.test/'+entry,runScripts:'outside-only',pretendToBeVisual:true,virtualConsole:vc});
  const w=dom.window,d=w.document;
  w.matchMedia=()=>({matches:false,addEventListener(){},removeEventListener(){}});
  w.HTMLElement.prototype.setPointerCapture=function(){};
  w.HTMLElement.prototype.releasePointerCapture=function(){};
  w.HTMLDialogElement.prototype.showModal=function(){this.setAttribute('open','');};
  w.HTMLDialogElement.prototype.close=function(){this.removeAttribute('open');this.dispatchEvent(new w.Event('close'));};
  const clock=FakeTimers.withGlobal(w).install({now:new Date('2026-11-20T10:00:00Z'),toFake:['Date','setTimeout','clearTimeout','setInterval','clearInterval']});
  const storageKey=entry.endsWith('empty.html')?'movebit-polish-empty-v2':'movebit-polish-v2';
  if(Object.keys(overrides).length)w.localStorage.setItem(storageKey,JSON.stringify(overrides));
  const script=d.querySelector('script[src]').getAttribute('src');
  w.eval(fs.readFileSync(path.resolve(root,path.dirname(entry),script),'utf8'));
  const q=selector=>{const el=d.querySelector(selector);assert.ok(el,'Missing '+selector);return el;};
  const click=selector=>{const el=q(selector);el.focus();el.click();};
  const action=name=>click(`[data-action="${name}"]`);
  const state=()=>JSON.parse(w.localStorage.getItem(storageKey)||'null');
  const key=(target,key)=>target.dispatchEvent(new w.KeyboardEvent('keydown',{key,bubbles:true,cancelable:true}));
  const pointer=(el,type,x,y,id=1)=>{const event=new w.MouseEvent(type,{clientX:x,clientY:y,button:0,bubbles:true,cancelable:true});Object.defineProperty(event,'pointerId',{value:id});el.dispatchEvent(event);};
  // Geometry is a controlled model, deliberately not a claim about rendered pixels.
  const rect=(left,top,width,height)=>({left,top,right:left+width,bottom:top+height,width,height});
  function geometry(){const area=q('.desktop-layout'),resident=q('.resident-companion');area.getBoundingClientRect=()=>rect(0,0,1200,750);resident.getBoundingClientRect=()=>{const [x,y]=resident.style.translate.split(' ').map(parseFloat);return rect(936+(x||0),450+(y||0),248,280);};}
  return {w,d,q,click,action,state,key,pointer,clock,errors,geometry,close(){clock.uninstall();w.close();}};
}
async function withFixture(run,entry,overrides){const f=fixture(entry,overrides);try{await run(f);assert.deepEqual(f.errors,[],'Runtime errors');}finally{f.close();}}
for(const entry of ['index.html','prototype/desktop.html','prototype/main.html','prototype/empty.html','prototype/micro.html','prototype/tray.html','prototype/onboarding.html'])test('entry starts: '+entry,()=>withFixture(f=>{assert.ok(f.q('main'));assert.ok(f.d.querySelector('[data-action="pet"],.welcome-window'));},entry));
test('pat is playful and never completes reminders',()=>withFixture(f=>{for(let i=0;i<3;i++)f.action('pet');assert.equal(f.q('.pet-character').dataset.expression,'peek');assert.equal(f.state(),null);f.clock.tick(2300);assert.equal(f.q('.pet-character').dataset.chat,'false');}));
test('pointer drag and release do not complete or pat',()=>withFixture(f=>{f.geometry();const b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',900,500);f.pointer(b,'pointerup',900,500);b.click();assert.equal(f.q('.pet-character').dataset.expression,'landed');assert.equal(f.state(),null);assert.notEqual(f.q('.resident-companion').style.translate,'0px 0px');}));
test('drag pose survives a preceding pat timeout',()=>withFixture(f=>{f.action('pet');f.geometry();const b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',950,550);f.clock.tick(2500);assert.equal(f.q('.pet-character').dataset.expression,'held');f.pointer(b,'pointerup',950,550);}));
test('minute refresh does not detach a captured drag target',()=>withFixture(f=>{f.clock.tick(59000);f.geometry();const b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',950,550);f.clock.tick(1500);assert.equal(b.isConnected,true);f.pointer(b,'pointerup',950,550);assert.equal(f.q('.pet-character').dataset.expression,'landed');}));
test('pointer cancellation restores a usable pet',()=>withFixture(f=>{f.geometry();let b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',950,550);f.pointer(b,'pointercancel',950,550);f.pointer(b,'pointerdown',950,550);f.pointer(b,'pointerup',950,550);b.click();assert.equal(f.q('.pet-character').dataset.expression,'happy');assert.equal(f.state(),null);}));
test('closing utility window keeps pending reminder and pet focus',()=>withFixture(f=>{f.action('tray');f.action('main');f.action('desktop');assert.equal(f.d.querySelector('.utility-window'),null);assert.equal(f.q('.resident-invitation').hidden,false);assert.equal(f.d.activeElement.dataset.action,'pet');}));
test('utility scroll survives close and reopen',()=>withFixture(f=>{f.action('tray');f.action('main');f.click('[data-tab=history]');f.q('#utilityScroll').scrollTop=140;f.action('desktop');f.action('tray');f.action('main');assert.equal(f.q('#utilityScroll').scrollTop,140);}));
test('clicking workspace outside menu dismisses it',()=>withFixture(f=>{f.action('tray');f.q('.desktop-layout').click();assert.equal(f.d.querySelector('.resident-menu'),null);}));
test('Escape dismisses menu and restores its trigger focus',()=>withFixture(f=>{f.action('tray');f.key(f.d.activeElement,'Escape');assert.equal(f.d.querySelector('.resident-menu'),null);assert.equal(f.d.activeElement.dataset.action,'tray');}));
test('opening menu during rest preserves countdown and returns to rest',()=>withFixture(f=>{f.action('tray');f.action('eyes');f.action('start');f.clock.tick(5000);f.click('.pet-more');f.clock.tick(3000);f.key(f.d.activeElement,'Escape');assert.ok(f.d.querySelector('.break-window'));assert.ok(f.q('#countdown').textContent.includes('12'));}));
test('closing rest window stops timer without completing',()=>withFixture(f=>{f.action('tray');f.action('eyes');f.action('start');f.clock.tick(2000);f.action('desktop');f.clock.tick(25000);assert.equal(f.d.querySelector('.break-window'),null);assert.equal(f.d.querySelector('#countdown'),null);assert.equal(f.state(),null);f.action('tray');f.action('eyes');assert.ok(f.d.querySelector('[data-action=start]'));}));
test('timer expiry never completes automatically',()=>withFixture(f=>{f.action('tray');f.action('eyes');f.action('start');f.clock.tick(21000);assert.ok(f.d.querySelector('[data-action=micro-done]'));assert.equal(f.state(),null);f.action('micro-done');assert.equal(f.state().done[2],4);assert.equal(f.d.querySelector('.break-window'),null);}));
test('partially selected invitation survives background minute refresh',()=>withFixture(f=>{f.q('.invitation details').open=true;f.q('input[value="1"]').checked=false;f.clock.tick(61000);assert.equal(f.q('.invitation details').open,true);assert.equal(f.q('input[value="1"]').checked,false);f.action('partial');assert.deepEqual(f.state().pending,[1]);assert.deepEqual(f.state().done,[2,1,3]);}));
test('confirmation dialog survives background resume',()=>withFixture(f=>{f.action('tray');f.action('update');assert.equal(f.q('dialog').open,true);f.clock.tick(3000);assert.equal(f.q('dialog').open,true);f.action('close-dialog');assert.equal(f.d.activeElement.dataset.action,'update');},'index.html',{pauseUntil:new Date('2026-11-20T10:00:02Z').getTime()}));
test('quit cancellation keeps pet and quit confirmation removes it',()=>withFixture(f=>{f.action('tray');f.action('quit');f.action('close-dialog');assert.ok(f.q('[data-action=pet]'));f.action('quit');f.action('confirm-quit');assert.equal(f.d.querySelector('[data-action=pet]'),null);f.clock.tick(65000);assert.equal(f.d.querySelector('[data-action=pet]'),null);f.action('restart');assert.ok(f.d.querySelector('.welcome-window'));}));

test('timer can end behind an open menu without completing or stealing focus',()=>withFixture(f=>{f.action('tray');f.action('eyes');f.action('start');f.clock.tick(18000);f.click('.pet-more');f.clock.tick(3000);assert.ok(f.d.querySelector('.resident-menu'));assert.ok(f.q('[data-action=micro-done]'));assert.ok(f.d.activeElement.closest('.resident-menu'));assert.equal(f.state(),null);f.key(f.d.activeElement,'Escape');assert.ok(f.d.querySelector('.break-window'));f.action('micro-done');assert.equal(f.state().done[2],4);}));
test('menu toggle returns to its original utility window and trigger',()=>withFixture(f=>{f.action('tray');f.action('main');f.click('.window-statusbar [data-action=tray]');f.key(f.d.activeElement,'Escape');assert.ok(f.d.querySelector('.utility-window'));assert.ok(f.d.activeElement.closest('.window-statusbar'));}));
test('menu arrow navigation wraps without leaving the menu',()=>withFixture(f=>{f.action('tray');f.key(f.d.activeElement,'End');assert.equal(f.d.activeElement.dataset.action,'desktop');f.key(f.d.activeElement,'ArrowDown');assert.equal(f.d.activeElement.dataset.action,'main');f.key(f.d.activeElement,'ArrowUp');assert.equal(f.d.activeElement.dataset.action,'desktop');}));
test('drag clamps the entire companion within the modeled workspace',()=>withFixture(f=>{f.geometry();const b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',-5000,-5000);let r=f.q('.resident-companion').getBoundingClientRect();assert.ok(r.left>=0&&r.top>=0);f.pointer(b,'pointermove',9000,9000);r=f.q('.resident-companion').getBoundingClientRect();assert.ok(r.right<=1200&&r.bottom<=750);f.pointer(b,'pointerup',9000,9000);assert.equal(f.state(),null);}));
test('lost pointer capture flushes deferred updates and restores pet',()=>withFixture(f=>{f.clock.tick(59000);f.geometry();const b=f.q('[data-action=pet]');f.pointer(b,'pointerdown',1000,600);f.pointer(b,'pointermove',950,550);f.clock.tick(2000);f.pointer(b,'lostpointercapture',950,550);assert.equal(f.q('.pet-character').dataset.expression,'landed');f.clock.tick(2300);assert.notEqual(f.q('.pet-character').dataset.expression,'held');}));
test('right click is an optional shortcut with a keyboard return path',()=>withFixture(f=>{f.q('[data-action=pet]').dispatchEvent(new f.w.MouseEvent('contextmenu',{bubbles:true,cancelable:true,button:2}));assert.ok(f.d.querySelector('.resident-menu'));f.key(f.d.activeElement,'Escape');assert.equal(f.d.querySelector('.resident-menu'),null);assert.equal(f.state(),null);}));
(async()=>{const results=[];for(const c of cases){try{await c.run();results.push({name:c.name,ok:true});console.log('PASS',c.name);}catch(e){results.push({name:c.name,ok:false,error:e.message});console.log('FAIL',c.name,'\n ',e.message);}}const failed=results.filter(x=>!x.ok).length;console.log(`${results.length-failed}/${results.length} passed`);if(process.env.MOVEBIT_RESULTS)fs.writeFileSync(process.env.MOVEBIT_RESULTS,JSON.stringify(results,null,2));process.exitCode=failed?1:0;})();
