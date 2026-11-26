#!/usr/bin/env python3
"""Worker contract smoke test (Node, not an iOS WebKit integration test)."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "submodules/ChatListUI/Sources/GoldgramPlugins.swift").read_text()
worker = source.split("// BEGIN GOLDGRAM_WORKER_V1\n",1)[1].split("// END GOLDGRAM_WORKER_V1",1)[0]
example = source.split('static let example = #"""\n',1)[1].split('\n"""#',1)[0]
import json
ui_sample = source.split('static let uiExample = #"""\n',1)[1].split('\n"""#',1)[0]
harness = """
const assert = require('node:assert/strict');
let result, requests=[], failModels=false;
global.self = {postMessage: raw => {const v=JSON.parse(raw);if(v.rpc!==undefined){requests.push(v);const isModels=v.args.url==="https://api.deepseek.com/models";if(v.args.progress)self.onmessage({data:{rpcProgress:v.rpc,event:{text:"partial",thinking:false,done:false}}});const response=isModels?{status:failModels?503:200,body:JSON.stringify({object:"list",data:[{id:"fresh-model",object:"model"}]})}:{status:200,body:'{"choices":[{"message":{"content":"mock answer"}}]}'};self.onmessage({data:{rpcResult:v.rpc,result:response}});}else result=v;}};
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


})().catch(e=>{console.error(e);process.exit(1)});
"""
with tempfile.TemporaryDirectory() as tmp:
    path = pathlib.Path(tmp)/"test.js"
    path.write_text(harness)
    subprocess.run(["node",str(path)],check=True)
assert "connect-src 'none'" in source
assert ".nonPersistent()" in source and "worker.terminate()" in source
assert "startAccessingSecurityScopedResource" in source
assert "current.previousCode = current.code" in source
assert "GoldgramPluginManifest.supported" in source

assert 'base.network=Object.freeze' in source
assert 'addFloatingButton' in source and 'contextActions:Object.keys(actions)' in source
assert 'sk-goldgram-managed' in source and 'credential.readKey() != nil' in source
print("Goldgram #269 scoped compatibility contracts present")


assert "GoldgramPluginLifecycle" in source and "lifecycleEnabled == true" in source
assert "UIApplication.didEnterBackgroundNotification" in source

assert 'GoldgramPluginStore.mergedFiles' in source and 'var fileData: [String: String]?' in source
assert 'input.removeValue(forKey: "mediaRows")' in source
