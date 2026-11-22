// Export manufacturing data from the saved PCB. DRC must pass first; nothing is ordered by this script.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out={saved:await eda.pcb_Document.save()};
out.drc=await eda.pcb_Drc.check(true,false,false);if(out.drc!==true)throw new Error("DRC does not pass; no export");
const save=async(name,f)=>{if(!f||!f.size)return {name,error:"no data"};return {name,size:f.size,generatedName:f.name,type:f.type,saved:await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/"+name,f)};};
out.files=[];
const jobs={
  gerber:async()=>save("gerber.zip",await eda.pcb_ManufactureData.getGerberFile("gerber.zip")),
  bom:async()=>save("bom.csv",await eda.pcb_ManufactureData.getBomFile("bom.csv","csv")),
  bomx:async()=>save("bom.xlsx",await eda.pcb_ManufactureData.getBomFile("bom.xlsx","xlsx")),
  cpl:async()=>save("cpl.csv",await eda.pcb_ManufactureData.getPickAndPlaceFile("cpl.csv","csv",ESYS_Unit.MILLIMETER)),
  cplx:async()=>save("cpl.xlsx",await eda.pcb_ManufactureData.getPickAndPlaceFile("cpl.xlsx","xlsx",ESYS_Unit.MILLIMETER)),
  netlist:async()=>{const t=await eda.pcb_Net.getNetlist(ESYS_NetlistType.JLCEDA_PRO);return save("pcb.net.json",new Blob([t],{type:"application/json"}));},
  ipc:async()=>save("ipc-d-356a.ipc",await eda.pcb_ManufactureData.getIpcD356AFile("ipc-d-356a.ipc")),
  pdf:async()=>save("pcb.pdf",await eda.pcb_ManufactureData.getPdfFile("pcb.pdf")),
  step:async()=>save("board.step",await eda.pcb_ManufactureData.get3DFile("board.step","step",["Component Model","Via","Wire In Signal Layer"],"Outfit",true)),
};
for(const k of a.jobs){try{out.files.push(await jobs[k]());}catch(e){out.files.push({name:k,error:String(e)});}}
return out;
