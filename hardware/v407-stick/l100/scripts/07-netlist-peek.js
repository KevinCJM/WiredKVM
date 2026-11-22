const file=await eda.sch_ManufactureData.getNetlistFile("schematic.net",ESYS_NetlistType.JLCEDA_PRO);const text=file?await file.text():null;
const wires=await eda.sch_PrimitiveWire.getAll();const attrs=await eda.sch_PrimitiveAttribute.getAll();
const dump=o=>{const r={};for(const k of Object.getOwnPropertyNames(Object.getPrototypeOf(o))){if(k.startsWith("getState_")){try{r[k.slice(9)]=o[k]();}catch(e){}}}return r;};
const cs=await eda.sch_PrimitiveComponent.getAll();const rp=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(cs.find(c=>c.getState_ComponentType()==="part").getState_PrimitiveId());
return {netlist:text&&text.slice(0,3000),wires:wires.map(dump),attrs:attrs.map(dump).slice(0,6),types:cs.map(c=>c.getState_ComponentType()),pin0:rp[0],pinKeys:Object.getOwnPropertyNames(Object.getPrototypeOf(rp[0]))};
