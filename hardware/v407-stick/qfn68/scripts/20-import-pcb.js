// Open PCB1, import the schematic (only if the PCB is empty), read back parts and pads.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const tab=await eda.dmt_EditorControl.openDocument(a.pcbUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,2000));
const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out={board:await eda.dmt_Board.getCurrentBoardInfo(),before:(await eda.pcb_PrimitiveComponent.getAll()).length};
if(a.doImport){if(out.before&&!a.allowPopulated)throw new Error("PCB already populated");out.imported=await eda.pcb_Document.importChanges(a.schematicUuid,true);await new Promise(r=>setTimeout(r,3000));}
const cs=await eda.pcb_PrimitiveComponent.getAll();out.parts=[];
const st=o=>{const r={};for(const k of Object.keys(o))if(typeof o[k]!=="function")r[k]=o[k];return r;};
for(const c of cs){const pads=await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(c.getState_PrimitiveId());
  const q={id:c.getState_PrimitiveId(),ref:c.getState_Designator(),x:c.getState_X(),y:c.getState_Y(),rotation:c.getState_Rotation(),layer:c.getState_Layer(),uid:c.getState_UniqueId?.(),supplierId:c.getState_SupplierId?.(),pads:pads.map(st)};
  try{q.bbox=await eda.pcb_Primitive.getPrimitivesBBox([q.id]);}catch(e){q.bboxErr=String(e);}
  if(out.parts.length===0)q.raw=st(c);out.parts.push(q);}
out.layers=(await eda.pcb_Layer.getAllLayers()).map(l=>[l.id,l.name,l.type,l.layerStatus]);
out.ruleName=await eda.pcb_Drc.getCurrentRuleConfigurationName();
out.saved=await eda.pcb_Document.save();
return out;
