// @name Goldgram SDK Search
// @author Goldgram
// @version 1.0.0
// @requiresGoldAPI 1.3.0
// @permission.settings.read required
// @permission.ui.read required
// @permission.ui.mutate required
// @permission.chat.read required
// @permission.messages.read required
// @permission.gold.search required
// @permission.gold.search.history optional
GGAPI.settings.addSection({title:"SDK Search",items:[
  {type:"text",key:"query",title:"Запрос",default:"тест",maxLength:100},
  {type:"toggle",key:"history",title:"Поиск на сервере (с подтверждением)",default:false}
]});
GGAPI.ui.addFloatingButton({id:"find",title:"Find SDK"},async()=>{
  try{
    const query=GGAPI.settings.getPlugin("query","тест");
    const history=GGAPI.settings.getPlugin("history",false);
    const method=history?"search.history":"search.messages";
    if(!GoldAPI.runtime.has(method)){GGAPI.ui.showSheet({title:"SDK Search",text:"Метод недоступен в этом контексте."});return;}
    const r=history?await GoldAPI.search.history(query,{limit:8}):GoldAPI.search.messages(query,{limit:8});
    GGAPI.ui.showSheet({title:"SDK Search",text:"Совпадений в выборке: "+r.items.length+"; поиск ограничен.\n"+r.items.map(x=>x.text).join("\n").slice(0,6000)});
  }catch(_){GGAPI.ui.showSheet({title:"SDK Search",text:"Поиск отменён или недоступен."});}
});
