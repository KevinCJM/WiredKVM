const cs=await eda.sch_PrimitiveComponent.getAll();const out=[];
for(const c of cs){const o={};for(const k of Object.getOwnPropertyNames(Object.getPrototypeOf(c))){if(k.startsWith("getState_")){try{o[k.slice(9)]=c[k]();}catch(e){}}}out.push(o);}
return {out,classes:Object.keys(eda).filter(k=>k.startsWith("sch_"))};
