// @name Goldgram SDK Documents
// @author Goldgram
// @version 1.0.0
// @requiresGoldAPI 1.3.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
// @permission.gold.documents required
// @permission.gold.documents.import required
GGAPI.settings.addSection({title:"SDK Documents",items:[{type:"button",key:"pick",title:"Выбрать PDF / DOCX / TXT / JSON"}]});
GGAPI.events.on("settings.action",async p=>{
  if(p.key!=="pick")return;
  try{
    if(!GoldAPI.runtime.has("documents.pickText")){GGAPI.ui.showSheet({title:"SDK Documents",text:"Импорт недоступен."});return;}
    const d=await GoldAPI.documents.pickText();
    if(!d)return;
    const a=GoldAPI.documents.analyze(d.text);
    GGAPI.ui.showSheet({title:"SDK Documents",text:"Слов: "+a.words+"; байт: "+a.bytes+(d.truncated?"; извлечена часть":"")});
  }catch(_){GGAPI.ui.showSheet({title:"SDK Documents",text:"Документ не удалось обработать."});}
});
