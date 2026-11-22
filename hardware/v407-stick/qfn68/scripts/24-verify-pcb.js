// PCB: save -> close -> reopen -> fresh readback (parts, copper, pours), DRC, netlist, canvas image.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
let tab=await eda.dmt_EditorControl.openDocument(a.pcbUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
let d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out={};
if(a.reload){out.saved=await eda.pcb_Document.save();out.closed=await eda.dmt_EditorControl.closeDocument(d.tabId);await new Promise(r=>setTimeout(r,1500));
  tab=await eda.dmt_EditorControl.openDocument(a.pcbUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,5000));
  d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Reopen failed");}
if(a.rebuildPours){out.rebuilt=[];for(const q of await eda.pcb_PrimitivePour.getAll()){let r;try{r=!!(await q.rebuildCopperRegion());}catch(e){r=String(e);}out.rebuilt.push([q.getState_PourName(),r]);}await new Promise(r=>setTimeout(r,1500));}
const cs=await eda.pcb_PrimitiveComponent.getAll();out.parts=[];
for(const c of cs){const pads=await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId());
  out.parts.push({ref:c.getState_Designator(),x:c.getState_X(),y:c.getState_Y(),rot:c.getState_Rotation(),layer:c.getState_Layer(),pads:pads.map(q=>[q.padNumber,q.x,q.y,q.net])});}
out.lines=(await eda.pcb_PrimitiveLine.getAll()).map(q=>[q.getState_Net(),q.getState_Layer(),q.getState_StartX(),q.getState_StartY(),q.getState_EndX(),q.getState_EndY(),q.getState_LineWidth()]);
out.vias=(await eda.pcb_PrimitiveVia.getAll()).map(q=>[q.getState_Net(),q.getState_X(),q.getState_Y(),q.getState_HoleDiameter(),q.getState_Diameter()]);
out.fills=(await eda.pcb_PrimitiveFill.getAll()).map(q=>[q.getState_Net(),q.getState_Layer()]);
out.pours=(await eda.pcb_PrimitivePour.getAll()).map(q=>[q.getState_PourName(),q.getState_Net(),q.getState_Layer()]);
out.poured=(await eda.pcb_PrimitivePoured.getAll()).length;
out.polylines=(await eda.pcb_PrimitivePolyline.getAll()).map(q=>[q.getState_Layer(),q.getState_Net()]);
out.copperLayers=await eda.pcb_Layer.getTheNumberOfCopperLayers();
out.ruleName=await eda.pcb_Drc.getCurrentRuleConfigurationName();
if(a.drc){out.drc=await eda.pcb_Drc.check(true,false,false);out.drcDetails=await eda.pcb_Drc.check(true,false,true);}
if(a.netlist){const t=await eda.pcb_Net.getNetlist(ESYS_NetlistType.JLCEDA_PRO);out.netlistSaved=await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/pcb.net.json",new Blob([t],{type:"application/json"}));}
if(a.image){await eda.pcb_Document.zoomToBoardOutline();await new Promise(r=>setTimeout(r,1500));const img=await eda.dmt_EditorControl.getCurrentRenderedAreaImage();out.image=img?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/"+a.image,img):null;out.imageType=img?.type;}
if(a.reload)out.saved2=await eda.pcb_Document.save();
return out;
