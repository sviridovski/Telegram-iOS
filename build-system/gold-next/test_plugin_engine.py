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
let result, requests=[];
global.self = {postMessage: raw => {const v=JSON.parse(raw);if(v.rpc!==undefined){requests.push(v);self.onmessage({data:{rpcResult:v.rpc,result:{status:200,body:'{"choices":[{"message":{"content":"mock answer"}}]}'}}});}else result=v;}};
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
