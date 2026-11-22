// Probe symbol pin geometry of library devices on a temporary schematic page, then delete that page.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const pages=await eda.dmt_Schematic.getAllSchematicPagesInfo();const before=pages.map(x=>[x.uuid,x.name]);
const tmp=await eda.dmt_Schematic.createSchematicPage(pages[0].parentSchematicUuid);if(!tmp)throw new Error("temp page failed");await new Promise(r=>setTimeout(r,1500));
const out={before,tmp,parts:{}};
try{
  const tab=await eda.dmt_EditorControl.openDocument(tmp);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
  const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==tmp)throw new Error("Wrong page");
  const libraryUuid=a.libraryUuid||await eda.lib_LibrariesList.getSystemLibraryUuid();let i=0;
  for(const [key,uuid] of Object.entries(a.devices)){const x=200+(i++)*200,y=400;
    const c=await eda.sch_PrimitiveComponent.create({libraryUuid,uuid},x,y,undefined,0,false,true,true);if(!c){out.parts[key]={error:"create failed"};continue;}
    const id=c.getState_PrimitiveId();const pins=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id);
    out.parts[key]={id,x:c.getState_X(),y:c.getState_Y(),des:c.getState_Designator(),name:c.getState_Name?.(),sid:c.getState_SupplierId?.(),other:c.getState_OtherProperty?.(),
      pins:(pins||[]).map(q=>({n:q.pinNumber,name:q.pinName,x:q.x-x,y:q.y-y,rot:q.rotation,len:q.pinLength,nc:q.noConnected,type:q.pinType}))};}
  try{await eda.dmt_EditorControl.closeDocument(doc.tabId);}catch(e){}
}finally{await new Promise(r=>setTimeout(r,800));out.deleted=await eda.dmt_Schematic.deleteSchematicPage(tmp);}
out.after=(await eda.dmt_Schematic.getAllSchematicPagesInfo()).map(x=>[x.uuid,x.name]);
return out;
