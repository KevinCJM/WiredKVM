// Remove every primitive except the sheet frame from the CURRENT schematic page (guarded by page uuid).
const a=__CLI__.args;const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc "+JSON.stringify(doc));
const n={};
const ws=await eda.sch_PrimitiveWire.getAllPrimitiveId();n.wires=ws.length;if(ws.length)await eda.sch_PrimitiveWire.delete(ws);
const cs=(await eda.sch_PrimitiveComponent.getAll()).filter(c=>c.getState_ComponentType()!=="sheet").map(c=>c.getState_PrimitiveId());n.comps=cs.length;if(cs.length)await eda.sch_PrimitiveComponent.delete(cs);
for(const k of ["sch_PrimitiveText","sch_PrimitiveRectangle"]){const ids=await eda[k].getAllPrimitiveId();n[k]=ids.length;for(const id of ids)await eda[k].delete(id);n[k+"_left"]=(await eda[k].getAllPrimitiveId()).length;}
n.left={wires:(await eda.sch_PrimitiveWire.getAllPrimitiveId()).length,comps:(await eda.sch_PrimitiveComponent.getAll()).length};
return n;
