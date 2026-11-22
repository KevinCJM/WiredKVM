const a=__CLI__.args;const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc");
const lib=await eda.lib_LibrariesList.getSystemLibraryUuid();const out={};
const r=await eda.sch_PrimitiveComponent.create({libraryUuid:lib,uuid:a.devices.R10K},300,600,undefined,0,false,true,true);
out.r=r.getState_PrimitiveId();
// stub wires
const w1=await eda.sch_PrimitiveWire.create([280,600,240,600],"TEST_A");out.w1=w1?.getState_PrimitiveId?.();
const w2=await eda.sch_PrimitiveWire.create([320,600,360,600]);out.w2=w2?.getState_PrimitiveId?.();
try{const l=await eda.sch_PrimitiveAttribute.createNetLabel(340,600,"TEST_B");out.label=l?.getState_PrimitiveId?.();}catch(e){out.labelErr=String(e);}
// flags with rotations
for(const [i,rot] of [0,90,180,270].entries()){
  const g=await eda.sch_PrimitiveComponent.createNetFlag("Ground","GND",500+i*60,600,rot);
  const pw=await eda.sch_PrimitiveComponent.createNetFlag("Power","3V3",500+i*60,700,rot);
  const gp=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(g.getState_PrimitiveId());
  const pp=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(pw.getState_PrimitiveId());
  out["flag"+rot]={g:gp.map(q=>[q.x,q.y,q.rotation]),p:pp.map(q=>[q.x,q.y,q.rotation])};
}
for(const [i,rot] of [0,180].entries()){const np=await eda.sch_PrimitiveComponent.createNetPort("BI","PORT_"+rot,300+i*100,700,rot);const pp=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(np.getState_PrimitiveId());out["port"+rot]=pp.map(q=>[q.x,q.y,q.rotation]);}
// rotated resistor
const r2=await eda.sch_PrimitiveComponent.create({libraryUuid:lib,uuid:a.devices.R10K},300,500,undefined,90,false,true,true);
out.r2pins=(await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(r2.getState_PrimitiveId())).map(q=>[q.pinNumber,q.x,q.y,q.rotation]);
const t=await eda.sch_PrimitiveText.create(300,760,"测试文本 Test",0,null,null,null,false,false,false);out.t=t?.getState_PrimitiveId?.();
const f=await eda.sch_ManufactureData.getPngFile("t.png",{width:2400});
out.png=f?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/style-test.png",f):null;out.pngType=f?.type;out.pngName=f?.name;
out.nets=await eda.sch_Net?.getAllNetsName?.();
return out;
