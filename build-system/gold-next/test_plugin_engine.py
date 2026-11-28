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
diag_sample = source.split('static let diagnosticsExample = #"""\n',1)[1].split('\n"""#',1)[0]
ai_engine_sample = source.split('static let aiEngineExample = #"""\n',1)[1].split('\n"""#',1)[0]
sdk_dir = root / "build-system/gold-next/sdk"
sdk_examples = {name: (sdk_dir / (name + ".js")).read_text(encoding="utf-8") for name in ("starter", "search", "documents", "ai")}
sdk_contract = json.loads((sdk_dir / "contract.json").read_text(encoding="utf-8"))
import re
native_permissions = re.search(r'static let supported: Set<String> = (\[[^\n]+\])', source)
assert native_permissions is not None
assert sorted(json.loads(native_permissions.group(1))) == sdk_contract["permissions"]
for name, code in sdk_examples.items():
    assert len(code.encode("utf-8")) <= 512 * 1024, name
    minimum = re.search(r"^// @requiresGoldAPI ([0-9.]+)$", code, re.M)
    assert minimum and tuple(map(int, minimum.group(1).split("."))) <= tuple(map(int, sdk_contract["goldApi"].split("."))), name
    declared = re.findall(r"^// @permission\.([^\s]+) (required|optional)$", code, re.M)
    assert declared and len({key for key, _ in declared}) == len(declared), name
    assert all(key in sdk_contract["permissions"] for key, _ in declared), name
aicc_sample = source.split('static let aiccAlpha = #"""\n',1)[1].split('\n"""#',1)[0]
workspace_sample = source.split('static let aiccWorkspace = #"""\n',1)[1].split('\n"""#',1)[0]
harness = """
const assert = require('node:assert/strict');
let result, requests=[], failModels=false, personalChoice="favorites",tileChoice="assistant",workspaceChoices=[],workspaceAnswer=null;
global.self = {postMessage: raw => {const v=JSON.parse(raw);if(v.rpc!==undefined){requests.push(v);if(v.method==="gold.ai.balance"){self.onmessage({data:{rpcResult:v.rpc,result:{value:{is_available:true,balance_infos:[{currency:"USD",total_balance:"2.50",granted_balance:"0.50",topped_up_balance:"2.00"}]}}}});return;}if(v.method==="gold.ai.usage"){self.onmessage({data:{rpcResult:v.rpc,result:{value:{requests:2,requestsWithUsage:1,totals:{total_tokens:12}}}}});return;}const isModels=v.args.url==="https://api.deepseek.com/models";if(v.args.progress)self.onmessage({data:{rpcProgress:v.rpc,event:{text:"partial",thinking:false,done:false}}});const response=v.method==="gold.search.history"?{value:{items:[{id:"1",text:"synthetic test",timestamp:123}],scope:"currentPeerHistory",complete:false,serverCompleted:true,truncated:false}}:v.method==="gold.documents.pickText"?{value:{name:"test.docx",format:"docx",text:"Hello world",bytes:100,pageCount:0,truncated:false}}:v.method==="ui.select"?{value:v.args.title==="Личные данные"?personalChoice:["tiles","results"].includes(v.args.layout)?(workspaceChoices.length?workspaceChoices.shift():tileChoice):"0"}:v.method==="gold.favorites.search"?{value:{items:[{title:"Test chat",folder:"Test",note:"synthetic",tags:[]}],matched:1,scope:"currentPeer",complete:true}}:v.method==="gold.favorites.selected"?{value:{title:"Test chat",folder:"Test"}}:v.method==="gold.favorites.addSelected"?{status:"saved"}:v.method==="gold.favorites.removeSelected"?{status:"removed"}:v.method==="gold.contacts.current"||v.method==="gold.contacts.selected"?{value:{name:"Test user",username:"test",card:{alias:"Test alias",note:"Test note"}}}:v.method==="gold.speech.voices"?{voices:[{id:"mock-ru",name:"Mock",language:"ru-RU"}]}:v.method==="gold.speech.speak"?{status:"ended",started:true}:v.method==="gold.speech.stop"?{stopped:false}:isModels?{status:failModels?503:200,body:JSON.stringify({object:"list",data:[{id:"fresh-model",object:"model"}]})}:{status:200,body:JSON.stringify({model:"mock-model",usage:{total_tokens:12,prompt_tokens:8,completion_tokens:4,completion_tokens_details:{reasoning_tokens:2}},choices:[{message:{content:workspaceAnswer??"mock answer"}}]}),durationMs:123};self.onmessage({data:{rpcResult:v.rpc,result:response}});}else result=v;}};
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
assert.equal(result.storage.version,"1.4.0");assert.equal(result.storage.caps.length,22);assert.equal(result.storage.caps.every(c=>!c.available),true);assert.equal(result.storage.fake,false);
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
const diagSample = """ + json.dumps(diag_sample) + """;
const diagGrants=Array.from(diagSample.matchAll(/^\\/\\/ @permission\\.([^\\s]+) required$/gm),m=>m[1]);
await self.onmessage({data:{source:diagSample,grants:diagGrants,event:"plugin.start"}});
assert.ok(!result.error);assert.equal(result.sections[0].items.length,4);
await self.onmessage({data:{source:diagSample,grants:diagGrants,event:"settings.action",key:"success"}});
assert.equal(result.output.text,"OK");
await self.onmessage({data:{source:diagSample,grants:diagGrants,event:"settings.action",key:"error"}});
assert.ok(result.error);assert.ok(!result.error.includes("synthetic diagnostic test"));








const sdkExamples = """ + json.dumps(sdk_examples) + """;
const sdkContract = """ + json.dumps(sdk_contract) + """;
const sdkGrants=(code,optional=false)=>Array.from(code.matchAll(/^\\/\\/ @permission\\.([^\\s]+) (required|optional)$/gm)).filter(m=>optional||m[2]==="required").map(m=>m[1]);
const sdkRun=async(name,event,extra={},optional=false)=>{
  const source=sdkExamples[name];
  await self.onmessage({data:{source,grants:sdkGrants(source,optional),event,...extra}});
  assert.ok(!result.error);
  return result;
};
await self.onmessage({data:{source:'GGAPI.ui.showSheet({title:"SDK",text:JSON.stringify({gg:GGAPI.runtime.apiVersion(),gold:GoldAPI.runtime.apiVersion(),methods:GoldAPI.runtime.capabilities().map(({name,scope,permissions})=>({name,scope,permissions})),available:GoldAPI.runtime.capabilities().filter(x=>x.available).length})})',grants:["ui.read"],event:"plugin.start"}});
const sdkInfo=JSON.parse(result.output.text);
assert.equal(sdkInfo.gg,sdkContract.ggApi);assert.equal(sdkInfo.gold,sdkContract.goldApi);
assert.deepEqual(sdkInfo.methods,sdkContract.methods);assert.equal(sdkInfo.available,0);
const sdkBefore=requests.length;
const starterStart=await sdkRun("starter","plugin.start");assert.equal(starterStart.settings.label,"Привет");
const starterAction=await sdkRun("starter","settings.action",{key:"increment",settings:{label:"SDK"},storage:{count:4}});
assert.equal(starterAction.storage.count,5);assert.equal(starterAction.output.text,"SDK · 5");
const starterAgain=await sdkRun("starter","settings.action",{key:"inspect",settings:starterAction.settings,storage:starterAction.storage});
assert.equal(starterAgain.output.text,"SDK · 5");
const searchStart=await sdkRun("search","plugin.start");assert.equal(searchStart.floating.id,"find");
const sdkContext={peerId:"synthetic",messages:[{id:"1",text:"synthetic test"},{id:"2",text:"other"}]};
const snapshot=await sdkRun("search","floating.tap",{context:sdkContext,settings:{query:"test",history:false}});
assert.ok(snapshot.output.text.includes("synthetic test"));
const deniedHistory=await sdkRun("search","floating.tap",{context:sdkContext,settings:{query:"test",history:true},historyAvailable:true});
assert.ok(deniedHistory.output.text.includes("недоступен"));assert.equal(requests.length,sdkBefore);
const history=await sdkRun("search","floating.tap",{context:sdkContext,settings:{query:"test",history:true},historyAvailable:true},true);
assert.ok(history.output.text.includes("synthetic test"));assert.equal(requests.at(-1).method,"gold.search.history");
const doc=await sdkRun("documents","settings.action",{key:"pick",documentsAvailable:true});
assert.equal(requests.at(-1).method,"gold.documents.pickText");assert.equal(doc.output.text,"Слов: 2; байт: 11");
const aiBefore=requests.length;
const aiStart=await sdkRun("ai","plugin.start",{managedKey:true});
assert.equal(aiStart.sections[0].items[0].type,"secret");assert.equal(aiStart.settings.apiKey,undefined);assert.equal(requests.length,aiBefore);
const aiDenied=await sdkRun("ai","settings.action",{key:"generate",managedKey:false});
assert.ok(aiDenied.output.text.includes("Нет ключа"));assert.equal(requests.length,aiBefore);
const aiResult=await sdkRun("ai","settings.action",{key:"generate",managedKey:true,settings:{model:"deepseek-chat",prompt:"synthetic prompt",sample:"synthetic text"}});
assert.equal(aiResult.output.text,"mock answer");assert.equal(requests.at(-1).method,"gold.ai.complete");assert.equal(JSON.parse(requests.at(-1).args.body).messages[1].content,"synthetic text");
console.log("Goldgram SDK 1.0 contract and four example plugins passed");

const aiEngine = """ + json.dumps(ai_engine_sample) + """;
const aiEngineGrants=sdkGrants(aiEngine);
const beforeEngine=requests.length;
await self.onmessage({data:{source:aiEngine,grants:aiEngineGrants,event:"plugin.start",managedKey:true}});
assert.ok(!result.error);assert.equal(requests.length,beforeEngine);
await self.onmessage({data:{source:aiEngine,grants:aiEngineGrants,event:"settings.action",key:"balance",managedKey:true}});
assert.ok(result.output.text.includes("USD 2.50"));assert.equal(requests.at(-1).method,"gold.ai.balance");assert.deepEqual(requests.at(-1).args,{});
await self.onmessage({data:{source:aiEngine,grants:aiEngineGrants,event:"settings.action",key:"usage",managedKey:false}});
assert.ok(result.output.text.includes("Последние запросы: 2"));assert.equal(requests.at(-1).method,"gold.ai.usage");
const deniedBefore=requests.length;
await self.onmessage({data:{source:aiEngine,grants:aiEngineGrants.filter(x=>x!=="gold.ai.balance"),event:"settings.action",key:"balance",managedKey:true}});
assert.equal(requests.length,deniedBefore);
await self.onmessage({data:{source:aiEngine,grants:aiEngineGrants,event:"settings.action",key:"generate",managedKey:true,settings:{thinking:true,model:"mock-model"}}});
assert.ok(result.output.text.includes("Токены: 12"));assert.ok(result.output.text.includes("123 ms"));
const engineBody=JSON.parse(requests.at(-1).args.body);
assert.equal(engineBody.thinking.type,"enabled");assert.equal(engineBody.reasoning_effort,"low");
const enhancedAI='GGAPI.events.on("settings.action",async()=>GGAPI.storage.set("enhanced",await GoldAPI.ai.complete({model:"mock-model",prompt:"p",text:"t",thinking:false,timeoutMs:12000})));';
await self.onmessage({data:{source:enhancedAI,grants:goldGrants,event:"settings.action",managedKey:true}});
assert.equal(result.storage.enhanced.usage.reasoning_tokens,2);assert.equal(result.storage.enhanced.model,"mock-model");assert.equal(result.storage.enhanced.durationMs,123);assert.equal(requests.at(-1).args.timeoutMs,12000);
const invalidBefore=requests.length;
await self.onmessage({data:{source:enhancedAI.replace("thinking:false","thinking:false,reasoningEffort:'max'"),grants:goldGrants,event:"settings.action",managedKey:true}});
assert.ok(result.error);assert.equal(requests.length,invalidBefore);
console.log("Goldgram AI Engine 1.4 contracts passed");

const aicc = """ + json.dumps(aicc_sample) + """;
const aiccGrants=sdkGrants(aicc,true);
const aiccBefore=requests.length;
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"plugin.start",managedKey:true,settings:{deepseekModel:"legacy-model",cp1On:true,cp1Name:"My profile",cp1Prompt:"Keep legacy style",asstProfile:"custom1",routeMode:"smart"}}});
assert.ok(!result.error);assert.equal(result.floating.title,"AI");assert.equal(result.sections.length,5);
assert.equal(result.settings.deepseekModel,"legacy-model");assert.equal(result.settings.cp1Prompt,"Keep legacy style");assert.equal(result.settings.asstProfile,"custom1");assert.equal(requests.length,aiccBefore);
const aiccSettings=result.settings;
const aiccCtx={peerId:"p",draft:"synthetic question",draftWritable:true,messages:[{id:"1",text:"context test"}]};
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"floating.tap",managedKey:true,settings:{...aiccSettings,aiccPanelMode:"quick",asstContext:false},context:aiccCtx}});
assert.ok(!result.error);assert.equal(result.output.kind,"draft");assert.equal(result.output.text,"mock answer");
let body=JSON.parse(requests.at(-1).args.body);assert.equal(body.model,"legacy-model");assert.equal(body.thinking.type,"enabled");assert.ok(body.messages[0].content.includes("Keep legacy style"));assert.equal(body.messages[1].content,"synthetic question");
tileChoice="rewrite";
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"floating.tap",managedKey:true,settings:aiccSettings,context:aiccCtx}});
assert.equal(requests.at(-2).method,"ui.select");assert.equal(requests.at(-2).args.layout,"tiles");assert.ok(requests.at(-2).args.choices.some(x=>x.icon==="pencil"));assert.equal(result.output.text,"mock answer");
tileChoice=null;
const cancelBefore=requests.length;
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"floating.tap",managedKey:true,settings:aiccSettings,context:aiccCtx}});
assert.equal(requests.length,cancelBefore+1);assert.equal(result.output,null);
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"floating.tap",managedKey:true,settings:aiccSettings,context:{...aiccCtx,draft:"перевод: test"}}});
assert.equal(JSON.parse(requests.at(-1).args.body).messages[1].content,"test");assert.equal(result.output.kind,"draft");
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"context.tap",key:"aicc_ctx_scam",managedKey:true,settings:aiccSettings,context:{peerId:"p",draft:"unchanged",selectedMessage:{id:"m",text:"synthetic warning"}}}});
assert.equal(result.output.kind,"sheet");assert.equal(JSON.parse(requests.at(-1).args.body).messages[1].content,"synthetic warning");
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"context.tap",key:"aicc_ctx_reply",managedKey:true,settings:{...aiccSettings,asstContext:false},context:{peerId:"c",type:"channel",draft:"",draftWritable:false,selectedMessage:{id:"m",text:"synthetic channel"}}}});
assert.equal(result.output.kind,"sheet");
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"settings.action",key:"btnBalance",managedKey:true}});
assert.equal(requests.at(-1).method,"gold.ai.balance");assert.ok(result.output.text.includes("USD 2.50"));
const noGrant=requests.length;
await self.onmessage({data:{source:aicc,grants:aiccGrants.filter(x=>x!=="gold.ai.balance"),event:"settings.action",key:"btnBalance",managedKey:true}});
assert.equal(requests.length,noGrant);assert.ok(result.output.text.includes("gold.ai.balance"));
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"settings.action",key:"btnUsage",managedKey:false}});
assert.equal(requests.at(-1).method,"gold.ai.usage");assert.ok(result.output.text.includes("Запросы: 2"));
tileChoice="boss";
await self.onmessage({data:{source:aicc,grants:aiccGrants,event:"context.tap",key:"aicc_ctx_profile",managedKey:true,context:aiccCtx}});
assert.equal(result.storage["aicc_profile_v21:p"],"boss");
assert.ok(!Object.keys(result.storage).some(k=>k.startsWith("aicc_mem_v2:")));
console.log("AICC Alpha: legacy settings, tile dispatch, cancel, typed AI, profile and permission contracts passed");

const ws = """ + json.dumps(workspace_sample) + """;
const wsGrants=sdkGrants(ws,true),wsFile="aicc-workspace-v1.json";
const wsRun=async(event,settings={},files={},extra={})=>{
 await self.onmessage({data:{source:ws,grants:wsGrants,event,settings,files,managedKey:true,...extra}});
 assert.ok(!result.error);return result;
};
const beforeWs=requests.length;
const wsStart=await wsRun("plugin.start",{cp1On:true,cp1Name:"Legacy",cp1Prompt:"Legacy prompt",asstProfile:"custom1"});
assert.equal(wsStart.sections.length,7);assert.equal(wsStart.settings.cp1Prompt,"Legacy prompt");assert.equal(requests.length,beforeWs);
assert.ok(!wsStart.files[wsFile]);
const newTool=await wsRun("settings.action",{...wsStart.settings,wsTTitle:"My tool",wsTCommand:"mytool",wsTPrompt:"Synthetic custom prompt",wsTMode:"fast",wsTOutput:"sheet",wsTSource:"input",wsTMenu:true},{},{key:"wsTSave"});
let wsData=JSON.parse(newTool.files[wsFile]);
assert.equal(wsData.tools.length,1);assert.equal(wsData.tools[0].id,"wst1");assert.equal(newTool.settings.wsTId,"wst1");
assert.ok(newTool.contextActions.some(x=>x.id==="aicc_ctx_wst1"));assert.equal(requests.length,beforeWs);
const wsSavedSettings=newTool.settings,wsSavedFiles=newTool.files;
const duplicate=await wsRun("settings.action",{...wsSavedSettings,wsTId:"",wsTTitle:"Other",wsTCommand:"перевод"},wsSavedFiles,{key:"wsTSave"});
assert.equal(duplicate.files[wsFile],wsSavedFiles[wsFile]);assert.ok(duplicate.output.text.includes("занята"));
await wsRun("floating.tap",{...wsSavedSettings,asstContext:true},wsSavedFiles,{context:{...aiccCtx,draft:"/mytool synthetic",messages:[{id:"1",text:"private extra context"}]}});
assert.equal(result.output.kind,"sheet");let wsBody=JSON.parse(requests.at(-1).args.body);
assert.equal(wsBody.messages[1].content,"synthetic");assert.ok(wsBody.messages[0].content.includes("Synthetic custom prompt"));assert.equal(wsBody.thinking.type,"disabled");
await wsRun("context.tap",wsSavedSettings,wsSavedFiles,{key:"aicc_ctx_wst1",context:{...aiccCtx,selectedMessage:{id:"1",text:"selected test"}}});
assert.equal(JSON.parse(requests.at(-1).args.body).messages[1].content,"selected test");
const edit=await wsRun("settings.action",{...wsSavedSettings,wsTTitle:"Renamed"},wsSavedFiles,{key:"wsTSave"});
assert.equal(JSON.parse(edit.files[wsFile]).tools[0].id,"wst1");assert.equal(JSON.parse(edit.files[wsFile]).tools[0].title,"Renamed");
const profile=await wsRun("settings.action",{...edit.settings,wsPTitle:"Extra profile",wsPPrompt:"Use the extra style"},edit.files,{key:"wsPSave"});
wsData=JSON.parse(profile.files[wsFile]);assert.equal(wsData.profiles[0].id,"wsp2");assert.equal(wsData.next,3);
assert.ok(profile.sections.find(x=>x.title==="Профили").items.find(x=>x.key==="asstProfile").options.some(x=>x.value==="wsp2"));
await wsRun("floating.tap",{...profile.settings,asstProfile:"wsp2",perChatProfile:false,aiccPanelMode:"quick",asstContext:false},profile.files,{context:aiccCtx});
assert.ok(JSON.parse(requests.at(-1).args.body).messages[0].content.includes("Use the extra style"));
tileChoice=null;
const cancelledDelete=await wsRun("settings.action",profile.settings,profile.files,{key:"wsTDelete"});
assert.equal(cancelledDelete.files[wsFile],profile.files[wsFile]);
tileChoice="yes";
const deleted=await wsRun("settings.action",profile.settings,profile.files,{key:"wsTDelete"});
assert.equal(JSON.parse(deleted.files[wsFile]).tools.length,0);assert.equal(JSON.parse(deleted.files[wsFile]).next,3);assert.ok(!deleted.contextActions.some(x=>x.id==="aicc_ctx_wst1"));
const corrupt=await wsRun("settings.action",{...wsSavedSettings,wsTTitle:"New"}, {[wsFile]:"not json"},{key:"wsTSave"});
assert.equal(corrupt.files[wsFile],"not json");assert.ok(corrupt.output.text.includes("не перезаписаны"));
const priorCandidates=requests.length;
workspaceAnswer=JSON.stringify(["First response","Second response","Third response"]);
workspaceChoices=["1","draft"];
await wsRun("floating.tap",{...wsSavedSettings,asstContext:false},wsSavedFiles,{context:{...aiccCtx,draft:"варианты: synthetic"}});
assert.equal(requests.length,priorCandidates+3);assert.equal(requests.at(-2).args.layout,"results");assert.equal(requests.at(-2).args.choices.length,3);assert.ok(requests.at(-2).args.choices[1].title.includes("Second response"));assert.equal(result.output.kind,"draft");assert.equal(result.output.text,"Second response");
workspaceAnswer="not JSON";
await wsRun("floating.tap",{...wsSavedSettings,asstContext:false},wsSavedFiles,{context:{...aiccCtx,draft:"варианты: synthetic"}});
assert.equal(result.output.kind,"sheet");assert.ok(result.output.title.includes("не удалось"));
workspaceAnswer=JSON.stringify(["One","Two","Three"]);workspaceChoices=[null];
await wsRun("floating.tap",{...wsSavedSettings,asstContext:false},wsSavedFiles,{context:{...aiccCtx,draft:"варианты: synthetic"}});
assert.equal(result.output,null);
workspaceAnswer=null;workspaceChoices=[];
console.log("AICC Workspace: registry, migration, custom commands, profile library and candidate cards passed");




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

# Foundation-only diagnostics fixture, identical to the local Swift smoke test.
if sys.platform == "darwin":
    diagnostics = source.split("// BEGIN GOLDGRAM_DIAGNOSTICS_V1\n", 1)[1].split("// END GOLDGRAM_DIAGNOSTICS_V1", 1)[0]
    fixture = r'''
func check(_ value: Bool, _ label: String) { precondition(value, label) }
private var run = GoldgramPluginDiagnosticRun(event: "private secret", started: Date(timeIntervalSince1970: 0), uptime: 10)
run.rpcReceived(); run.rpcFailed(); run.networkStarted()
run.networkFinished(from: 10, to: 10.25, status: 429, failed: false)
run.networkFinished(from: 10, to: 10.5, status: 999, failed: true)
private let entry = run.finish(.timeout, uptime: 11)
check(entry.event == "other" && entry.milliseconds == 1000 && entry.outcome == .timeout, "typed outcome and event whitelist")
check(entry.rpcCount == 1 && entry.rpcErrors == 1 && entry.networkAttempts == 1, "counters")
check(entry.network[0].httpStatus == 429 && entry.network[0].failed && entry.network[0].milliseconds == 250, "HTTP and elapsed")
check(entry.network[1].httpStatus == nil && entry.network[1].failed, "invalid HTTP")
check(GoldgramPluginDiagnosticRun.milliseconds(from: 2, to: 1) == 0, "negative uptime")
check(GoldgramPluginDiagnosticRun.milliseconds(from: 0, to: .infinity) == 0, "nonfinite uptime")
private var journal = GoldgramPluginDiagnosticJournal()
for _ in 0..<40 { journal.append(key: "private-account-A", entry: entry) }
check(journal.entries(key: "private-account-A").count == 32, "per plugin cap")
journal.append(key: "private-account-B", entry: entry)
check(journal.entries(key: "private-account-B").count == 1, "isolation")
private let report = journal.report(key: "private-account-A")
check(!report.contains("private secret") && !report.contains("private-account-A") && !report.contains("private-account-B"), "no untrusted text or keys")
check(report.contains("HTTP 429") && report.contains("timeout"), "report")
journal.clear(key: "private-account-A")
check(journal.entries(key: "private-account-A").isEmpty && journal.entries(key: "private-account-B").count == 1, "isolated clear")
for i in 0..<300 { journal.append(key: "key-\(i)", entry: entry) }
check(journal.entries(key: "key-0").isEmpty && journal.entries(key: "key-299").count == 1, "global cap")
for _ in 0..<20 { run.networkFinished(from: 10, to: 11, status: 200, failed: false) }
check(run.finish(.completed, uptime: 11).network.count == 8, "network cap")
print("Goldgram native diagnostics policy passed (13 checks)")
'''
    with tempfile.TemporaryDirectory() as tmp:
        p = pathlib.Path(tmp)
        (p/"main.swift").write_text("import Foundation\n"+diagnostics+fixture)
        subprocess.run(["swiftc",str(p/"main.swift"),"-o",str(p/"diagnostics-test")],check=True,timeout=90)
        subprocess.run([str(p/"diagnostics-test")],check=True,timeout=30)
    subprocess.run(["swiftc","-frontend","-parse",str(root/"submodules/ChatListUI/Sources/GoldgramPlugins.swift")],check=True,timeout=30)
assert "Self.journal.append(key: lease, entry: diagnostics.finish(outcome))" in source
assert "diagnosticNetworkCallback(callback)" in source
assert "UIActivityViewController(activityItems: [text]" in source

# AICC dashboard routing is pure Foundation; test every route and complete management coverage.
if sys.platform == "darwin":
    routing = source.split("// BEGIN GOLDGRAM_AICC_DASHBOARD_ROUTING\n",1)[1].split("// END GOLDGRAM_AICC_DASHBOARD_ROUTING",1)[0]
    fixture = r'''

let source: [[String: Any]] = [
 ["title":"Модель и сеть", "group":"Модель и сеть", "items":[["key":"apiKey"]]],
 ["title":"Профили", "group":"Профили", "items":[["key":"asstProfile"],["key":"cp1Prompt"],["key":"asstContext"],["key":"perChatProfile"]]],
 ["title":"Инструменты и команды", "items":[["key":"cmdAsst"]]],
 ["title":"Кнопка и вывод", "items":[["key":"resultMode"]]]
]
private func keys(_ page: GoldgramAICCSettingsPage) -> [String] {
 page.sections(source).flatMap { ($0["items"] as? [[String: String]] ?? []).compactMap { $0["key"] } }
}
precondition(keys(.model) == ["apiKey"])
precondition(keys(.profiles) == ["asstProfile","cp1Prompt"])
precondition(keys(.context) == ["asstContext","perChatProfile"])
precondition(keys(.tools) == ["cmdAsst"])
precondition(keys(.button) == ["resultMode"])
precondition(keys(.management).isEmpty)
precondition(GoldgramAICCSettingsPage.profiles.sections(source)[0]["group"] == nil)
precondition(GoldgramAICCSettingsPage.model.managementRows(network:true,running:false) == [8,9])
precondition(GoldgramAICCSettingsPage.model.managementRows(network:false,running:false).isEmpty)
precondition(GoldgramAICCSettingsPage.context.managementRows(network:true,running:true) == [1])
precondition(Set(GoldgramAICCSettingsPage.allCases.flatMap { $0.managementRows(network:true,running:false) }) == Set(0...12))
print("AICC dashboard routing: 11 checks passed")
'''
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp)/"main.swift"
        path.write_text("import Foundation\n"+routing+fixture)
        subprocess.run(["swift",str(path)],check=True,timeout=90)
assert 'store.record(id)?.code == GoldgramPluginManager.aiccAlpha' in source
assert 'GoldgramPluginConfirmations(store: store, onlyID: id)' in source
assert 'onlyID == nil || next.plugins[i].id == onlyID' in source
assert 'if isDashboard && indexPath.section == 0 { return dashboardCell() }' in source

assert 'GoldgramPluginManager.aiccWorkspace' in source
assert '("contextMenu", "Контекстное меню", "list.bullet")' in source
assert 'case .customTools: sectionTitle = "Свои инструменты"' in source
assert 'case .profileLibrary: sectionTitle = "Библиотека профилей"' in source
assert 'choices.count <= 3' in ai and 'detailed ? 4000 : 320' in ai
assert 'detailed: detailed' in ai


# Workspace UI 2.0 uses the existing registry and editor keys without replacing the JS.
assert "private func workspaceLibraryCell()" in source
assert "private func openWorkspaceEditor(entryID: String?)" in source
assert "if isWorkspaceLibrary && indexPath.section == 0 { return workspaceLibraryCell() }" in source
assert 'record.fileData?["aicc-workspace-v1.json"]' in source
assert "GoldgramWorkspaceLibrary.editorValues" in source
assert "if isDashboard || isWorkspaceLibrary { return [] }" in source
if sys.platform == "darwin":
    workspace_ui = source.split("// BEGIN GOLDGRAM_WORKSPACE_LIBRARY_UI\n",1)[1].split("// END GOLDGRAM_WORKSPACE_LIBRARY_UI",1)[0]
    routing = source.split("// BEGIN GOLDGRAM_AICC_DASHBOARD_ROUTING\n",1)[1].split("// END GOLDGRAM_AICC_DASHBOARD_ROUTING",1)[0]
    fixture = r'''
let valid = #"{"version":1,"next":3,"tools":[{"id":"wst1","title":"News","prompt":"Analyse","command":"news","mode":"fast","output":"sheet","source":"input","menu":true}],"profiles":[{"id":"wsp2","title":"Friend","prompt":"Friendly"}]}"#
private let library = GoldgramWorkspaceLibrary.read(valid)!
precondition(GoldgramWorkspaceLibrary.read(nil)?.tools.isEmpty == true)
precondition(GoldgramWorkspaceLibrary.read("broken") == nil)
precondition(GoldgramWorkspaceLibrary.read(valid.replacingOccurrences(of: "wst1", with: "wst3")) == nil)
precondition(GoldgramWorkspaceLibrary.read(valid.replacingOccurrences(of: "fast", with: "bad")) == nil)
precondition(library.entries(tools: true).count == 1 && library.entries(tools: false).count == 1)
private let tool = GoldgramWorkspaceLibrary.editorValues(tools: true, entry: library.tools.first)
precondition(tool["wsTId"] as? String == "wst1" && tool["wsTCommand"] as? String == "news" && tool["wsTMenu"] as? Bool == true)
private let profile = GoldgramWorkspaceLibrary.editorValues(tools: false, entry: library.profiles.first)
precondition(profile["wsPId"] as? String == "wsp2" && profile["wsPPrompt"] as? String == "Friendly" && profile["wsTId"] == nil)
private let blank = GoldgramWorkspaceLibrary.editorValues(tools: true, entry: nil)
precondition(blank["wsTId"] as? String == "" && blank["wsTMode"] as? String == "default" && blank["wsTMenu"] as? Bool == false)
let schema: [[String:Any]] = [["title":"Свои инструменты","items":[["key":"wsTInfo"],["key":"wsTNew"],["key":"wsTEdit"],["key":"wsTEditing"],["key":"wsTTitle"],["key":"wsTSave"]]],["title":"Библиотека профилей","items":[["key":"wsPInfo"],["key":"wsPTitle"],["key":"wsPSave"]]]]
private func keys(_ page: GoldgramAICCSettingsPage) -> [String] {
    page.sections(schema).flatMap { ($0["items"] as? [[String:String]] ?? []).compactMap { $0["key"] } }
}
precondition(keys(.customTools).isEmpty && keys(.profileLibrary).isEmpty)
precondition(keys(.toolEditor) == ["wsTTitle","wsTSave"] && keys(.profileEditor) == ["wsPTitle","wsPSave"])
print("Workspace UI routing and registry: 10 checks passed")
'''
    with tempfile.TemporaryDirectory() as tmp:
        path = pathlib.Path(tmp)/"main.swift"
        path.write_text("import Foundation\n"+routing+workspace_ui+fixture)
        subprocess.run(["swift",str(path)],check=True,timeout=90)
