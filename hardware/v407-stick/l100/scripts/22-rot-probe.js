// Measure the PCB rotation convention on one part, then restore it.
const a=__CLI__.args;const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const cs=await eda.pcb_PrimitiveComponent.getAll();const c=cs.find(c=>c.getState_Designator()===a.ref);const id=c.getState_PrimitiveId();
const snap=async()=>{const q=await eda.pcb_PrimitiveComponent.get(id);const pads=await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(id);return {x:q.getState_X(),y:q.getState_Y(),rot:q.getState_Rotation(),pads:pads.map(p=>[p.padNumber,p.x,p.y,p.rotation,p.pad])};};
const out={r0:await snap()};
for(const r of [90,180,270]){await eda.pcb_PrimitiveComponent.modify(id,{rotation:r});out["r"+r]=await snap();}
await eda.pcb_PrimitiveComponent.modify(id,{rotation:0});out.back=await snap();
return out;
