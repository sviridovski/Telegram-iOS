// @name Goldgram SDK AI
// @author Goldgram
// @version 1.0.0
// @requiresGoldAPI 1.3.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
// @permission.network.fetch required
// @permission.gold.ai required
GGAPI.settings.addSection({title:"SDK AI",items:[
  {type:"text",key:"apiKey",title:"DeepSeek API key"},
  {type:"text",key:"model",title:"ID модели",default:"deepseek-chat",maxLength:100},
  {type:"textarea",key:"prompt",title:"Промпт",default:"Ответь кратко",maxLength:1000},
  {type:"textarea",key:"sample",title:"Текст для отправки",default:"Объясни, что такое SDK.",maxLength:2000},
  {type:"button",key:"generate",title:"Сгенерировать ответ"}
]});
GGAPI.events.on("settings.action",async p=>{
  if(p.key!=="generate")return;
  try{
    if(!GoldAPI.runtime.has("ai.complete")){GGAPI.ui.showSheet({title:"SDK AI",text:"Нет ключа или разрешения."});return;}
    const a=await GoldAPI.ai.complete({
      model:GGAPI.settings.getPlugin("model","deepseek-chat"),
      prompt:GGAPI.settings.getPlugin("prompt","Ответь кратко"),
      text:GGAPI.settings.getPlugin("sample","Объясни, что такое SDK."),
      maxTokens:256
    });
    GGAPI.ui.showSheet({title:"SDK AI",text:(a.partial?"Частичный ответ\n":"")+a.text});
  }catch(_){GGAPI.ui.showSheet({title:"SDK AI",text:"Запрос отменён или недоступен."});}
});
