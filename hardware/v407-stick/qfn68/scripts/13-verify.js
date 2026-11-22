// save -> close -> reopen every page, then fresh readback: PNG per page, netlist, ERC, NC pins.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const out={pages:[]};
for(const [i,uuid] of a.pages.entries()){
  let tab=await eda.dmt_EditorControl.openDocument(uuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1200));
  let doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==uuid)throw new Error("Wrong doc");
  const saved=await eda.sch_Document.save();
  const closed=await eda.dmt_EditorControl.closeDocument(doc.tabId);await new Promise(r=>setTimeout(r,800));
  tab=await eda.dmt_EditorControl.openDocument(uuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,2500));
  doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==uuid)throw new Error("Reopen failed");
  const cs=(await eda.sch_PrimitiveComponent.getAll());const parts=cs.filter(c=>c.getState_ComponentType()==="part");
  const nc=[];for(const c of parts){for(const pin of await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId()))if(pin.noConnected)nc.push(c.getState_Designator()+"."+pin.pinNumber);}
  out.pages.push({uuid,saved,closed,parts:parts.length,flags:cs.filter(c=>c.getState_ComponentType()==="netflag").length,wires:(await eda.sch_PrimitiveWire.getAllPrimitiveId()).length,texts:(await eda.sch_PrimitiveText.getAllPrimitiveId()).length,badText:(await eda.sch_PrimitiveText.getAll()).map(t=>t.getState_Content()).filter(c=>c.includes("\uFFFD")),nc});
}
out.pageNames=(await eda.dmt_Schematic.getAllSchematicPagesInfo()).map(x=>[x.uuid,x.name]);
const file=await eda.sch_ManufactureData.getNetlistFile("schematic.net",ESYS_NetlistType.JLCEDA_PRO);if(!file)throw new Error("No netlist");
out.netlistSaved=await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/schematic.net.json",file);
out.erc=await eda.sch_Drc.check(true,false,false);out.ercDetails=await eda.sch_Drc.check(true,false,true);
const f=await eda.sch_ManufactureData.getPngFile("sch.png",{width:4096});out.pngType=f?.type;out.pngName=f?.name;
out.png=f?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/schematic-png"+(f.type==="image/png"?".png":".zip"),f):null;
return out;
