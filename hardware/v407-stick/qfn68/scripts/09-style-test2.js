const a=__CLI__.args;const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc");
const lib=await eda.lib_LibrariesList.getSystemLibraryUuid();const out={};
const mk=async(k,x,y,rot)=>{const c=await eda.sch_PrimitiveComponent.create({libraryUuid:lib,uuid:a.devices[k]},x,y,undefined,rot,false,true,true);const id=c.getState_PrimitiveId();return {id,pins:await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id)};};
// TP rotations
for(const [i,rot] of [0,90,180,270].entries()){const t=await mk("TP",200+i*80,700,rot);out["tp"+rot]=t.pins.map(q=>[q.x,q.y,q.rotation]);}
// T junction test: rail + drop ending mid-rail (no vertex)
await eda.sch_PrimitiveWire.create([200,600,400,600],"RAIL");
const r1=await mk("R10K",300,570,90);await eda.sch_PrimitiveWire.create([300,590,300,600]);
const r2=await mk("R10K",360,570,90);await eda.sch_PrimitiveWire.create([360,590,360,600]);
// corner flag
await eda.sch_PrimitiveWire.create([300,550,300,540,360,540,360,550]);
await eda.sch_PrimitiveComponent.createNetFlag("Ground","GND",330,540,0);
// NC
const r3=await mk("R10K",600,600,0);
try{const m=await eda.sch_PrimitivePin.modify(r3.pins[0].primitiveId,{noConnected:true});out.nc=!!m;}catch(e){out.ncErr=String(e);}
// LED rot 180, schottky
const l=await mk("LED",600,500,180);out.led=l.pins.map(q=>[q.pinNumber,q.pinName,q.x,q.y,q.rotation]);
const s=await mk("SCHOTTKY",700,500,0);const e1=await mk("ESD1",800,500,90);const xt=await mk("XTAL",900,500,0);const e2=await mk("ESD2",1000,500,0);
const file=await eda.sch_ManufactureData.getNetlistFile("schematic.net",ESYS_NetlistType.JLCEDA_PRO);const nl=JSON.parse(await file.text());
out.nlKeys=Object.keys(nl);out.comp0=Object.values(nl.components).map(c=>({d:c.props.Designator,pins:c.pins||c.pinInfoMap||Object.keys(c)}));
const f=await eda.sch_ManufactureData.getPngFile("t.png",{width:4096});out.png=f?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/style-test2.png",f):null;
return out;
