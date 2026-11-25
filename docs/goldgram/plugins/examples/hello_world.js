// @name Привет Goldgram
// @version 1.0.0
// @permission.settings.read required
// @permission.events required
// @permission.ui.read required
GGAPI.settings.addSection({title:"Настройки",items:[{type:"text",key:"name",title:"Имя",default:"Goldgram"},{type:"button",key:"hello",title:"Проверить"}]});
GGAPI.events.on("settings.action",p=>{if(p.key==="hello")GGAPI.toast("Привет, "+GGAPI.settings.getPlugin("name","Goldgram")+"!");});
