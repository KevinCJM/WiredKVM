const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await new Promise(r=>setTimeout(r,1500));
const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong schematic "+JSON.stringify(doc));
const existing=await eda.sch_PrimitiveComponent.getAll();
const libraryUuid=await eda.lib_LibrariesList.getSystemLibraryUuid();
const out={tab,doc,existing:existing.map(c=>({id:c.getState_PrimitiveId(),type:c.getState_ComponentType?.(),des:c.getState_Designator?.(),name:c.getState_Name?.()})),parts:{}};
let i=0;
for(const [key,uuid] of Object.entries(a.devices)){
  const x=2000+(i%6)*600,y=-2000-Math.floor(i/6)*600;i++;
  const c=await eda.sch_PrimitiveComponent.create({libraryUuid,uuid},x,y,undefined,0,false,true,true);
  if(!c){out.parts[key]={error:"create failed"};continue;}
  const id=c.getState_PrimitiveId();
  const pins=await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id);
  out.parts[key]={id,x:c.getState_X(),y:c.getState_Y(),des:c.getState_Designator(),name:c.getState_Name?.(),sid:c.getState_SupplierId?.(),other:c.getState_OtherProperty?.(),
    pins:(pins||[]).map(q=>({n:q.pinNumber,name:q.pinName,x:q.x-x,y:q.y-y,rot:q.rotation,len:q.pinLength,nc:q.noConnected,type:q.pinType}))};
  await eda.sch_PrimitiveComponent.delete(id);
}
out.after=(await eda.sch_PrimitiveComponent.getAll()).length;
return out;
