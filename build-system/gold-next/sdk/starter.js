// @name Goldgram SDK Starter
// @author Goldgram
// @version 1.0.0
// @requiresGoldAPI 1.3.0
// @permission.settings.read required
// @permission.events required
// @permission.storage required
// @permission.ui.read required
GGAPI.settings.addSection({title:"SDK Starter",items:[
  {type:"text",key:"label",title:"Метка",default:"Привет",maxLength:100},
  {type:"button",key:"increment",title:"Увеличить счётчик"},
  {type:"button",key:"inspect",title:"Показать счётчик"}
]});
GGAPI.events.on("settings.action",p=>{
  if(p.key!=="increment"&&p.key!=="inspect")return;
  let count=Number(GGAPI.storage.get("count")||0);
  if(!Number.isSafeInteger(count)||count<0||count>=1000000)count=0;
  if(p.key==="increment"){count++;GGAPI.storage.set("count",count);}
  GGAPI.ui.showSheet({title:"SDK Starter",text:GGAPI.settings.getPlugin("label","Привет")+" · "+count});
});
