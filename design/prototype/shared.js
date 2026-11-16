
(() => {
'use strict';
const view=document.body.dataset.view;
const empty=view==='empty';
const key=empty?'movebit-polish-empty-v2':'movebit-polish-v2';
const seed={minutes:empty?0:192,sitting:empty?0:34,longest:empty?0:52,counts:empty?[0,0,0]:[2,1,3],done:empty?[0,0,0]:[1,1,3],pending:empty?[]:[0,1],hidden:false,laterUntil:0,pauseUntil:0,focus:false,sound:false,dnd:false,from:'22:00',to:'07:00',startup:false,language:'zh',records:empty?[]:[{day:'11-05',minutes:174},{day:'11-06',minutes:201},{day:'11-07',minutes:150},{day:'11-08',minutes:227},{day:'11-09',minutes:117},{day:'11-10',minutes:239}],started:false};
let state={...seed},storage=true;
try{const saved=JSON.parse(localStorage.getItem(key)||'null');if(saved)state={...seed,...saved};}catch{storage=false;}
let dark=false;try{dark=localStorage.getItem('movebit-theme')==='dark'||(!localStorage.getItem('movebit-theme')&&matchMedia('(prefers-color-scheme: dark)').matches)}catch{}
document.documentElement.classList.toggle('dark',dark);
const app=document.getElementById('app');
const kinds=['起身','喝水','护眼'];

let petSequence=0,playCount=0,moodUntil=0,petReset=null;
function petArt(expression){
 const id='mubi-volume-'+(++petSequence);
 const smiling=['done','happy','hello','move','landed'].includes(expression);
 const resting=['focus','sleep','eyes','later'].includes(expression);
 const held=expression==='held';
 const eyes=resting?'<path d="M42 65q5 4 10 0M69 65q5 4 10 0"/>':smiling?'<path d="M42 66q5-8 10 0M69 66q5-8 10 0"/>':expression==='wink'?'<path d="M42 65l9 3-9 3"/><ellipse cx="74" cy="66" rx="3" ry="4" fill="var(--mubi-ink)" stroke="none"/>':held?'<ellipse cx="47" cy="64" rx="4" ry="5" fill="var(--mubi-ink)" stroke="none"/><ellipse cx="74" cy="64" rx="4" ry="5" fill="var(--mubi-ink)" stroke="none"/>':'<ellipse cx="47" cy="65" rx="3" ry="4" fill="var(--mubi-ink)" stroke="none"/><ellipse cx="74" cy="65" rx="3" ry="4" fill="var(--mubi-ink)" stroke="none"/>';
 const mouth=held?'<ellipse cx="61" cy="78" rx="3" ry="4" fill="var(--mubi-ink)"/>':smiling?'<path d="M55 77q6 10 12 0" fill="var(--mubi-mouth)" stroke="var(--mubi-ink)" stroke-width="1.5"/>':'<path d="M57 77q4 4 8 0" fill="none" stroke="var(--mubi-ink)" stroke-width="1.8" stroke-linecap="round"/>';
 const prop=expression==='water'?'<g class="mubi-prop"><path d="M76 89h20l-2 22H78z" fill="var(--pet-water-soft)" stroke="var(--pet-water)" stroke-width="2"/><path d="M80 100h13l-1 9H81z" fill="var(--pet-water)" opacity=".6"/><path d="M96 93h4q6 7-5 10" fill="none" stroke="var(--pet-water)" stroke-width="2"/><path d="M77 99q-9-4-12 2" fill="none" stroke="var(--mubi-shadow)" stroke-width="5" stroke-linecap="round"/></g>':expression==='eyes'?'<g class="mubi-prop" fill="none" stroke="var(--pet-leaf)" stroke-width="2" stroke-linecap="round"><path d="M82 27q10-15 22-9-3 14-19 13M85 30l12-8"/></g>':expression==='focus'?'<g class="mubi-prop" fill="none" stroke="var(--pet-focus)" stroke-width="3"><path d="M31 64v-7q28-26 58 0v7"/><rect x="28" y="59" width="8" height="17" rx="4" fill="var(--pet-focus)"/><rect x="85" y="59" width="8" height="17" rx="4" fill="var(--pet-focus)"/></g>':expression==='done'?'<g class="mubi-prop" fill="none" stroke="var(--pet-gold)" stroke-width="2.5" stroke-linecap="round"><path d="M13 44v10m-5-5h10M103 37v8m-4-4h8M100 91l4 4 8-10"/></g>':expression==='move'?'<g class="mubi-prop" fill="none" stroke="var(--pet-coral)" stroke-width="2.5" stroke-linecap="round"><path d="M16 72l-6-6 6-6M105 60l6 6-6 6"/></g>':'';
 return `<svg class="mubi" aria-hidden="true" width="180" height="210" viewBox="0 0 120 140"><defs><linearGradient id="${id}" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="var(--mubi-light)"/><stop offset=".55" stop-color="var(--mubi-body)"/><stop offset="1" stop-color="var(--mubi-deep)"/></linearGradient></defs><ellipse class="mubi-ground" cx="60" cy="132" rx="30" ry="4" fill="var(--mubi-shadow)" opacity=".32"/><g class="mubi-figure"><g class="mubi-ear"><path d="M52 24C47 13 40 7 32 6 30 14 36 23 45 27 48 28 51 26 52 24Z" fill="var(--mubi-fin)"/><path d="M74 23C71 14 66.5 8 60.5 6 58.5 13 62.5 21.5 70 25 72 26 74 25 74 23Z" fill="var(--mubi-fin)"/></g><path d="M58 16C82 18 106 46 109 82 111 104 92 124 60 124 33 124 12.5 106 11 84 9.5 52 34 14 58 16Z" fill="url(#${id})"/><ellipse cx="38" cy="116" rx="12" ry="6" fill="var(--mubi-deep)"/><ellipse cx="82" cy="116" rx="12" ry="6" fill="var(--mubi-deep)"/><ellipse cx="42" cy="34" rx="18" ry="10" fill="#fff" opacity="var(--mubi-rim)"/><g class="mubi-face"><g fill="none" stroke="var(--mubi-ink)" stroke-width="2.5" stroke-linecap="round">${eyes}</g><ellipse cx="36" cy="77" rx="7" ry="3.5" fill="var(--pet-blush)" opacity="${smiling||expression==='wink'?'.6':'.28'}"/><ellipse cx="85" cy="77" rx="7" ry="3.5" fill="var(--pet-blush)" opacity="${smiling||expression==='wink'?'.6':'.28'}"/>${mouth}</g><path class="mubi-hand left" d="M22 91q-10 3-7 11 5 6 11-2" fill="var(--mubi-fin)"/><path class="mubi-hand right" d="M96 90q11 4 8 12-5 5-11-3" fill="var(--mubi-fin)"/>${prop}</g></svg>`;
}
function petState(){
 if(['done','happy','wink','peek','held','landed'].includes(mood)&&Date.now()<moodUntil)return mood;
 if(state.focus)return 'focus';
 if(state.pauseUntil>Date.now()||quietHours())return 'sleep';
 if(state.laterUntil>state.minutes)return 'later';
 if(current==='onboarding')return 'hello';
 if(current==='micro')return duration===120?'move':'eyes';
 if(!state.hidden&&state.pending.length)return state.pending.includes(1)?'water':state.pending.includes(0)?'move':'eyes';
 return 'waiting';
}
const petWords={landed:'站稳啦，就在这里陪你。',waiting:'你忙你的，我在。',hello:'你好呀，很高兴见到你。',water:'给自己，也添一点水。',move:'走两步？我陪你。',eyes:'看看远处，让眼睛透口气。',done:'这次休息，我记住啦。',later:'好呀，待会儿再见。',focus:'专心吧，我会小小声。',sleep:'休息一下，我也眯一会儿。',happy:'嘿嘿，被你发现啦。',wink:'收到一个摸摸，回你一个眨眼。',peek:'在呢，刚才偷偷看了你一眼。',held:'慢一点，我的叶子要飞啦。'};
function updatePets(){for(const node of app.querySelectorAll('.pet-character')){const expression=petState();node.dataset.chat=String(Date.now()<moodUntil);if(node.dataset.expression===expression)return;node.dataset.expression=expression;node.querySelector('.pet-art').innerHTML=petArt(expression);const caption=node.querySelector('.pet-caption');if(caption)caption.textContent=english()?translate(petWords[expression]):petWords[expression];} }
function reactPet(expression){mood=expression;moodUntil=Date.now()+2200;updatePets();clearTimeout(petReset);petReset=setTimeout(()=>{mood='waiting';moodUntil=0;updatePets();},2200);}

let message='',mood='waiting',period=7,chartDay=null,microMode='invite',duration=20,remaining=20,deadline=0,timer=null,dragPoint=null,justDragged=false,petX=0,returnFocus=null;
const tr={ '设置与统计':'Settings & activity','运行中':'Running','已暂停':'Paused','专注中':'Focused','恢复提醒':'Resume reminders','暂停 1 小时':'Pause for 1 hour','开启专注':'Start focus','结束专注':'End focus','稍后再说':'Remind me later','隐藏这次':'Hide this invitation','做到了':'Done','逐项确认':'Confirm individually','开始':'Start','做好了':'Done','停止计时':'Stop timer','重新开始':'Start again','休息一下':'Take a break','提醒设置':'Reminder settings','历史与洞察':'History & insights','关于 MoveBit':'About MoveBit','提示音':'Reminder sound','免打扰时段':'Quiet hours','开机自启':'Launch at login','语言':'Language','跟随系统':'System default','中文':'简体中文','今日活跃':'Active today','最近 7 天':'Last 7 days','最近 30 天':'Last 30 days','7 天':'7 days','30 天':'30 days','检查更新':'Check for updates','更多操作':'More actions','隐藏':'Hide','全部完成':'Complete all','确认所选':'Confirm selected','取消':'Cancel','关闭':'Close','起身':'Move','喝水':'Water','护眼':'Eyes','2 分钟拉伸':'2-minute stretch','20 秒护眼':'20-second eye break','复位沐比':'Reset Mubi position','退出 MoveBit':'Quit MoveBit','数据位置':'Data location','问题反馈':'Feedback','官网':'Website','当前连续活跃':'Current active session','今日最长连续':'Longest session today','近 30 天最长连续':'Longest in 30 days','近 30 天活跃日均':'Daily average in 30 days','暂无记录':'No records yet','不计完成':'Not marked as done','从':'From','到':'To'};

Object.assign(tr,{
'亮色':'Light','暗色':'Dark','切换亮暗主题':'Switch light and dark theme','桌面提醒':'Desktop reminder','托盘':'Tray','初次见面':'Welcome','原型总览':'Prototype overview','本地交互原型 · 示例数据':'Interactive prototype · Sample data',
'当前环境不支持存储，本次操作仅在当前页面保留':'Storage is unavailable. Changes stay in this page only.',
'轻点说「做到了」 · 拖动换位置':'Tap to confirm all · Drag to move',
'摸摸沐比，确认当前全部提醒；按方向键移动位置':'Tap Mubi to confirm all pending reminders; use arrow keys to move',
'一起休息一下':'A little break together','一起休息一下。':'A little break together.',
'收到，照顾好自己。':'Got it. Take care of yourself.',
'我在这里，等下一次小休息。':'Here when your next break comes.',
'到点再见，安心做自己的事。':'See you at the next break. Carry on at your own pace.',
'这次邀请已收起，恢复后再一起提醒。':'This invitation is tucked away. It will return when reminders resume.',
'好，稍后见。':'Sure. See you in a bit.',
'这次先收起来。':'Tucked away for now.',
'没有记为完成；仍可从托盘回应。':'Not marked as done. You can still respond from the tray.',
'查看待回应':'View pending reminders',
'未选事项继续等待；「做到了」确认本次全部事项。':'Unchecked items stay pending. “Done” confirms every item in this invitation.',
'稍后：10 活跃分钟后再提醒。隐藏：本次不再浮现，托盘仍可回应。':'Later: return after 10 active minutes. Hide: keep this invitation in the tray without showing it again.',
'仅记录使用中的活跃时间，不代表健康评分。':'Computer activity time, not a health score.',
'暂无记录':'No records yet','开始使用后，每天的活跃时间会出现在这里。':'Your daily activity will appear here as you use MoveBit.',
'工作模式洞察':'Activity insights',
'最活跃日：11-04 · 3 小时 51 分钟。长时间活跃不是目标，记得留出休息。':'Most active day: Nov 4 · 3 hr 51 min. Longer is not a goal. Leave room for breaks.',
'节奏已调好，无需设置提醒间隔。':'A balanced rhythm is ready. No reminder intervals to configure.',
'提醒出现时轻响一声；专注时静默':'A soft sound with each reminder; always silent in focus.',
'时段内不弹出、不发声，结束后合并提醒':'No popups or sounds during quiet hours. Reminders combine afterwards.',
'登录电脑后启动 MoveBit':'Start MoveBit when you sign in.',
'跨夜时段也适用':'Overnight schedules are supported',
'界面语言':'Interface language','修改后自动保存':'Changes save automatically',
'轻轻提醒，自己决定。数据只留在本机。':'A gentle reminder. Your choice. All data stays on your device.',
'自动检查更新，不静默安装。以 BUSL-1.1 授权发布（源码可得）。':'Updates are checked automatically and never installed silently. Source available under BUSL-1.1.',
'今日活跃':'Active today','安心忙，提醒已收起':'Carry on. Reminders are tucked away.',
'有一条邀请等你回应':'One invitation is waiting for you',
'活跃时间指使用电脑的时间，不是运动时长。':'Active time means computer use, not exercise.',
'离开电脑时不累计':'Time away does not count',
'次回应':'responses',
'回应由你确认，不代表应用测量或验证了休息。':'Responses are your own reports. The app does not measure or verify your breaks.',
'一个沐比，一条邀请':'One Mubi. One invitation.',
'提醒在身边，工作照常。':'A reminder nearby. Work carries on.',
'同一时刻只在一个显示器上出现，不遮住整个工作台。':'Present on one display at a time, without taking over your desktop.',
'主显示器 · 当前工作区':'Main display · Current workspace',
'扩展显示器':'Extended display','邀请不复制，回应不重复。':'One invitation. No duplicate responses.',
'随时找到沐比。':'Mubi is always close by.',
'暂停和专注会收起邀请。专注结束只汇总一次，不补发一串通知。':'Pause and focus tuck invitations away. Ending focus brings one summary, never a queue of notifications.',
'时间到了，感觉如何？':'Time is up. How do you feel?',
'给自己一点空隙。':'Make a little space for yourself.',
'站起来，轻轻活动肩膀':'Stand up and gently move your shoulders',
'看看远处，放松眼睛':'Look into the distance and relax your eyes',
'肩膀向后绕两圈，再走几步；不舒服就停。':'Roll your shoulders back, then take a few steps. Stop if it feels uncomfortable.',
'把目光从屏幕移开，看看远处。':'Take your eyes off the screen and look into the distance.',
'随时可以停，不需要坚持到最后。':'Stop whenever you like. There is no need to finish the timer.',
'休息好了就点「做好了」。计时结束不会自动算完成。':'Tap “Done” when you feel rested. The timer does not confirm a break for you.',
'点「开始」后计时；这是一份邀请。':'The timer starts when you choose. This is an invitation.',
'改为 20 秒护眼':'Switch to a 20-second eye break','改为 2 分钟拉伸':'Switch to a 2-minute stretch',
'你好，我是沐比。':'Hi, I’m Mubi.',
'到点提醒你喝水、起身、看看远处。':'I’ll remind you to drink water, move and look into the distance.',
'什么时候休息，由你决定。':'When to take a break is up to you.',
'摸摸我说「做到了」，也可以稍后再说。':'Tap me to say “Done”, or ask me to come back later.',
'所有数据只留在本机。':'All your data stays on this device.',
'节奏已调好，直接开始就好。':'A balanced rhythm is ready. Just start.',
'请选择至少一项，或直接收起逐项确认。':'Select at least one item, or close the individual checklist.',
'记下了，剩下的按自己的节奏来。':'Noted. Take the rest at your own pace.',
'收到，照顾好自己。完成由你确认。':'Noted. Take care of yourself. Completion is your own report.',
'时间到了，休息好了再确认。':'Time is up. Confirm when you feel rested.',
'沐比在这里。待回应事项可从托盘查看。':'Mubi is here. Pending reminders are available in the tray.',
'好，10 活跃分钟后再见。不算完成。':'See you after 10 active minutes. Not marked as done.',
'这次邀请已收起，没有记为完成。托盘仍保留回应入口。':'Invitation hidden, not marked as done. You can still respond from the tray.',
'暂停一小时，已有邀请暂时收起；到期自动恢复。':'Paused for one hour. Invitations are tucked away and resume automatically.',
'提醒已恢复。':'Reminders resumed.',
'安心专注，邀请先收起，提示音保持静默。':'Focus in peace. Invitations are tucked away and sounds are muted.',
'计时已停止，没有记为完成。':'Timer stopped. Not marked as done.',
'记下这次休息了。继续按自己的节奏来。':'Break noted. Continue at your own pace.',
'已收起休息卡，没有记为完成。':'Break card hidden. Not marked as done.',
'很高兴认识你。需要时，托盘里随时能找到我。':'Nice to meet you. You can always find me in the tray.',
'沐比的位置已复位。':'Mubi’s position has been reset.',
'更新服务尚未连接。暂时无法检查新版本，不会自动安装任何内容。':'The product checks GitHub Releases and never installs silently. This prototype is not connected to the update service and cannot check for a new version.',
'此入口尚未配置，请稍后再试。':'No confirmed URL was supplied. This entry is preserved without navigating to a guessed address.',
'数据只留在本机。当前尚无法打开系统数据目录。':'Product data stays on your device. This prototype uses browser storage and cannot open the native app’s data directory.',
'退出后将不再收到提醒。':'You will no longer receive reminders after quitting.',
'退出原型会话':'End prototype session','已退出':'Session ended',
'这次先到这里。':'See you next time.',
'原型会话已结束，没有关闭浏览器或系统应用。':'The prototype session has ended. Your browser and system apps remain open.',
'已保存，本地设置已更新。':'Saved. Local settings updated.',
'已更新，本次页面内有效。':'Updated for this page only.',
'已收起，没有记为完成。':'Hidden, not marked as done.',
'暂停已到期，提醒恢复了。':'Pause ended. Reminders resumed.',
'每日活跃分钟，选择柱形查看详情':'Daily active minutes. Select a bar for details.'
});
Object.assign(tr,{
'和沐比一起，留一点休息的空隙':'Make a little room for rest with Mubi',
'忙，也要照顾好自己。':'Busy days deserve little breaks.',
'小时':'hr','分钟':'min',
'沐比有一份小小的休息邀请':'Mubi has a little invitation for you',
'这次提醒已收起，托盘里仍可回应':'Invitation tucked away; respond from the tray anytime',
'沐比的提醒':'A note from Mubi','休息这件事，听你的。':'Your break. Your choice.',
'一起做完，或一件一件来。':'All at once, or one little thing at a time.',
'现在就想休息？':'Ready for a break?',
'你忙你的，我在。':'You do your thing. I’m here.',
'你好呀，很高兴见到你。':'Hello! I’m happy to meet you.',
'给自己，也添一点水。':'A little water for you, too.',
'走两步？我陪你。':'A few steps? I’ll come along.',
'看看远处，让眼睛透口气。':'Look into the distance. Let your eyes breathe.',
'这次休息，我记住啦。':'A little break, duly noted.',
'好呀，待会儿再见。':'Sure. See you in a little while.',
'专心吧，我会小小声。':'Focus away. I’ll be very quiet.',
'休息一下，我也眯一会儿。':'Take a breather. I’ll rest my eyes, too.',
'嘿嘿，被你发现啦。':'Hehe. You found me!',
'收到一个摸摸，回你一个眨眼。':'A little pat for me. A wink for you.',
'在呢，刚才偷偷看了你一眼。':'Here! Just sneaking a little peek.',
'慢一点，我的叶子要飞啦。':'Easy there! Mind my little leaves.',
'轻点完成本次全部提醒 · 拖动换位置':'Tap to complete this invitation · Drag to move',
'摸摸沐比，不会记为完成':'Pat Mubi. No reminders will be marked done.',
'一起慢下来':'Let’s slow down together',
'轻点沐比完成本次全部提醒；拖动或方向键移动位置':'Tap Mubi to complete this invitation; drag or use arrow keys to move',
'摸摸沐比，看看它的回应，不会记录完成':'Pat Mubi to see a response. Does not mark reminders done.',
'站稳啦，就在这里陪你。':'Landed! I’ll keep you company right here.'
});
Object.assign(tr,{
'桌面工作区':'Desktop workspace','桌面上的沐比':'Mubi on your desktop',
'摸摸沐比；按住拖动，方向键移动；不会记录完成':'Pat Mubi; drag or use arrow keys to move. Does not mark reminders done.',
'更新服务尚未连接。暂时无法检查新版本，不会自动安装任何内容。':'The update service is not connected. No update can be checked or installed.',
'此入口尚未配置，请稍后再试。':'This entry is not configured yet. Please try again later.',
'数据只留在本机。当前尚无法打开系统数据目录。':'Data stays on your device. The system data directory cannot be opened yet.',
'关闭窗口，继续在桌面提醒':'Close window; keep desktop reminders running',
'隐藏这次提醒，不记完成':'Hide this invitation without marking it done',
'沐比菜单':'Mubi menu','打开 MoveBit 菜单':'Open MoveBit menu',
'只做了一部分':'Only did some of these','未选的继续等你。':'Unchecked items will wait for you.',
'稍后':'Later','今日':'Today','历史':'History','设置':'Settings','关于':'About',
'窗口内容':'Window content','使用电脑的时间，不是运动时长。':'Time using your computer, not exercise.',
'本轮连续活跃':'Current active session','完成由你确认，不代表应用检测了休息。':'Your own report. The app does not detect or verify breaks.',
'提醒暂时收起':'Reminders are tucked away','有待回应的提醒':'There are pending reminders',
'回到沐比身边':'Back to Mubi','数据只留在本机':'Data stays on your device',
'当前无法保存设置，操作仅在本次会话有效。':'Settings cannot be saved. Changes last for this session only.',
'返回桌面':'Back to desktop','切换为亮色':'Switch to light','切换为暗色':'Switch to dark',
'站起来，松松肩膀':'Stand up and relax your shoulders',
'休息好了再确认，不会自动记为完成。':'Confirm when rested. Completion is never automatic.',
'准备好了再开始，随时可以停。':'Start when ready. Stop whenever you like.',
'先收起来':'Tuck away','开始陪伴':'Let’s begin',
'喝水、起身、看看远处，':'Drink water, move and look into the distance.',
'到点我会轻轻提醒你。':'I’ll give you a gentle reminder when it’s time.',
'摸摸我，或拎着我换个位置。':'Pat me, or pick me up and move me.',
'休息好了，再点「做到了」。':'When rested, tap “Done”.',
'MoveBit 已退出':'MoveBit has quit','重新打开':'Reopen',
'起来走走，喝口水？':'Stretch your legs and have some water?',
'起来走走？':'Stretch your legs?','喝口水？':'A sip of water?',
'看看远处？':'Look into the distance?',
'起来走走，看看远处？':'Stretch your legs and look into the distance?',
'喝口水，看看远处？':'Some water and a look into the distance?',
'起来走走，喝口水，看看远处？':'Move, drink some water and rest your eyes?',
'这次提醒已收起':'This invitation is tucked away'
});
function english(){return state.language==='en'||(state.language==='system'&&navigator.language.toLowerCase().startsWith('en'));}
function translate(text){
 const lead=text.match(/^\s*/)[0],tail=text.match(/\s*$/)[0],v=text.trim();
 if(tr[v])return lead+tr[v]+tail;
 let out=v;
 const rules=[
 [/^已暂停至 (.+)$/,'Paused until $1'],[/^免打扰中$/,'Quiet hours'],
 [/^再活跃 (\d+) 分钟后提醒。已有事项会合并，不叠加打扰。$/,'Back after $1 active minutes. Pending items combine into one invitation.'],
 [/^再活跃 (\d+) 分钟后见$/,'See you after $1 active minutes'],
 [/^下次起身：约 (\d+) 活跃分钟后$/,'Next move break: in about $1 active minutes'],
 [/^本轮连续活跃 (\d+) \/ 50 分钟$/,'Current active session: $1 / 50 min'],
 [/^提醒 (\d+) 次$/,'$1 reminders'],
 [/^专注结束，待回应事项已合并成一条邀请。$/,'Focus ended. Pending items are combined into one invitation.'],
 [/^专注结束，当前没有待回应事项。$/,'Focus ended. No pending reminders.'],
 [/^起身做到了$/,'Move break done'],[/^喝水做到了$/,'Water break done'],[/^护眼做到了$/,'Eye break done'],
 [/^起身，也记得喝水。$/,'Move a little. Have some water.'],
 [/^起身，也记得喝水，也记得护眼。$/,'Move, drink some water and rest your eyes.'],
 [/^起身，也记得护眼。$/,'Move a little and rest your eyes.'],[/^喝水，也记得护眼。$/,'Have some water and rest your eyes.'],
 [/^起身。$/,'Move a little.'],[/^喝水。$/,'Have some water.'],[/^护眼。$/,'Rest your eyes.'],
 [/站起来走几步，/g,'Stand up and take a few steps. '],[/喝口水，/g,'Have some water. '],[/看看远处，/g,'Look into the distance. '],[/按自己的节奏就好。/g,'At your own pace.'],
 [/本轮久坐/g,'Current sitting session'],[/最长连续/g,'Longest session'],[/活跃 /g,'Active '],[/提醒 /g,'Reminders '],
 [/(\d+) 天合计 /g,'$1-day total: '],[/(\d+) 个活跃日/g,'$1 active days'],
 [/(\d+) 小时/g,'$1 hr'],[/(\d+) 分钟/g,'$1 min'],[/(\d+) 次/g,'$1 times'],[/^秒$/,'sec'],[/到期自动恢复/g,'Resumes automatically']
 ];
 for(const [pattern,value] of rules)out=out.replace(pattern,value);
 return lead+out+tail;
}
function localize(){document.documentElement.lang=english()?'en':'zh-CN';if(!english())return;const walker=document.createTreeWalker(app,NodeFilter.SHOW_TEXT);let n;while(n=walker.nextNode())n.nodeValue=translate(n.nodeValue);for(const el of app.querySelectorAll('[aria-label],[title]'))for(const attr of ['aria-label','title'])if(el.hasAttribute(attr))el.setAttribute(attr,translate(el.getAttribute(attr)));}

function persist(){try{localStorage.setItem(key,JSON.stringify(state));}catch{storage=false;}}
function say(text){message=text;const el=document.getElementById('feedback');if(el)el.textContent=english()?translate(text):text;}
function time(ts){return new Date(ts).toLocaleTimeString('zh-CN',{hour:'2-digit',minute:'2-digit',hour12:false})}
function quietHours(){if(!state.dnd)return false;const now=new Date(),m=now.getHours()*60+now.getMinutes(),a=state.from.split(':').map(Number),b=state.to.split(':').map(Number),start=a[0]*60+a[1],end=b[0]*60+b[1];return start===end|| (start<end?m>=start&&m<end:m>=start||m<end)}
function suspended(){return state.pauseUntil>Date.now()||state.focus||quietHours()}
function status(){return state.pauseUntil>Date.now()?`已暂停至 ${time(state.pauseUntil)}`:state.focus?'专注中':quietHours()?'免打扰中':'运行中'}
function btn(label,action,cls='',extra=''){return `<button type="button" class="${cls}" data-action="${action}" ${extra}>${label}</button>`}

function pet(interactive=false){
 const expression=petState(),art=`<span class="pet-art">${petArt(expression)}</span>`;
 const label='摸摸沐比；按住拖动，方向键移动；不会记录完成';
 return `<div class="pet pet-character ${interactive?'pet-desktop':'pet-passive'}" data-expression="${expression}" data-chat="${Date.now()<moodUntil}"><p class="pet-caption">${petWords[expression]}</p><div class="pet-scene">${interactive||current==='onboarding'?`<button type="button" class="pet-button" data-action="${interactive?'pet':'petplay'}" aria-label="${label}">${art}</button>`:`<div class="pet-still">${art}</div>`}</div></div>`;
}
function glyph(name){const paths={close:'<path d="m6 6 12 12M18 6 6 18"/>',more:'<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',leaf:'<path d="M12 21C3 21 3 11 12 5c9 6 9 16 0 16Z"/><path d="M12 5C9 1 6 2 6 2c0 4 4 5 6 3Z"/>',back:'<path d="m14 5-7 7 7 7"/>'};return `<svg class="od-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name]}</svg>`;}
function windowBar(title){return `<header class="app-titlebar"><span class="window-app-mark">${glyph('leaf')}</span><h1>${title}</h1><span class="sp"></span>${btn(glyph('close'),'desktop','window-close','aria-label="关闭窗口，继续在桌面提醒"')}</header>`;}
function frame(label,body){
 const hasWindow=current!=='desktop',showPet=current!=='onboarding',openInvite=current==='desktop'&&state.pending.length&&!suspended()&&!state.hidden&&state.laterUntil<=state.minutes;
 return `<main class="desktop-stage ${hasWindow?'has-window':''}" aria-label="桌面工作区"><div class="desktop-layout"><div class="window-slot">${hasWindow?body:''}</div>${showPet?`<aside class="resident-companion" aria-label="桌面上的沐比" style="translate:${petX}px ${petY}px"><div class="resident-invitation" ${openInvite?'':'hidden'}>${openInvite?invitation():''}</div>${pet(true)}<div class="pet-menu-anchor">${btn(glyph('more'),'tray','pet-more','aria-label="沐比菜单" aria-haspopup="menu"')}</div></aside>`:''}</div><div class="desktop-system-entry">${btn(glyph('leaf')+'<span>MoveBit</span>','tray','system-tray-button','aria-label="打开 MoveBit 菜单" aria-haspopup="menu"')}</div><div id="feedback" class="sr-only" role="status" aria-live="polite">${message}</div></main><dialog id="dialog" aria-labelledby="dialogTitle"><h2 id="dialogTitle"></h2><div id="dialogBody"></div><div class="actions">${btn('关闭','close-dialog')}</div></dialog>`;
}

function controls(){return `<div class="actions">${btn(state.pauseUntil>Date.now()?'恢复提醒':'暂停 1 小时','pause')}${btn(state.focus?'结束专注':'开启专注','focus','quiet')}</div>`}

function invitation(){
 if(!state.pending.length)return '';
 if(suspended())return `<div class="bubble"><p>${status()}</p>${controls()}</div>`;
 if(state.laterUntil>state.minutes)return `<div class="bubble"><p>再活跃 ${state.laterUntil-state.minutes} 分钟后见</p></div>`;
 if(state.hidden)return `<div class="bubble"><p>这次提醒已收起</p>${btn('查看待回应','reveal','quiet')}</div>`;
 const words=state.pending.map(i=>['起来走走','喝口水','看看远处'][i]);
 return `<section class="bubble invitation" aria-label="休息邀请"><div class="invitation-heading"><h2>${words.join('，')}？</h2>${btn(glyph('close'),'hide','invitation-close','aria-label="隐藏这次提醒，不记完成"')}</div><div class="actions">${btn('做到了','done','primary')}${btn('稍后','later','quiet')}</div><details><summary class="small">只做了一部分</summary><div class="kind-list">${state.pending.map(i=>`<label><input type="checkbox" name="complete" value="${i}" checked>${kinds[i]}做到了</label>`).join('')}</div>${btn('确认所选','partial','quiet')}<p class="small muted">未选的继续等你。</p></details></section>`;
}

function history(){const all=[...state.records,...(state.minutes?[{day:'11-11',minutes:state.minutes}]:[])],data=all.slice(-period),total=data.reduce((s,r)=>s+r.minutes,0),max=Math.max(1,...data.map(r=>r.minutes));return `<div class="row between"><p class="muted">仅记录使用中的活跃时间，不代表健康评分。</p><div class="segment">${btn('7 天','period','',`data-value="7" aria-pressed="${period===7}"`)}${btn('30 天','period','',`data-value="30" aria-pressed="${period===30}"`)}</div></div>${data.length?`<div class="chart" role="group" aria-label="每日活跃分钟，选择柱形查看详情">${data.map((r,i)=>`<button class="chart-col ${i===data.length-1?'today':''}" type="button" data-action="chart" data-value="${r.day}" aria-label="${r.day}，活跃 ${r.minutes} 分钟"><i style="height:${Math.max(3,r.minutes/max*160)}px"></i><span>${r.day.slice(3)}</span></button>`).join('')}</div><p class="chart-caption" aria-live="polite">${chartDay?`${chartDay} · 活跃 ${data.find(r=>r.day===chartDay)?.minutes||0} 分钟${chartDay==='11-11'?` · 提醒 ${state.counts.reduce((a,b)=>a+b,0)} 次 · 最长连续 ${Math.max(state.longest,state.sitting)} 分钟`:''}`:`${period} 天合计 ${Math.floor(total/60)} 小时 ${total%60} 分钟 · ${data.length} 个活跃日`}</p>`:'<div class="empty-note">暂无记录<br>开始使用后，每天的活跃时间会出现在这里。</div>'}<h3 class="section-space">工作模式洞察</h3><div class="insights section-space">${[['当前连续活跃',state.sitting],['今日最长连续',Math.max(state.longest,state.sitting)],['近 30 天最长连续',data.length?108:0],['近 30 天活跃日均',data.length?Math.round(total/data.length):0]].map(([label,n])=>`<div class="od-stat"><span class="small muted">${label}</span><strong>${n?n+' 分钟':'暂无记录'}</strong></div>`).join('')}</div>${data.length?'<p class="small muted section-space">最活跃日：11-04 · 3 小时 51 分钟。长时间活跃不是目标，记得留出休息。</p>':''}`}
function settings(){return `<p class="muted small">节奏已调好，无需设置提醒间隔。</p>${[['提示音','sound','提醒出现时轻响一声；专注时静默'],['免打扰时段','dnd','时段内不弹出、不发声，结束后合并提醒'],['开机自启','startup','登录电脑后启动 MoveBit']].map(([label,id,hint])=>`<label class="setting od-row"><span class="od-field od-fill"><strong>${label}</strong><small class="muted">${hint}</small></span><input class="od-fixed" type="checkbox" data-setting="${id}" ${state[id]?'checked':''}></label>${id==='dnd'?`<div class="times" ${state.dnd?'':'hidden'}><label>从 <input type="time" data-setting="from" value="${state.from}"></label><label>到 <input type="time" data-setting="to" value="${state.to}"></label><span class="small muted">跨夜时段也适用</span></div>`:''}`).join('')}<label class="setting"><span class="od-field od-fill"><strong>语言</strong><small class="muted">界面语言</small></span><select data-setting="language" aria-label="语言"><option value="system" ${state.language==='system'?'selected':''}>跟随系统</option><option value="zh" ${state.language==='zh'?'selected':''}>简体中文</option><option value="en" ${state.language==='en'?'selected':''}>English</option></select></label><p class="small muted section-space" id="saveStatus">修改后自动保存</p>`}
function about(){return `<h3>MoveBit v0.0.10</h3><p class="muted small section-space">轻轻提醒，自己决定。数据只留在本机。</p><div class="actions">${btn('检查更新','update')}${btn('官网','website','quiet')}${btn('问题反馈','feedback','quiet')}${btn('数据位置','data','quiet')}</div><p class="small muted section-space">自动检查更新，不静默安装。以 BUSL-1.1 授权发布（源码可得）。</p>`}
function healthIcon(type){const shapes=['<circle cx="13" cy="4" r="2"/><path d="m10 9 3-2 3 4 3 1M13 7l-2 7 4 3 1 5M11 14l-4 6M10 9l-4 3"/>','<path d="M12 3C9 7 5 11 5 15a7 7 0 0 0 14 0c0-4-4-8-7-12Z"/><path d="M9 16a3 3 0 0 0 3 3"/>','<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12Z"/><circle cx="12" cy="12" r="3"/>'];return `<svg class="od-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${shapes[type]}</svg>`;}

function todayPanel(){return `<div class="window-status row between"><span class="status ${suspended()?'paused':''}" id="statusText">${status()}</span>${btn(state.pauseUntil>Date.now()?'恢复提醒':'暂停 1 小时','pause','quiet')}</div><section class="today-compact"><span class="eyebrow">今日活跃</span><div class="compact-number">${Math.floor(state.minutes/60)?`<span class="od-nowrap">${Math.floor(state.minutes/60)} <small>小时</small></span> `:''}<span class="od-nowrap">${state.minutes%60} <small>分钟</small></span></div><p class="muted small">使用电脑的时间，不是运动时长。</p><div class="session-track"><div class="row between small"><span>本轮连续活跃</span><strong>${state.sitting} / 50 分钟</strong></div><div class="bar"><i style="transform:scaleX(${Math.min(state.sitting/50,1)})"></i></div></div><div class="metrics">${kinds.map((kind,i)=>`<div class="metric"><div class="metric-name">${healthIcon(i)}<span>${kind}</span></div><div class="metric-total"><strong>${state.done[i]}</strong><span>次回应</span></div><small>提醒 ${state.counts[i]} 次</small></div>`).join('')}</div><p class="honest-note">完成由你确认，不代表应用检测了休息。</p></section><div class="next-reminder">${suspended()?'提醒暂时收起':state.pending.length?'有待回应的提醒':`下次起身：约 ${Math.max(1,50-state.sitting)} 活跃分钟后`}${state.pending.length?btn('回到沐比身边','reveal','quiet'):''}</div>`;}
function main(){const content=activeTab==='today'?todayPanel():activeTab==='history'?history():activeTab==='settings'?settings():about();return `<section class="utility-window" aria-label="MoveBit 设置与统计">${windowBar('MoveBit')}<nav class="window-tabs" aria-label="窗口内容">${[['today','今日'],['history','历史'],['settings','设置'],['about','关于']].map(([key,label])=>btn(label,'tab',activeTab===key?'selected':'',`data-tab="${key}" aria-pressed="${activeTab===key}"`)).join('')}</nav><div class="utility-scroll" id="utilityScroll">${content}${!storage?'<p class="storage-notice">当前无法保存设置，操作仅在本次会话有效。</p>':''}</div><footer class="window-statusbar"><span>数据只留在本机</span><span class="sp"></span>${btn(glyph('more'),'tray','quiet','aria-label="沐比菜单" aria-haspopup="menu"')}</footer></section>`;}
function desktop(){return '';}
function tray(){return `<section class="resident-menu" role="menu" aria-label="MoveBit 菜单"><div class="menu-status"><strong>MoveBit</strong><span class="status ${suspended()?'paused':''}">${status()}</span></div>${btn('设置与统计','main')}${state.pending.length?`<div class="menu-divider" role="separator"></div>${btn('做到了','done')}${btn('逐项确认','reveal')}${btn('稍后再说','later')}${btn('隐藏这次','hide')}`:''}<div class="menu-divider" role="separator"></div>${btn(state.focus?'结束专注':'开启专注','focus')}${btn(state.pauseUntil>Date.now()?'恢复提醒':'暂停 1 小时','pause')}<div class="menu-divider" role="separator"></div>${btn('20 秒护眼','eyes')}${btn('2 分钟拉伸','stretch')}${btn('复位沐比','reset')}<div class="menu-divider" role="separator"></div>${btn('检查更新','update')}${btn(dark?'切换为亮色':'切换为暗色','theme')}${btn('退出 MoveBit','quit')}<div class="menu-divider" role="separator"></div>${btn('返回桌面','desktop','menu-return')}</section>`;}
function micro(){const active=microMode==='running',ended=microMode==='ended',stretch=duration===120;return `<section class="break-window" aria-label="微休息">${windowBar(stretch?'2 分钟拉伸':'20 秒护眼')}<div class="break-body"><h2>${ended?'时间到了，感觉如何？':stretch?'站起来，松松肩膀':'看看远处，放松眼睛'}</h2><p class="muted">${stretch?'肩膀向后绕两圈，再走几步；不舒服就停。':'把目光从屏幕移开，看看远处。'}</p>${active?`<div class="timer od-nowrap" id="countdown" role="timer">${remaining} <span class="small">秒</span></div><div class="bar"><i id="timerBar" style="transform:scaleX(${remaining/duration})"></i></div>`:ended?'<p class="break-help">休息好了再确认，不会自动记为完成。</p>':'<p class="break-help">准备好了再开始，随时可以停。</p>'}<div class="actions">${active?btn('做好了','micro-done','primary')+btn('停止计时','stop','quiet'):ended?btn('做好了','micro-done','primary')+btn('重新开始','start','quiet'):btn('开始','start','primary')}${btn('先收起来','micro-hide','quiet')}</div><div class="break-switch">${btn(stretch?'改为 20 秒护眼':'改为 2 分钟拉伸','switch-micro','quiet')}</div></div></section>`;}
function onboarding(){return `<section class="welcome-window">${windowBar('MoveBit')}<div class="welcome-body">${pet(false)}<h2>你好，我是沐比。</h2><p>喝水、起身、看看远处，<br>到点我会轻轻提醒你。</p><p class="small muted">摸摸我，或拎着我换个位置。<br>休息好了，再点「做到了」。</p>${btn('开始陪伴','onboard','primary')}<span class="small muted">所有数据只留在本机。</span></div></section>`;}
let current=view,sessionEnded=false,lastSuspended=suspended(),activeTab='today',petY=0;
const tabScroll={today:0,history:0,settings:0,about:0};

function render(){if(current!=='desktop'){petX=0;petY=0;}const activeAction=app.contains(document.activeElement)?document.activeElement.dataset.action:null;const opened=[...app.querySelectorAll('details[open][data-detail]')].map(d=>d.dataset.detail);const labels={main:'设置与统计',empty:'设置与统计',desktop:'桌面提醒',tray:'托盘',micro:'休息一下',onboarding:'初次见面'};const body=current==='main'||current==='empty'?main():current==='desktop'?desktop():current==='tray'?tray():current==='micro'?micro():onboarding();app.innerHTML=frame(labels[current],body);const scroll=app.querySelector('#utilityScroll');if(scroll)scroll.scrollTop=tabScroll[activeTab]||0;app.querySelectorAll('.resident-menu>button').forEach(el=>el.setAttribute('role','menuitem'));opened.forEach(id=>{const d=app.querySelector(`[data-detail="${id}"]`);if(d)d.open=true});localize();if(activeAction){const target=[...app.querySelectorAll('[data-action]')].find(el=>el.dataset.action===activeAction)||app.querySelector('[data-action=pet],main button');target?.focus({preventScroll:true});}clearTimeout(petReset);if(moodUntil>Date.now())petReset=setTimeout(()=>{mood='waiting';moodUntil=0;updatePets();},Math.max(0,moodUntil-Date.now()));}
function navigate(to){if(timer){clearInterval(timer);timer=null;microMode='invite'}mood='waiting';moodUntil=0;current=to;message='';render();const focus=to==='desktop'?app.querySelector('[data-action=pet]'):app.querySelector('.resident-menu button,.window-close,main button');focus?.focus({preventScroll:true});}
function dialog(title,body,trigger){returnFocus=trigger;document.getElementById('dialogTitle').textContent=title;document.getElementById('dialogBody').innerHTML=body;localize();document.getElementById('dialog').showModal();}
function finish(ids){if(!ids.length){say('请选择至少一项，或直接收起逐项确认。');return;}for(const i of ids){if(state.pending.includes(i)){state.done[i]++;if(i===0)state.sitting=0;}}state.pending=state.pending.filter(i=>!ids.includes(i));state.hidden=false;state.laterUntil=0;mood='done';moodUntil=Date.now()+2200;message=state.pending.length?'记下了，剩下的按自己的节奏来。':'收到，照顾好自己。完成由你确认。';persist();if(current==='tray')current='desktop';render();}
function tick(){if(microMode==='running'){remaining=Math.max(0,Math.ceil((deadline-Date.now())/1000));if(!remaining){clearInterval(timer);timer=null;microMode='ended';message='时间到了，休息好了再确认。';render();document.querySelector('[data-action="micro-done"]')?.focus();return;}const el=document.getElementById('countdown');if(el)el.innerHTML=`${remaining} <span class="small">${english()?'sec':'秒'}</span>`;const bar=document.getElementById('timerBar');if(bar)bar.style.transform=`scaleX(${remaining/duration})`;}}
app.addEventListener('click',e=>{const b=e.target.closest('[data-action]');if(!b)return;const action=b.dataset.action;switch(action){case'theme':dark=!dark;document.documentElement.classList.toggle('dark',dark);try{localStorage.setItem('movebit-theme',dark?'dark':'light')}catch{}render();break;case'done':finish([...state.pending]);break;case'petplay':case'pet':if(justDragged){justDragged=false;break;}playCount++;reactPet(['happy','wink','peek'][(playCount-1)%3]);say(petWords[petState()]);break;case'partial':finish([...app.querySelectorAll('input[name=complete]:checked')].map(el=>Number(el.value)));break;case'later':state.laterUntil=state.minutes+10;state.hidden=false;mood='later';moodUntil=Date.now()+2200;message='好，10 活跃分钟后再见。不算完成。';persist();if(current==='tray')current='desktop';render();break;case'hide':state.hidden=true;message='这次邀请已收起，没有记为完成。托盘仍保留回应入口。';persist();if(current==='tray')current='desktop';render();break;case'reveal':state.hidden=false;state.laterUntil=0;current='desktop';persist();render();break;case'pause':state.pauseUntil=state.pauseUntil>Date.now()?0:Date.now()+3600000;message=state.pauseUntil?'暂停一小时，已有邀请暂时收起；到期自动恢复。':'提醒已恢复。';persist();if(current==='tray')current='desktop';render();break;case'focus':state.focus=!state.focus;message=state.focus?'安心专注，邀请先收起，提示音保持静默。':`专注结束，${state.pending.length?'待回应事项已合并成一条邀请。':'当前没有待回应事项。'}`;persist();if(current==='tray')current='desktop';render();break;case'main':case'tray':case'desktop':navigate(action);break;case'tab':{const scroll=app.querySelector('#utilityScroll');if(scroll)tabScroll[activeTab]=scroll.scrollTop;activeTab=b.dataset.tab;render();app.querySelector(`[data-tab="${activeTab}"]`)?.focus();break;}case'eyes':case'stretch':duration=action==='eyes'?20:120;remaining=duration;microMode='invite';navigate('micro');break;case'start':if(timer)clearInterval(timer);microMode='running';remaining=duration;deadline=Date.now()+duration*1000;render();timer=setInterval(tick,250);break;case'stop':clearInterval(timer);timer=null;microMode='invite';message='计时已停止，没有记为完成。';render();break;case'micro-done':clearInterval(timer);timer=null;const i=duration===20?2:0;if(state.pending.includes(i))state.pending=state.pending.filter(n=>n!==i);state.done[i]++;if(i===0)state.sitting=0;mood='done';moodUntil=Date.now()+2200;persist();microMode='invite';current='desktop';message='记下这次休息了。继续按自己的节奏来。';render();break;case'micro-hide':clearInterval(timer);timer=null;microMode='invite';current='desktop';message='已收起休息卡，没有记为完成。';render();break;case'switch-micro':if(timer)clearInterval(timer);duration=duration===20?120:20;remaining=duration;microMode='invite';render();break;case'period':period=Number(b.dataset.value);chartDay=null;render();app.querySelector(`button[data-action="period"][data-value="${period}"]`)?.focus();break;case'chart':chartDay=b.dataset.value;render();app.querySelector(`button[data-action="chart"][data-value="${chartDay}"]`)?.focus();break;case'onboard':state.started=true;persist();navigate('desktop');say('很高兴认识你。需要时，托盘里随时能找到我。');break;case'reset':petX=0;petY=0;state.hidden=false;persist();message='沐比的位置已复位。';current='desktop';render();break;case'update':dialog('检查更新','<p>更新服务尚未连接。暂时无法检查新版本，不会自动安装任何内容。</p>',b);break;case'website':case'feedback':dialog(action==='website'?'官网':'问题反馈','<p>此入口尚未配置，请稍后再试。</p>',b);break;case'data':dialog('数据位置','<p>数据只留在本机。当前尚无法打开系统数据目录。</p>',b);break;case'quit':dialog('退出 MoveBit','<p>退出后将不再收到提醒。</p><div class="actions">'+btn('取消','close-dialog')+btn('退出 MoveBit','confirm-quit','primary')+'</div>',b);break;case'confirm-quit':sessionEnded=true;if(timer){clearInterval(timer);timer=null;}document.getElementById('dialog').close();app.innerHTML='<main class="desktop-stage ended-desktop" aria-label="已退出"><div class="end-session"><p>MoveBit 已退出</p>'+btn('重新打开','restart','quiet')+'</div></main>';localize();break;case'restart':sessionEnded=false;current='onboarding';render();break;case'close-dialog':document.getElementById('dialog').close();break;}});
app.addEventListener('change',e=>{const el=e.target,id=el.dataset.setting;if(!id)return;state[id]=el.type==='checkbox'?el.checked:el.value;persist();message=storage?'已保存，本地设置已更新。':'已更新，本次页面内有效。';render();app.querySelector(`[data-setting="${id}"]`)?.focus();});
app.addEventListener('click',e=>{if(current==='tray'&&e.target.classList.contains('desktop-stage'))navigate('desktop');});
app.addEventListener('contextmenu',e=>{if(e.target.closest('.pet-button')){e.preventDefault();navigate('tray');}});
app.addEventListener('close',e=>{if(e.target.id==='dialog'&&returnFocus?.isConnected)returnFocus.focus();},true);

app.addEventListener('pointerdown',e=>{const button=e.target.closest('[data-action=pet]');if(!button||e.button!==0)return;const resident=button.closest('.resident-companion');if(!resident)return;const area=app.querySelector('.desktop-layout'),box=resident.getBoundingClientRect(),bounds=area.getBoundingClientRect();dragPoint={x:e.clientX,y:e.clientY,originX:petX,originY:petY,pointer:e.pointerId,button,resident,minX:Math.min(0,bounds.left+16-box.left+petX),maxX:Math.max(0,bounds.right-16-box.right+petX),minY:Math.min(0,bounds.top+16-box.top+petY),maxY:Math.max(0,bounds.bottom-16-box.bottom+petY)};justDragged=false;button.setPointerCapture(e.pointerId);});
app.addEventListener('pointermove',e=>{if(!dragPoint||e.pointerId!==dragPoint.pointer)return;const dx=e.clientX-dragPoint.x,dy=e.clientY-dragPoint.y;if(Math.hypot(dx,dy)>8||justDragged){if(!justDragged){justDragged=true;mood='held';moodUntil=Date.now()+3600000;updatePets();}petX=Math.max(dragPoint.minX,Math.min(dragPoint.maxX,dragPoint.originX+dx));petY=Math.max(dragPoint.minY,Math.min(dragPoint.maxY,dragPoint.originY+dy));dragPoint.resident.style.translate=`${petX}px ${petY}px`;dragPoint.resident.style.setProperty('--drag-tilt',`${Math.max(-8,Math.min(8,dx/10))}deg`);}});
function releasePet(e){if(!dragPoint||e.pointerId!==dragPoint.pointer)return;const wasDragged=justDragged;dragPoint=null;if(wasDragged){reactPet('landed');say('站稳啦，就在这里陪你。');}}
app.addEventListener('pointerup',releasePet);app.addEventListener('pointercancel',e=>{justDragged=true;releasePet(e);});
app.addEventListener('keydown',e=>{
 const menu=app.querySelector('.resident-menu');
 if(menu&&['ArrowDown','ArrowUp','Home','End'].includes(e.key)){e.preventDefault();const items=[...menu.querySelectorAll('button:not(:disabled)')],index=items.indexOf(document.activeElement);let next=e.key==='Home'?0:e.key==='End'?items.length-1:(index+(e.key==='ArrowDown'?1:-1)+items.length)%items.length;items[next]?.focus();return;}
 if(e.target.matches('[data-action=pet]')&&['Enter',' '].includes(e.key))justDragged=false;
 if(e.target.matches('[data-action=pet]')&&['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].includes(e.key)){e.preventDefault();const resident=e.target.closest('.resident-companion'),area=app.querySelector('.desktop-layout'),r=resident.getBoundingClientRect(),a=area.getBoundingClientRect();let dx=e.key==='ArrowLeft'?-8:e.key==='ArrowRight'?8:0,dy=e.key==='ArrowUp'?-8:e.key==='ArrowDown'?8:0;dx=Math.max(a.left+8-r.left,Math.min(a.right-8-r.right,dx));dy=Math.max(a.top+8-r.top,Math.min(a.bottom-8-r.bottom,dy));petX+=dx;petY+=dy;resident.style.translate=`${petX}px ${petY}px`;justDragged=false;}
 if(e.key==='Escape'&&!app.querySelector('dialog[open]')&&current!=='desktop'){e.preventDefault();navigate('desktop');}
});
window.addEventListener('resize',()=>{petX=0;petY=0;const resident=app.querySelector('.resident-companion');if(resident)resident.style.translate='0px 0px';});
setInterval(()=>{if(sessionEnded)return;if(lastSuspended!==suspended()){lastSuspended=suspended();if(current!=='micro')render();}if(state.pauseUntil&&state.pauseUntil<=Date.now()){state.pauseUntil=0;persist();message='暂停已到期，提醒恢复了。';render();}const s=document.getElementById('statusText');if(s)s.textContent=english()?translate(status()):status();},1000);
let activeSeconds=0;
setInterval(()=>{if(!sessionEnded&&!document.hidden&&!suspended()){activeSeconds++;if(activeSeconds>=60){activeSeconds=0;state.minutes++;state.sitting++;state.longest=Math.max(state.longest,state.sitting);if(state.sitting>=50&&!state.pending.includes(0)){state.pending.push(0);state.counts[0]++;}if(state.minutes%60===0&&!state.pending.includes(1)){state.pending.push(1);state.counts[1]++;}if(state.minutes%20===0&&!state.pending.includes(2)){state.pending.push(2);state.counts[2]++;}persist();if(current!=='micro')render();}}},1000);
render();
})();
