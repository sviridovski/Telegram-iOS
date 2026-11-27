#!/usr/bin/env python3
"""Worker contract smoke test (Node, not an iOS WebKit integration test)."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "submodules/ChatListUI/Sources/GoldgramPlugins.swift").read_text()
worker = source.split("// BEGIN GOLDGRAM_WORKER_V1\n",1)[1].split("// END GOLDGRAM_WORKER_V1",1)[0]
example = source.split('static let example = #"""\n',1)[1].split('\n"""#',1)[0]
import json
ui_sample = source.split('static let uiExample = #"""\n',1)[1].split('\n"""#',1)[0]
gold_sample = source.split('static let goldExample = #"""\n',1)[1].split('\n"""#',1)[0]
speech_sample = source.split('static let speechExample = #"""\n',1)[1].split('\n"""#',1)[0]
personal_sample = source.split('static let personalExample = #"""\n',1)[1].split('\n"""#',1)[0]
searchdoc_sample = source.split('static let searchDocumentsExample = #"""\n',1)[1].split('\n"""#',1)[0]
update_sample = source.split('static let updateExampleV1 = #"""\n',1)[1].split('\n"""#',1)[0]
harness = """
const assert = require('node:assert/strict');
let result, requests=[], failModels=false, personalChoice="favorites";
global.self = {postMessage: raw => {const v=JSON.parse(raw);if(v.rpc!==undefined){requests.push(v);const isModels=v.args.url==="https://api.deepseek.com/models";if(v.args.progress)self.onmessage({data:{rpcProgress:v.rpc,event:{text:"partial",thinking:false,done:false}}});const response=v.method==="gold.search.history"?{value:{items:[{id:"1",text:"synthetic test",timestamp:123}],scope:"currentPeerHistory",complete:false,serverCompleted:true,truncated:false}}:v.method==="gold.documents.pickText"?{value:{name:"test.docx",format:"docx",text:"Hello world",bytes:100,pageCount:0,truncated:false}}:v.method==="ui.select"?{value:v.args.title==="Личные данные"?personalChoice:"0"}:v.method==="gold.favorites.search"?{value:{items:[{title:"Test chat",folder:"Test",note:"synthetic",tags:[]}],matched:1,scope:"currentPeer",complete:true}}:v.method==="gold.favorites.selected"?{value:{title:"Test chat",folder:"Test"}}:v.method==="gold.favorites.addSelected"?{status:"saved"}:v.method==="gold.favorites.removeSelected"?{status:"removed"}:v.method==="gold.contacts.current"||v.method==="gold.contacts.selected"?{value:{name:"Test user",username:"test",card:{alias:"Test alias",note:"Test note"}}}:v.method==="gold.speech.voices"?{voices:[{id:"mock-ru",name:"Mock",language:"ru-RU"}]}:v.method==="gold.speech.speak"?{status:"ended",started:true}:v.method==="gold.speech.stop"?{stopped:false}:isModels?{status:failModels?503:200,body:JSON.stringify({object:"list",data:[{id:"fresh-model",object:"model"}]})}:{status:200,body:'{"choices":[{"message":{"content":"mock answer"}}]}'};self.onmessage({data:{rpcResult:v.rpc,result:response}});}else result=v;}};
""" + worker + """
goldWorkerMain();
const sample = """ + json.dumps(example) + """;
const grants = ['settings.read','events','ui.read'];
(async ()=>{
await self.onmessage({data:{source:sample,grants,event:'plugin.start'}});
assert.equal(result.settings.name,'Goldgram'); assert.equal(result.sections[0].items.length,6);
await self.onmessage({data:{source:sample,grants,event:'settings.action',key:'test',settings:{name:'Test',enabled:true}}});
assert.equal(result.logs.at(-1),'Привет, Test!');
await self.onmessage({data:{source:sample,grants:[],event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.settings.setPlugin("apiKey","dummy")',grants,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.chat.sendText("test")',grants,event:'plugin.start'}});
assert.ok(result.error);
console.log('Goldgram #267 local worker: schema, persisted settings, button callback, denied APIs OK');
const compat = ['settings.read','events','ui.read','ui.mutate','chat.read','chat.write','messages.read','storage','network.fetch'];
const script = 'GGAPI.settings.addSection({title:"AI",items:[{type:"text",key:"apiKey",title:"Key",default:""},{type:"text",key:"prompt",title:"Prompt",default:"custom"}]});GGAPI.ui.addFloatingButton({id:"ai",title:"AI"},async()=>{const r=await GGAPI.network.fetch("https://api.deepseek.com/chat/completions",{method:"POST",body:JSON.stringify({prompt:GGAPI.settings.getPlugin("prompt"),draft:GGAPI.chat.draftText()})});GGAPI.chat.setDraftText((await r.json()).choices[0].message.content)});GGAPI.ui.addMessageContextAction({id:"reply",title:"Reply"},()=>{});';
await self.onmessage({data:{source:script,grants:compat,event:'plugin.start',managedKey:true}});
assert.equal(result.sections[0].items[0].type,'secret');assert.equal(result.settings.apiKey,undefined);assert.equal(result.floating.id,'ai');assert.equal(result.contextActions.length,1);
await self.onmessage({data:{source:script,grants:compat,event:'floating.tap',managedKey:true,context:{draft:'hello',peerId:'p'},settings:{prompt:'changed'}}});
assert.equal(result.output.text,'mock answer');assert.equal(JSON.parse(requests.at(-1).args.body).prompt,'changed');
assert.equal(JSON.parse(requests.at(-1).args.body).draft,'hello');
console.log('Goldgram #269 plugin-owned registration, secret schema, async callback and custom prompt OK');
const multi = label => 'function hit(){const n=Number(GGAPI.storage.get("count")||0)+1; GGAPI.storage.set("count",n); GGAPI.ui.showSheet({title:"'+label+'",text:String(n)});} GGAPI.ui.addFloatingButton({id:"shared",title:"'+label+'"},hit); GGAPI.ui.addMessageContextAction({id:"shared",title:"'+label+'"},hit);';
const run = async (label,event,storage,key) => { await self.onmessage({data:{source:multi(label),grants:compat,event,storage,key,context:{draft:"",peerId:"p",selectedMessage:{text:"test"}}}}); assert.ok(!result.error); return result; };
const a1=await run('A','floating.tap',{}), b1=await run('B','floating.tap',{});
assert.equal(a1.floating.id,b1.floating.id); assert.equal(a1.contextActions[0].id,b1.contextActions[0].id);
assert.equal(a1.storage.count,1); assert.equal(b1.storage.count,1); assert.equal(a1.output.title,'A'); assert.equal(b1.output.title,'B');
const a2=await run('A','context.tap',a1.storage,'shared'); assert.equal(a2.storage.count,2); assert.equal(b1.storage.count,1);
await self.onmessage({data:{source:'throw Error("test failure")',grants:compat,event:'plugin.start'}}); assert.ok(result.error);
const b2=await run('B','floating.tap',b1.storage); assert.equal(b2.storage.count,2);
console.log('Goldgram #271 equal local IDs, independent counters and failure isolation OK');
const catalogScript='GGAPI.settings.addSection({title:"Models",items:[{type:"select",key:"model",title:"Model",default:"fallback",options:[],modelSource:"deepseek"}]}); GGAPI.events.on("settings.action",async()=>{const c=await GGAPI.network.refreshModels(true); GGAPI.storage.set("model",c.models[0].id);});';
await self.onmessage({data:{source:catalogScript,grants:compat,event:'plugin.start'}});
assert.equal(result.sections[0].items[0].modelSource,'deepseek'); assert.equal(result.settings.model,'fallback');
const cached='GGAPI.events.on("settings.action",async()=>{const c=await GGAPI.network.refreshModels(); GGAPI.storage.set("model",c.models[0].id);});';
const before=requests.length;
await self.onmessage({data:{source:cached,grants:compat,event:'settings.action',modelCatalog:{models:[{id:'cached-model'}],updatedAt:100,stale:false}}});
assert.equal(result.storage.model,'cached-model'); assert.equal(requests.length,before);
await self.onmessage({data:{source:catalogScript,grants:compat,event:'settings.action',modelCatalog:{models:[{id:'cached-model'}],updatedAt:100,stale:false}}});
assert.equal(result.storage.model,'fresh-model');
assert.equal(requests.at(-1).args.url,'https://api.deepseek.com/models');
assert.equal(requests.at(-1).args.method,'GET'); assert.equal(requests.at(-1).args.body,undefined);
failModels=true;
const failure='GGAPI.events.on("settings.action",async()=>{try{await GGAPI.network.refreshModels(true)}catch(e){GGAPI.storage.set("model",GGAPI.network.models().models[0].id)}});';
await self.onmessage({data:{source:failure,grants:compat,event:'settings.action',modelCatalog:{models:[{id:'cached-model'}],updatedAt:100,stale:true}}});
assert.equal(result.storage.model,'cached-model'); failModels=false;
await self.onmessage({data:{source:catalogScript,grants:compat.filter(x=>x!=='network.fetch'),event:'plugin.start'}});
assert.equal(result.sections[0].items.length,0);
console.log('Goldgram #272 declarative model selector, cache hit and permission gating OK');
const streamScript='GGAPI.events.on("settings.action",async()=>{GGAPI.storage.set("enabled",GGAPI.runtime.features().streaming);const r=await GGAPI.network.stream("https://api.deepseek.com/chat/completions",{method:"POST",body:"{}"},e=>GGAPI.storage.set("delta",e.text));const j=await r.json();GGAPI.storage.set("answer",j.choices[0].message.content);});';
await self.onmessage({data:{source:streamScript,grants:compat,event:'settings.action',streamingEnabled:true}});
assert.equal(result.storage.enabled,true);assert.equal(result.storage.delta,'partial');assert.equal(result.storage.answer,'mock answer');
await self.onmessage({data:{source:streamScript,grants:compat,event:'settings.action',streamingEnabled:false}});
assert.equal(result.storage.enabled,false);assert.equal(result.storage.delta,undefined);assert.equal(requests.at(-1).args.progress,false);
console.log('Goldgram #274 streaming callback and feature flag OK');
const uiSample = """ + json.dumps(ui_sample) + """;
await self.onmessage({data:{source:uiSample,grants:compat,event:'plugin.start'}});
assert.ok(!result.error); assert.equal(result.sections[0].group,'Настройки');
assert.equal(result.sections[0].items[1].step,0.5);
assert.equal(result.sections[0].items[4].maxLength,500);
assert.equal(result.sections[1].items[1].fraction,0.4);
assert.equal(result.settings.summary,undefined);assert.equal(result.settings.meter,undefined);
assert.equal(result.contextActions.length,2);
await self.onmessage({data:{source:uiSample,grants:compat,event:'settings.changed',key:'level',value:7.5,settings:{level:7.5}}});
assert.equal(result.sections[1].items[0].detail,'7.5');assert.equal(result.sections[1].items[1].fraction,0.75);
await self.onmessage({data:{source:uiSample,grants:compat.filter(x=>x!=='settings.read'),event:'plugin.start'}});
assert.ok(result.error);
const reRender='GGAPI.settings.addSection({title:"Initial",items:[{type:"info",key:"initial",title:"Initial"}]}); GGAPI.events.on("settings.action",()=>{GGAPI.settings.clearSections();GGAPI.settings.addSection({title:"Updated",items:[{type:"info",key:"updated",title:"Updated"}]});});';
await self.onmessage({data:{source:reRender,grants:compat,event:'settings.action'}});
assert.equal(result.schemaCleared,true);assert.equal(result.sections.length,1);assert.equal(result.sections[0].title,'Updated');
console.log('Goldgram #275 declarative UI, dynamic card/progress and permissions OK');

const evScript='const a=GGAPI.events.on("chat.opened",()=>GGAPI.storage.set("opened",1)); GGAPI.events.on("chat.closed",()=>GGAPI.storage.set("closed",1)); const b=GGAPI.events.on("local.x",()=>GGAPI.storage.set("bad",1)); GGAPI.events.off(b); GGAPI.events.once("local.x",()=>GGAPI.storage.set("once",Number(GGAPI.storage.get("once")||0)+1)); GGAPI.events.on("settings.action",()=>{GGAPI.events.emit("local.x",{});GGAPI.events.emit("local.x",{});});';
await self.onmessage({data:{source:evScript,grants:compat,event:'plugin.start'}});
assert.deepEqual(result.lifecycleSubscriptions,['chat.opened','chat.closed']);
await self.onmessage({data:{source:evScript,grants:compat,event:'chat.opened',context:{peerId:'p',type:'user'}}});
assert.equal(result.storage.opened,1);assert.equal(result.storage.closed,undefined);assert.equal(result.output,null);
await self.onmessage({data:{source:evScript,grants:compat,event:'chat.closed'}});
assert.equal(result.storage.closed,1);
await self.onmessage({data:{source:evScript,grants:compat,event:'settings.action'}});
assert.equal(result.storage.once,1);assert.equal(result.storage.bad,undefined);
await self.onmessage({data:{source:evScript,grants:compat.filter(x=>x!=='chat.read'),event:'plugin.start'}});
assert.deepEqual(result.lifecycleSubscriptions,[]);
await self.onmessage({data:{source:'GGAPI.events.emit("chat.opened",{})',grants:compat,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.events.on("local.x",()=>GGAPI.events.emit("local.x",{}));GGAPI.events.emit("local.x",{})',grants:compat,event:'plugin.start'}});
assert.ok(result.error);
const cmd='const t=GGAPI.commands.register(["hello","bye"],p=>GGAPI.ui.showSheet({title:p.name,text:"manual"}));GGAPI.commands.register("other",()=>{});GGAPI.commands.unregister(t);GGAPI.commands.register("hello",p=>GGAPI.ui.showSheet({title:p.name,text:"manual"}));';
await self.onmessage({data:{source:cmd,grants:compat,event:'plugin.start'}});
assert.deepEqual(result.contextActions.map(x=>x.id),['cmd:other','cmd:hello']);
await self.onmessage({data:{source:cmd,grants:compat,event:'context.tap',key:'cmd:hello',context:{selectedMessage:{text:'test'}}}});
assert.equal(result.output.title,'hello');assert.equal(result.output.text,'manual');
const beforePassive=requests.length;
await self.onmessage({data:{source:'GGAPI.events.on("chat.opened",async()=>{try{await GGAPI.network.fetch("https://api.deepseek.com/models")}catch(e){GGAPI.storage.set("blocked",true)};GGAPI.ui.showSheet({title:"x",text:"x"})});',grants:compat,event:'chat.opened',context:{peerId:'p'}}});
assert.equal(result.storage.blocked,true);assert.equal(requests.length,beforePassive);assert.equal(result.output,null);
console.log('Goldgram #276 events, once/off, recursion limit, scoped commands and passive RPC denial OK');

const dataGrants=[...compat,'media.read'];
const fileWrite='GGAPI.files.writeText("note.txt","Привет 👋");GGAPI.files.writeJSON("state.json",{count:42});';
await self.onmessage({data:{source:fileWrite,grants:dataGrants,event:'plugin.start'}});
assert.equal(result.files['note.txt'],'Привет 👋');assert.equal(result.files['state.json'],'{"count":42}');
const savedFiles=result.files;
await self.onmessage({data:{source:'GGAPI.storage.set("read",GGAPI.files.readJSON("state.json").count);GGAPI.storage.set("bytes",GGAPI.files.stat("note.txt").sizeBytes);GGAPI.storage.set("list",GGAPI.files.list());GGAPI.files.remove("note.txt");',grants:dataGrants,event:'plugin.start',files:savedFiles}});
assert.equal(result.storage.read,42);assert.equal(result.storage.bytes,17);assert.deepEqual(result.storage.list,['note.txt','state.json']);assert.equal(result.files['note.txt'],undefined);
await self.onmessage({data:{source:'GGAPI.storage.set("empty",GGAPI.files.list().length);',grants:dataGrants,event:'plugin.start'}});
assert.equal(result.storage.empty,0);
await self.onmessage({data:{source:'GGAPI.files.writeText("../x","bad")',grants:dataGrants,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.files.writeText("secret.txt","bad")',grants:dataGrants,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.files.writeText("note.txt","я".repeat(33000))',grants:dataGrants,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'for(let i=0;i<17;i++)GGAPI.files.writeText("x"+i,"a")',grants:dataGrants,event:'plugin.start'}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.files.writeText("a.txt","x")',grants:grants,event:'plugin.start'}});
assert.ok(result.error);
const historyCtx={peerId:'p',messages:[{id:'a',id_num:1,text:'one'},{id:'b',id_num:2,text:'two'}],selectedMessage:{id:'c',text:'selected'},mediaRows:[{messageId:'m',kind:'photo'}]};
const histScript='GGAPI.events.on("settings.action",async()=>{const h=await GGAPI.messages.history("p",{limit:1});GGAPI.storage.set("history",h);const b=await GGAPI.messages.getHistory("p",{beforeId:2});GGAPI.storage.set("before",b.items[0].id);GGAPI.storage.set("selected",GGAPI.messages.get("c").text);GGAPI.storage.set("fetch",(await GGAPI.messages.fetch(["b","other"])).length);GGAPI.storage.set("media",GGAPI.media.info("m").kind);});';
await self.onmessage({data:{source:histScript,grants:dataGrants,event:'settings.action',context:historyCtx}});
assert.equal(result.storage.history.items[0].id,'b');assert.equal(result.storage.history.complete,false);assert.equal(result.storage.history.scope,'visibleSnapshot');assert.equal(result.storage.before,'a');assert.equal(result.storage.selected,'selected');assert.equal(result.storage.fetch,1);assert.equal(result.storage.media,'photo');
await self.onmessage({data:{source:'GGAPI.events.on("settings.action",async()=>{await GGAPI.messages.history("other")});',grants:dataGrants,event:'settings.action',context:historyCtx}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.events.on("settings.action",async()=>{await GGAPI.messages.history("p",{tag:"photo"})});',grants:dataGrants,event:'settings.action',context:historyCtx}});
assert.ok(result.error);
await self.onmessage({data:{source:'GGAPI.storage.set("hasMedia",!!GGAPI.media);GGAPI.storage.set("selected",GGAPI.messages.getSelectedMessage());',grants:compat,event:'plugin.start',context:{peerId:'p',selectedMessage:{id:'m',mediaKind:'photo'}}}});
assert.equal(result.storage.hasMedia,false);assert.equal(result.storage.selected,null);
await self.onmessage({data:{source:'GGAPI.storage.set("selected",GGAPI.media.selected());',grants:dataGrants,event:'plugin.start',context:{peerId:'p',selectedMessage:{id:'m',mediaKind:'photo'}}}});
assert.equal(result.storage.selected.kind,'photo');assert.equal(result.storage.selected.messageId,'m');
await self.onmessage({data:{source:'GGAPI.events.on("chat.opened",()=>GGAPI.storage.set("filesAvailable",!!GGAPI.files));',grants:dataGrants,event:'chat.opened',files:savedFiles,context:historyCtx}});
assert.equal(result.storage.filesAvailable,false);assert.deepEqual(result.files,{});
console.log('Goldgram #277 scoped snapshot, media permissions, persistent logical files and quotas OK');

const channelScript='GGAPI.ui.addMessageContextAction({id:"check",title:"Check"},()=>{const info=GGAPI.chat.currentChatInfo();GGAPI.storage.set("type",info.type);GGAPI.storage.set("canSend",info.canSend);GGAPI.storage.set("isChannel",info.isChannel);GGAPI.chat.setDraftText(GGAPI.messages.getSelectedMessage().text);});';
await self.onmessage({data:{source:channelScript,grants:compat,event:'context.tap',key:'check',context:{peerId:'c',type:'channel',draft:"",draftWritable:false,selectedMessage:{id:"p",text:"answer"}}}});
assert.equal(result.storage.type,'channel');assert.equal(result.storage.canSend,false);assert.equal(result.storage.isChannel,true);assert.equal(result.output.text,'answer');
await self.onmessage({data:{source:channelScript,grants:compat,event:'context.tap',key:'check',context:{peerId:'g',type:'group',draft:"",draftWritable:true,selectedMessage:{id:"p",text:"answer"}}}});
assert.equal(result.storage.type,'group');assert.equal(result.storage.canSend,true);assert.equal(result.storage.isChannel,false);assert.equal(result.output.kind,'draft');
console.log('Goldgram #278 channel context metadata and virtual draft output OK');

const captionScript='GGAPI.ui.addMessageContextAction({id:"caption",title:"Caption"},p=>{const m=GGAPI.messages.getSelectedMessage();GGAPI.storage.set("text",p.message.text);GGAPI.storage.set("same",m.text===GGAPI.messages.get(m.id).text);GGAPI.storage.set("kind",p.message.mediaKind||null);GGAPI.storage.set("hasMedia",!!GGAPI.media);GGAPI.storage.set("mediaInfo",GGAPI.media?GGAPI.media.selected():null);GGAPI.chat.setDraftText(p.message.text);});';
const captionContext={peerId:"discussion",type:"group",draft:"",draftWritable:true,selectedMessage:{id:"channel-post",text:"News caption",mediaKind:"video"}};
await self.onmessage({data:{source:captionScript,grants:compat,event:"context.tap",key:"caption",context:captionContext}});
assert.equal(result.storage.text,"News caption");assert.equal(result.storage.same,true);assert.equal(result.storage.kind,null);assert.equal(result.storage.hasMedia,false);assert.equal(result.storage.mediaInfo,null);assert.equal(result.output.kind,"draft");assert.equal(result.output.text,"News caption");
await self.onmessage({data:{source:captionScript,grants:[...compat,"media.read"],event:"context.tap",key:"caption",context:captionContext}});
assert.equal(result.storage.text,"News caption");assert.equal(result.storage.kind,"video");assert.equal(result.storage.mediaInfo.kind,"video");assert.equal(result.storage.mediaInfo.messageId,"channel-post");
const mediaOnlyScript='GGAPI.ui.addMessageContextAction({id:"caption",title:"Caption"},p=>GGAPI.storage.set("selected",p.message));';
await self.onmessage({data:{source:mediaOnlyScript,grants:compat,event:"context.tap",key:"caption",context:{selectedMessage:{id:"video",mediaKind:"video"}}}});
assert.equal(result.storage.selected,null);
await self.onmessage({data:{source:mediaOnlyScript,grants:[...compat,"media.read"].filter(x=>x!=="chat.read"),event:"context.tap",key:"caption",context:{selectedMessage:{id:"video",mediaKind:"video"}}}});
assert.equal(result.storage.selected,null);
console.log('Goldgram #280 caption text independent of media grant, metadata remains scoped');

const goldGrants=[...compat,'gold.ai','gold.documents','gold.search'];
const goldCapsScript='GGAPI.storage.set("version",GoldAPI.runtime.apiVersion());GGAPI.storage.set("caps",GoldAPI.runtime.capabilities());GGAPI.storage.set("fake",GoldAPI.runtime.has("speech.say"));';
await self.onmessage({data:{source:goldCapsScript,grants:compat,event:"settings.action"}});
assert.equal(result.storage.version,"1.3.0");assert.equal(result.storage.caps.length,20);assert.equal(result.storage.caps.every(c=>!c.available),true);assert.equal(result.storage.fake,false);
await self.onmessage({data:{source:goldCapsScript,grants:goldGrants,event:"settings.action",managedKey:true}});
assert.equal(result.storage.caps.find(c=>c.name==="ai.complete").available,true);assert.equal(result.storage.caps.find(c=>c.name==="search.messages").available,false);
await self.onmessage({data:{source:goldCapsScript,grants:goldGrants,event:"plugin.start",managedKey:true}});
assert.equal(result.storage.caps.find(c=>c.name==="ai.complete").available,false);
const gDocs='GGAPI.events.on("settings.action",()=>{GoldAPI.documents.saveText("gold.txt","Привет мир"+String.fromCharCode(10)+"Тест");GGAPI.storage.set("stats",GoldAPI.documents.analyze(GoldAPI.documents.readText("gold.txt")));});';
const expectedDoc="Привет мир"+String.fromCharCode(10)+"Тест";
await self.onmessage({data:{source:gDocs,grants:goldGrants,event:"settings.action"}});
assert.equal(result.files["gold.txt"],expectedDoc);assert.deepEqual(result.storage.stats,{characters:15,bytes:28,words:3,lines:2});
await self.onmessage({data:{source:'GGAPI.events.on("settings.action",()=>GGAPI.storage.set("text",GoldAPI.documents.readText("gold.txt")));',grants:goldGrants,event:"settings.action",files:result.files}});
assert.equal(result.storage.text,expectedDoc);
await self.onmessage({data:{source:gDocs,grants:goldGrants.filter(g=>g!=="storage"),event:"settings.action"}});
assert.ok(result.error);
await self.onmessage({data:{source:'GoldAPI.documents.analyze("x")',grants:goldGrants,event:"chat.opened"}});
assert.ok(result.error);
const gs='GGAPI.ui.addMessageContextAction({id:"find",title:"Find"},()=>GGAPI.storage.set("found",GoldAPI.search.messages("TeSt",{limit:2})));';
const searchContext={peerId:"p",messages:[{id:"1",text:"test one"},{id:"2",text:"test two"},{id:"3",text:"else"}],selectedMessage:{id:"2",text:"TEST caption",mediaKind:"photo"}};
await self.onmessage({data:{source:gs,grants:goldGrants,event:"context.tap",key:"find",context:searchContext}});
assert.equal(result.storage.found.matched,2);assert.equal(result.storage.found.complete,false);assert.equal(result.storage.found.items[0].source,"selected");assert.equal(result.storage.found.items[0].text,"TEST caption");assert.equal(result.storage.found.items[0].mediaKind,undefined);
await self.onmessage({data:{source:'GGAPI.events.on("settings.action",()=>GoldAPI.search.messages("test",{peerId:"foreign"}));',grants:goldGrants,event:"settings.action",context:searchContext}});
assert.ok(result.error);
await self.onmessage({data:{source:gs,grants:goldGrants.filter(g=>g!=="messages.read"),event:"context.tap",key:"find",context:searchContext}});
assert.ok(result.error);
const gAI='GGAPI.events.on("settings.action",async()=>{const r=await GoldAPI.ai.complete({model:"mock-model",prompt:"test",text:"synthetic",maxTokens:32},e=>GGAPI.storage.set("delta",e.text));GGAPI.storage.set("answer",r);});';
const beforeGoldAI=requests.length;
await self.onmessage({data:{source:gAI,grants:goldGrants,event:"settings.action",managedKey:true,streamingEnabled:true}});
assert.equal(result.storage.answer.text,"mock answer");assert.equal(result.storage.answer.partial,false);assert.equal(result.storage.delta,"partial");assert.equal(result.output,null);
assert.equal(requests.at(-1).method,"gold.ai.complete");assert.equal(JSON.parse(requests.at(-1).args.body).messages[1].content,"synthetic");
await self.onmessage({data:{source:gAI,grants:goldGrants.filter(g=>g!=="gold.ai"),event:"settings.action",managedKey:true}});
assert.ok(result.error);
await self.onmessage({data:{source:gAI,grants:goldGrants,event:"settings.action",managedKey:false}});
assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.ai.complete({model:"m",prompt:"p",text:"t"})',grants:goldGrants,event:"plugin.start",managedKey:true}});
assert.ok(result.error);
assert.equal(requests.length,beforeGoldAI+1);
console.log('Goldgram #281 GoldAPI scoped services and permission gates OK');

const speechGrants=[...compat,"gold.speech"];
const speechCheck='GGAPI.storage.set("available",GoldAPI.runtime.has("speech.speak"));GGAPI.storage.set("namespace",!!GoldAPI.speech);';
await self.onmessage({data:{source:speechCheck,grants:speechGrants,event:"settings.action",speechAvailable:true}});
assert.equal(result.storage.available,true);assert.equal(result.storage.namespace,true);
await self.onmessage({data:{source:speechCheck,grants:compat,event:"settings.action",speechAvailable:true}});
assert.equal(result.storage.available,false);assert.equal(result.storage.namespace,false);
await self.onmessage({data:{source:speechCheck,grants:speechGrants,event:"chat.opened",speechAvailable:true}});
assert.equal(result.storage.available,false);
await self.onmessage({data:{source:speechCheck,grants:speechGrants,event:"settings.action",speechAvailable:false}});
assert.equal(result.storage.available,false);
const speechScript='GGAPI.events.on("settings.action",async()=>{GGAPI.storage.set("voices",await GoldAPI.speech.voices("ru-RU"));GGAPI.storage.set("result",await GoldAPI.speech.speak("Привет",{language:"ru-RU",voiceId:"mock-ru",rate:1.2}));GGAPI.storage.set("stopped",await GoldAPI.speech.stop());});';
const speechBefore=requests.length;
await self.onmessage({data:{source:speechScript,grants:speechGrants,event:"settings.action",speechAvailable:true}});
assert.equal(result.storage.voices[0].id,"mock-ru");assert.equal(result.storage.result.status,"ended");assert.equal(result.storage.result.started,true);assert.equal(result.storage.stopped,false);
assert.equal(requests.length,speechBefore+3);assert.equal(requests.at(-2).method,"gold.speech.speak");assert.equal(requests.at(-2).args.text,"Привет");assert.equal(requests.at(-2).args.rate,1.2);
const beforeDenied=requests.length;
for(const source of ['return GoldAPI.speech.speak("x",{rate:2})','return GoldAPI.speech.speak("x".repeat(1201))','return GoldAPI.speech.speak("x",{language:"bad language"})','return GoldAPI.speech.speak("x",{url:"https://example.org"})','return GoldAPI.speech.speak(" ")']){
 await self.onmessage({data:{source,grants:speechGrants,event:"settings.action",speechAvailable:true}});assert.ok(result.error);
}
await self.onmessage({data:{source:'return GoldAPI.speech.speak("x")',grants:speechGrants,event:"plugin.start",speechAvailable:true}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.speech.speak("x")',grants:speechGrants,event:"chat.opened",speechAvailable:true}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.speech.speak("x")',grants:compat,event:"settings.action",speechAvailable:true}});assert.ok(result.error);
assert.equal(requests.length,beforeDenied);
console.log('Goldgram #282 speech foreground grant, options and RPC contracts OK');

const personalGrants=[...compat,"gold.favorites","gold.contacts"];
const personalFlags={personalPeerAvailable:true,personalSelectionAvailable:true,personalCurrentContactAvailable:true,personalSelectedContactAvailable:true};
const pCheck='GGAPI.storage.set("available",GoldAPI.runtime.has("favorites.addSelected"));GGAPI.storage.set("contact",GoldAPI.runtime.has("contacts.current"));';
await self.onmessage({data:{source:pCheck,grants:personalGrants,event:"context.tap",...personalFlags}});
assert.equal(result.storage.available,true);assert.equal(result.storage.contact,true);
await self.onmessage({data:{source:pCheck,grants:compat,event:"context.tap",...personalFlags}});
assert.equal(result.storage.available,false);assert.equal(result.storage.contact,false);
await self.onmessage({data:{source:pCheck,grants:personalGrants,event:"chat.opened",...personalFlags}});
assert.equal(result.storage.available,false);assert.equal(result.storage.contact,false);
await self.onmessage({data:{source:pCheck,grants:personalGrants,event:"context.tap",personalPeerAvailable:true}});
assert.equal(result.storage.available,false);assert.equal(result.storage.contact,false);
const pScript='GGAPI.ui.addMessageContextAction({id:"p",title:"Personal"},async()=>{GGAPI.storage.set("search",await GoldAPI.favorites.search("synthetic",10));GGAPI.storage.set("selected",await GoldAPI.favorites.selected());GGAPI.storage.set("added",await GoldAPI.favorites.addSelected({folder:"Test",tags:["one"],note:"synthetic"}));GGAPI.storage.set("author",await GoldAPI.contacts.selected());});';
const pBefore=requests.length;
await self.onmessage({data:{source:pScript,grants:personalGrants,event:"context.tap",key:"p",...personalFlags}});
assert.equal(result.storage.search.scope,"currentPeer");assert.equal(result.storage.selected.folder,"Test");assert.equal(result.storage.added,"saved");assert.equal(result.storage.author.card.alias,"Test alias");assert.equal(requests.length,pBefore+4);
assert.equal(requests.at(-2).method,"gold.favorites.addSelected");assert.deepEqual(requests.at(-2).args,{folder:"Test",tags:["one"],note:"synthetic"});
assert.deepEqual(requests.at(-1).args,{});
const pDenied=requests.length;
for(const source of ['return GoldAPI.favorites.addSelected({messageId:123})','return GoldAPI.favorites.addSelected({folder:"x".repeat(81)})','return GoldAPI.favorites.addSelected({tags:Array(13).fill("x")})','return GoldAPI.favorites.search("",31)','return GoldAPI.favorites.addSelected({peerId:"other"})']){
 await self.onmessage({data:{source,grants:personalGrants,event:"context.tap",...personalFlags}});assert.ok(result.error);
}
await self.onmessage({data:{source:'return GoldAPI.favorites.addSelected()',grants:personalGrants,event:"context.tap",personalPeerAvailable:true}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.favorites.removeSelected()',grants:personalGrants.filter(g=>g!=="messages.read"),event:"context.tap",...personalFlags}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.contacts.selected()',grants:personalGrants.filter(g=>g!=="gold.contacts"),event:"context.tap",...personalFlags}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.contacts.current()',grants:personalGrants,event:"plugin.start",...personalFlags}});assert.ok(result.error);
assert.equal(requests.length,pDenied);
console.log('Goldgram #283 personal scoped grant, no caller IDs, and metadata contracts OK');

const sdGrants=[...compat,"gold.search","gold.search.history","gold.documents","gold.documents.import"];
const sdFlags={historyAvailable:true,documentsAvailable:true};
const sdScript='GGAPI.events.on("settings.action",async()=>{GGAPI.storage.set("h",await GoldAPI.search.history("test",{limit:3,since:100,until:200}));GGAPI.storage.set("d",await GoldAPI.documents.pickText());});';
await self.onmessage({data:{source:sdScript,grants:sdGrants,event:"settings.action",...sdFlags}});
assert.equal(result.storage.h.scope,"currentPeerHistory");assert.equal(result.storage.h.complete,false);assert.equal(result.storage.d.text,"Hello world");assert.equal(requests.at(-2).method,"gold.search.history");assert.deepEqual(requests.at(-2).args,{query:"test",limit:3,since:100,until:200});assert.deepEqual(requests.at(-1).args,{});
const sdBefore=requests.length;
for(const source of ['return GoldAPI.search.history("x",{peerId:"other"})','return GoldAPI.search.history("x",{limit:13})','return GoldAPI.search.history("x",{since:200,until:100})','return GoldAPI.search.history(" ")','return GoldAPI.search.history("x",{since:2147483648})']){
 await self.onmessage({data:{source,grants:sdGrants,event:"settings.action",...sdFlags}});assert.ok(result.error);
}
await self.onmessage({data:{source:'return GoldAPI.search.history("x")',grants:sdGrants.filter(g=>g!=="gold.search.history"),event:"settings.action",...sdFlags}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.documents.pickText()',grants:sdGrants.filter(g=>g!=="gold.documents.import"),event:"settings.action",...sdFlags}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.documents.pickText()',grants:sdGrants,event:"chat.opened",...sdFlags}});assert.ok(result.error);
await self.onmessage({data:{source:'return GoldAPI.search.history("x")',grants:sdGrants,event:"floating.tap",historyAvailable:false}});assert.ok(result.error);
assert.equal(requests.length,sdBefore);
const sdSample=""" + json.dumps(searchdoc_sample) + """;
await self.onmessage({data:{source:sdSample,grants:sdGrants,event:"plugin.start"}});
assert.ok(!result.error);assert.equal(result.floating.title,"Find");
await self.onmessage({data:{source:sdSample,grants:sdGrants,event:"settings.action",key:"document",...sdFlags}});
assert.ok(result.output.text.includes("Hello world"));assert.ok(result.output.text.includes("Слов: 2"));
await self.onmessage({data:{source:sdSample,grants:sdGrants,event:"floating.tap",...sdFlags}});
assert.ok(result.output.text.includes("synthetic test"));
console.log('Goldgram #285 history/document scope contracts OK');


const personalSample = """ + json.dumps(personal_sample) + """;
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"plugin.start"}});
assert.ok(!result.error);assert.equal(result.floating.title,"Personal");assert.equal(result.contextActions.length,4);
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"context.tap",key:"personal-add",...personalFlags}});
assert.equal(result.output.text,"✓ Закладка сохранена");assert.equal(requests.at(-1).args.folder,"GoldAPI Test");
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"context.tap",key:"personal-remove",...personalFlags}});
assert.equal(result.output.text,"✓ Закладка удалена");
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"context.tap",key:"personal-author",...personalFlags}});
assert.ok(result.output.text.includes("Имя: Test user"));assert.ok(result.output.text.includes("Псевдоним: Test alias"));

await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"floating.tap",...personalFlags}});
assert.equal(result.output.title,"Личная закладка");assert.ok(result.output.text.includes("Папка: Test"));assert.ok(result.output.text.includes("Заметка: synthetic"));assert.ok(!result.output.text.includes('"scope"'));
personalChoice="contact";
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"floating.tap",...personalFlags}});
assert.ok(result.output.text.includes("Username: @test"));
await self.onmessage({data:{source:personalSample,grants:personalGrants,event:"context.tap",key:"personal-add",personalPeerAvailable:true}});
assert.ok(result.output.text.includes("Действие недоступно"));assert.ok(!result.output.text.includes("GoldAPI unavailable"));




const speechSample = """ + json.dumps(speech_sample) + """;
await self.onmessage({data:{source:speechSample,grants:speechGrants,event:"plugin.start"}});
assert.ok(!result.error);assert.equal(result.floating.title,"TTS");assert.equal(result.contextActions[0].id,"speak");
await self.onmessage({data:{source:speechSample,grants:speechGrants,event:"context.tap",key:"speak",context:{peerId:"p",selectedMessage:{id:"1",text:"news caption"}},speechAvailable:true}});
assert.equal(requests.at(-1).method,"gold.speech.speak");assert.equal(requests.at(-1).args.text,"news caption");
await self.onmessage({data:{source:speechSample,grants:speechGrants,event:"floating.tap",context:{peerId:"p",draft:"draft text"},speechAvailable:true}});
assert.equal(requests.at(-1).args.text,"draft text");assert.equal(result.output,null);



const builtInGold=""" + json.dumps(gold_sample) + """;
await self.onmessage({data:{source:builtInGold,grants:goldGrants,event:"plugin.start"}});
assert.ok(!result.error);assert.equal(result.floating.title,"Gold");assert.equal(result.contextActions[0].id,"gold-inspect");
await self.onmessage({data:{source:builtInGold,grants:goldGrants,event:"settings.action",key:"write"}});
assert.equal(result.files["gold-test.txt"],expectedDoc);
const builtInFiles=result.files;
await self.onmessage({data:{source:builtInGold,grants:goldGrants,event:"settings.action",key:"read",files:builtInFiles}});
assert.equal(JSON.parse(result.output.text).words,3);
await self.onmessage({data:{source:builtInGold,grants:goldGrants,event:"context.tap",key:"gold-inspect",context:searchContext}});
assert.equal(JSON.parse(result.output.text).words,2);
await self.onmessage({data:{source:builtInGold,grants:goldGrants,event:"floating.tap",context:searchContext,settings:{query:"test"}}});
assert.ok(result.output.text.includes("TEST caption"));

const updateV1 = """ + json.dumps(update_sample) + """;
const updateV2 = updateV1.replace("// @version 1.0","// @version 2.0\\n// @permission.clipboard optional").replace("Update Test 1.0","Update Test 2.0");
const updateGrants=Array.from(updateV1.matchAll(/^\\/\\/ @permission\\.([^\\s]+) required$/gm),m=>m[1]);
assert.ok(updateGrants.includes("ui.read"));
await self.onmessage({data:{source:updateV1,grants:updateGrants.filter(x=>x!=="ui.read"),event:"settings.action",key:"inspect"}});
assert.ok(result.error);
await self.onmessage({data:{source:updateV1,grants:updateGrants,event:"settings.action",key:"increment",settings:{label:"persisted"},storage:{count:5}}});
assert.ok(!result.error);assert.equal(result.storage.count,6);assert.equal(result.files["update-test.txt"],"saved");
const updateData={settings:result.settings,storage:result.storage,files:result.files};
await self.onmessage({data:{source:updateV2,grants:[...updateGrants,"clipboard"],event:"settings.action",key:"inspect",...updateData}});
assert.ok(!result.error);assert.equal(result.output.title,"Update Test 2.0");assert.equal(result.output.text,"persisted · 6 · saved");
await self.onmessage({data:{source:updateV1,grants:updateGrants,event:"settings.action",key:"inspect",...updateData}});
assert.ok(!result.error);assert.equal(result.output.title,"Update Test 1.0");assert.equal(result.output.text,"persisted · 6 · saved");
console.log("Goldgram update sample preserves settings/storage/files across version and rollback");







})().catch(e=>{console.error(e);process.exit(1)});
"""
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"test.js"
    path.write_text(harness)
    subprocess.run(["node",str(path)],check=True)
assert "connect-src 'none'" in source
assert ".nonPersistent()" in source and "worker.terminate()" in source
assert "startAccessingSecurityScopedResource" in source
assert "next.previousCode = current.code" in source
assert "GoldgramPluginManifest.supported" in source

assert 'base.network=Object.freeze' in source
assert 'addFloatingButton' in source and 'contextActions:Object.keys(actions)' in source
assert 'sk-goldgram-managed' in source and 'credential.readKey() != nil' in source
print("Goldgram #269 scoped compatibility contracts present")


assert "GoldgramPluginLifecycle" in source and "lifecycleEnabled == true" in source
assert "UIApplication.didEnterBackgroundNotification" in source

assert 'GoldgramPluginStore.mergedFiles' in source and 'var fileData: [String: String]?' in source
assert 'input.removeValue(forKey: "mediaRows")' in source

chat = (root / "submodules/TelegramUI/Sources/ChatController.swift").read_text()
ai = (root / "submodules/ChatListUI/Sources/GoldgramAI.swift").read_text()
assert 'guard canSendMessagesToChat(self.presentationInterfaceState)' in chat
assert 'goldgramPluginTimedText' in chat and 'attr.timeout != viewOnceTimeout' in chat
assert 'Сообщение с автоудалением' in chat and 'AutoclearTimeoutMessageAttribute' in chat
assert 'guard registration == nil, draft.writable' in ai and 'guard draft.writable, self.token' in ai

assert 'var allowTimedTextWithoutPrompt: Bool?' in source and 'skipTimedTextPrompt(account: String, actionKey: String)' in source
assert 'thread.channelMessageId == id || thread.effectiveMessageId == id' in chat
assert 'thread.isChannelPost, !thread.isNotAvailable' in chat
assert 'peer == message.id.peerId || self.goldgramPluginDiscussionRoot(message.id)' in chat
assert 'message.media.allSatisfy({ $0 is TelegramMediaWebpage })' in chat
assert 'GoldgramAIButtonGroup.skipTimedTextPrompt' in chat

assert '$0 is TelegramMediaImage || $0 is TelegramMediaFile' in chat
assert 'if self.goldgramPluginSelectedText(message._asMessage())' in chat
assert 'selected.removeValue(forKey: "mediaKind")' in source
assert 'actions[p.key]({message:selectedSnapshot})' in source

assert 'method == "gold.ai.complete", grants.contains("gold.ai"), grants.contains("network.fetch")' in source
assert 'new Function("GGAPI","GG","console","GoldAPI",p.source)' in source
assert 'static let goldExample' in source

assert 'import AVFoundation' in source and 'AVSpeechSynthesizer()' in source
assert 'speech?.cancel(); speech = nil' in source
assert 'Self.owner == nil' in source and 'self.valid(), UIApplication.shared.applicationState == .active' in source
assert 'method == "gold.speech.speak", grants.contains("gold.speech")' in source
assert 'guard !broker.isBusy' in source

personal = (root / "submodules/ChatListUI/Sources/GoldgramAuthorSearch.swift").read_text()
assert 'safeContext.removeValue(forKey: "_goldPersonalScope")' in source
assert 'selected.removeValue(forKey: "_goldPersonalSelection")' in source
assert 'GoldgramPersonalUI.change(context)' in personal and 'data.bookmarks.first(where: { $0.key == target.key }) == old' in personal
assert 'allowTimedReference, raw.id.peerId.namespace == Namespaces.Peer.CloudUser' in personal
assert 'attr.timeout >= 3600, attr.timeout != viewOnceTimeout' in personal
assert 'selectedExpired' in personal and '!self.selectedExpired' in personal
assert 'message.id.peerId.namespace == Namespaces.Peer.CloudUser || message.id.peerId.namespace == Namespaces.Peer.CloudGroup' in chat
assert 'personal?.cancel(); personal = nil' in source

assert 'allowTimedReference: self.goldgramPluginTimedText(message._asMessage())' in chat
assert 'legacy.previousCode = legacy.code' in source and 'legacy.code = Self.personalExample' in source

reader = (root / "submodules/ChatListUI/Sources/GoldgramPluginDocuments.swift").read_text()
assert 'safeContext.removeValue(forKey: "_goldHistoryScope")' in source
assert 'self.chatLocation.threadId == nil' in chat
assert 'GoldgramMediaEntry.eligible(m)' in personal and 'raw.autoremoveAttribute == nil' in personal
assert 'history?.cancel(); history = nil' in source and 'documents?.cancel(); documents = nil' in source
assert 'PDFDocument(data: data)' in reader and 'COMPRESSION_ZLIB' in reader
assert 'shouldResolveExternalEntities = false' in reader and 'plain <= maxXML' in reader

# Native parser smoke tests on the same macOS runner, before the Bazel build.
# Compile the actual document reader (no UIKit picker on macOS) and exercise
# stored/deflated Word XML, invalid XML, oversized entries, TXT, JSON, and PDF.
import sys, zipfile, struct
if sys.platform == "darwin":
    parser = reader.split("@MainActor\nfinal class GoldgramPluginDocumentSession", 1)[0]
    parser = parser.replace("import UIKit\n", "").replace("import UniformTypeIdentifiers\n", "")
    swift_test = r'''
func load(_ name: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name))
}
func check(_ condition: Bool, _ name: String) {
    if !condition { fatalError("Document contract failed: " + name) }
}
func denied(_ name: String) throws {
    do { _ = try GoldgramDocumentReader.docx(try load(name)); fatalError("Accepted invalid DOCX: " + name) }
    catch { }
}
for name in ["stored.docx", "deflated.docx"] {
    let data = try load(name)
    let result = try GoldgramDocumentReader.read(data, name: name, ext: "docx")
    check((result["text"] as? String) == "Hello & мир\nSecond\tline\n", name)
    check((result["truncated"] as? Bool) == false, "not truncated")
}
try denied("oversized.docx")
try denied("dtd.docx")
try denied("crc.docx")
try denied("missing.docx")
try denied("duplicate.docx")
let txt = try GoldgramDocumentReader.read(Data("hello".utf8), name:"a.txt",ext:"txt")
check((txt["text"] as? String) == "hello", "TXT")
let js = try GoldgramDocumentReader.read(Data("{\"x\":1}".utf8), name:"a.json",ext:"json")
check((js["text"] as? String) == "{\"x\":1}", "JSON")
let big = try GoldgramDocumentReader.read(Data(String(repeating:"я",count:30000).utf8),name:"big.txt",ext:"txt")
check((big["text"] as? String)?.utf8.count == 48000, "UTF-8 bound")
check((big["truncated"] as? Bool) == true, "truncation flag")
let pdf = try GoldgramDocumentReader.read(try load("sample.pdf"), name:"sample.pdf",ext:"pdf")
check((pdf["text"] as? String)?.contains("Goldgram PDF test") == true, "PDF text")
check((pdf["pageCount"] as? Int) == 1, "PDF page count")
print("Goldgram #285 native document fixtures passed")
'''
    with tempfile.TemporaryDirectory() as tmp:
        p = pathlib.Path(tmp)
        xml = b'<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello &amp; ' + "мир".encode() + b'</w:t></w:r></w:p><w:p><w:r><w:t>Second</w:t><w:tab/><w:t>line</w:t></w:r></w:p></w:body></w:document>'
        for name, compression in [("stored.docx",zipfile.ZIP_STORED),("deflated.docx",zipfile.ZIP_DEFLATED)]:
            with zipfile.ZipFile(p/name,"w",compression=compression) as z:
                z.writestr("word/document.xml",xml)
        with zipfile.ZipFile(p/"oversized.docx","w",compression=zipfile.ZIP_DEFLATED) as z:
            z.writestr("word/document.xml",b"x"*(512*1024+1))
        with zipfile.ZipFile(p/"dtd.docx","w") as z:
            z.writestr("word/document.xml",b'<!DOCTYPE x [<!ENTITY a "bad">]>'+xml)
        with zipfile.ZipFile(p/"missing.docx","w") as z:
            z.writestr("other.xml",xml)
        with zipfile.ZipFile(p/"duplicate.docx","w") as z:
            z.writestr("word/document.xml",xml)
            z.writestr("word/document.xml",xml)
        bad = bytearray((p/"stored.docx").read_bytes())
        offset = 30 + struct.unpack_from("<H",bad,26)[0] + struct.unpack_from("<H",bad,28)[0]
        bad[offset+5] ^= 1
        (p/"crc.docx").write_bytes(bad)
        content = b"BT /F1 14 Tf 72 720 Td (Goldgram PDF test) Tj ET"
        objs = [b"<< /Type /Catalog /Pages 2 0 R >>", b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
                b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                b"<< /Length "+str(len(content)).encode()+b" >>\nstream\n"+content+b"\nendstream"]
        pdf = bytearray(b"%PDF-1.4\n")
        offsets = []
        for i, obj in enumerate(objs,1):
            offsets.append(len(pdf))
            pdf += str(i).encode()+b" 0 obj\n"+obj+b"\nendobj\n"
        xref = len(pdf)
        pdf += b"xref\n0 6\n0000000000 65535 f \n"
        for offset in offsets: pdf += ("%010d 00000 n \n"%offset).encode()
        pdf += b"trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n"+str(xref).encode()+b"\n%%EOF\n"
        (p/"sample.pdf").write_bytes(pdf)
        (p/"main.swift").write_text(parser+"\n"+swift_test)
        subprocess.run(["swiftc",str(p/"main.swift"),"-o",str(p/"reader-test")],check=True,timeout=90)
        subprocess.run([str(p/"reader-test"),str(p)],check=True,timeout=30)
    subprocess.run(["swiftc","-frontend","-parse",str(root/"submodules/ChatListUI/Sources/GoldgramPluginDocuments.swift")],check=True,timeout=30)


# Compile the actual native manifest/update policy with Foundation-only record stubs.
# No UIKit, no WebKit, no device storage or Keychain access in this test.
if sys.platform == "darwin":
    manifest = source.split("private struct GoldgramPluginManifest {",1)[1].split("private struct GoldgramPluginConfirmationPolicy",1)[0]
    rules = source.split("private enum GoldgramPluginUpdate {",1)[1].split("private struct GoldgramPluginState",1)[0]
    stub = r'''
private struct GoldgramPluginRecord {
    var id = UUID(); var code: String; var previousCode: String? = nil
    var enabled = true; var grants = ["storage"]
    var settings = ["label":"test"]; var storage = ["count":"7"]; var fileData: [String:String]? = ["note.txt":"text"]
    var settingsSchema: Data? = Data(); var floatingTitle: String? = "old"; var contextActions: [[String:String]]? = []
    var confirmationPolicy: Bool? = true; var lifecycleEnabled: Bool? = true; var lifecycleSubscriptions: [String]? = ["chat.opened"]
}
'''
    checks = r'''
func check(_ condition: Bool, _ label: String) { if !condition { fatalError(label) } }
func script(_ version: String, _ name: String = "Test", _ author: String = "Owner", _ more: String = "") -> String {
    "// @name \(name)\n// @author \(author)\n// @version \(version)\n\(more)\nconst x = 1;"
}
private let old = GoldgramPluginManifest(script("1.9"))
func valid(_ next: String) -> Bool { GoldgramPluginUpdate.validate(old, GoldgramPluginManifest(next)) == nil }
check(valid(script("1.10.0")), "numeric comparison")
check(!valid(script("1.9.0")), "equal version")
check(!valid(script("1.8")), "downgrade")
check(!valid(script("2.0-beta")), "unsupported version")
check(!valid(script("2.0","Other")), "name mismatch")
check(!valid(script("2.0","Test","Other")), "author mismatch")
check(!valid(script("2.0","Test","Owner","// @requiresGoldAPI 9.0")), "future API")
check(!valid(script("2.0","Test","Owner","// @permission.unknown required")), "unsupported grant")
check(valid(script("2.0","Test","Owner","// @permission.clipboard optional\n// @requiresGoldAPI 1.3.0")), "supported addition")
private let current = GoldgramPluginRecord(code: script("1.9"))
private let next = GoldgramPluginUpdate.replacement(current,code:script("2.0"))
check(next.id == current.id && next.settings == current.settings && next.storage == current.storage && next.fileData == current.fileData, "preserved data")
check(!next.enabled && next.grants.isEmpty && next.settingsSchema == nil && next.floatingTitle == nil && next.contextActions == nil && next.confirmationPolicy == nil && next.lifecycleSubscriptions == nil && next.lifecycleEnabled == nil, "reset execution state")
check(next.previousCode == current.code, "rollback code")
private let reverted = GoldgramPluginUpdate.replacement(next,code:current.code)
check(reverted.code == current.code && reverted.previousCode == next.code && reverted.id == current.id, "rollback and redo")
print("Goldgram native plugin update policy passed (13 checks)")
'''
    with tempfile.TemporaryDirectory() as tmp:
        p = pathlib.Path(tmp)
        (p/"main.swift").write_text("import Foundation\nprivate struct GoldgramPluginManifest {"+manifest+stub+"\nprivate enum GoldgramPluginUpdate {"+rules+checks)
        subprocess.run(["swiftc",str(p/"main.swift"),"-o",str(p/"update-test")],check=True,timeout=90)
        subprocess.run([str(p/"update-test")],check=True,timeout=30)
