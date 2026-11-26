#!/usr/bin/env python3
"""Worker contract smoke test (Node, not an iOS WebKit integration test)."""
import pathlib, subprocess, tempfile
root = pathlib.Path(__file__).resolve().parents[2]
source = (root / "submodules/ChatListUI/Sources/GoldgramPlugins.swift").read_text()
worker = source.split("// BEGIN GOLDGRAM_WORKER_V1\n",1)[1].split("// END GOLDGRAM_WORKER_V1",1)[0]
example = source.split('static let example = #"""\n',1)[1].split('\n"""#',1)[0]
import json
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
