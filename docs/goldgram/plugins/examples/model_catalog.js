// @name Goldgram Model Catalog Test
// @version 1.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
// @permission.network.fetch required
GGAPI.settings.addSection({title:"DeepSeek",items:[
  {type:"text",key:"apiKey",title:"API-ключ"},
  {type:"select",key:"model",title:"Модель из каталога",modelSource:"deepseek",default:"deepseek-flash",options:[
    {value:"deepseek-flash",title:"Flash (резерв)"},
    {value:"deepseek-v4-pro",title:"Pro (резерв)"}
  ]},
  {type:"button",key:"refresh",title:"Обновить каталог"},
  {type:"button",key:"show",title:"Показать выбранный ID"}
]});
GGAPI.events.on("settings.action",async p=>{
  if(p.key==="refresh"){
    try{
      const c=await GGAPI.network.refreshModels(true);
      GGAPI.ui.showSheet({title:"Каталог",text:c.models.map(m=>m.id).join("\n")});
    }catch(e){GGAPI.ui.showSheet({title:"Ошибка обновления",text:"Сохранённый каталог не изменён."});}
  }
  if(p.key==="show")GGAPI.ui.showSheet({title:"Выбранная модель",text:GGAPI.settings.getPlugin("model","")});
});
