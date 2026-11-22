// Apply one generated page plan (scripts/plan.json) to an EMPTY schematic page, verify real pin coordinates before wiring, then save.
const a=__CLI__.args;const plan=a.plan;
const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc "+JSON.stringify(doc));
const existing=(await eda.sch_PrimitiveComponent.getAll()).filter(c=>c.getState_ComponentType()!=="sheet");
if(existing.length||(await eda.sch_PrimitiveWire.getAllPrimitiveId()).length)throw new Error("Page not empty");
const lib=await eda.lib_LibrariesList.getSystemLibraryUuid();const out={page:plan.name,parts:0,wires:0,labels:0,flags:0,nc:0,texts:0,mismatch:[]};
const pinIds={};
for(const q of plan.parts){
  globalThis.__wkProgress="part "+q.ref+" "+q.dev;
  const c=await eda.sch_PrimitiveComponent.create({libraryUuid:q.lib==="project"?a.projectUuid:lib,uuid:q.dev},q.x,q.y,undefined,q.rot,q.mirror,q.bom,true);
  if(!c)throw new Error("create failed "+q.ref);
  const id=c.getState_PrimitiveId();
  if(!await eda.sch_PrimitiveComponent.modify(id,{designator:q.ref}))throw new Error("designator failed "+q.ref);
  for(const pin of await eda.sch_PrimitiveComponent.getAllPinsByPrimitiveId(id))pinIds[q.ref+"."+pin.pinNumber]=pin;
  out.parts++;
}
for(const e of plan.expect){const pin=pinIds[e.ref+"."+e.n];
  if(!pin||Math.abs(pin.x-e.x)>0.01||Math.abs(pin.y-e.y)>0.01||((pin.rotation%360)+360)%360!==e.rot)out.mismatch.push({e,got:pin&&[pin.x,pin.y,pin.rotation]});}
if(out.mismatch.length||Object.keys(pinIds).length!==plan.expect.length){out.pinCount=Object.keys(pinIds).length;out.expectCount=plan.expect.length;out.mismatch=out.mismatch.slice(0,12);out.aborted=true;return out;}
globalThis.__wkProgress="wires";
for(const w of plan.wires){if(!await eda.sch_PrimitiveWire.create(w))throw new Error("wire failed "+JSON.stringify(w));out.wires++;}
for(const f of plan.flags){if(!await eda.sch_PrimitiveComponent.createNetFlag(f.kind,f.net,f.x,f.y,f.rot))throw new Error("flag failed "+JSON.stringify(f));out.flags++;}
// createNetLabel returns nothing useful on this host build; success is checked from the wires' net names afterwards.
for(const l of plan.labels){await eda.sch_PrimitiveAttribute.createNetLabel(l.x,l.y,l.net);out.labels++;}
const wn=(await eda.sch_PrimitiveWire.getAll()).map(w=>({line:w.getState_Line(),net:w.getState_Net()}));
const on=(l,w)=>{const L=Array.isArray(w.line[0])?w.line:[w.line];return L.some(s=>{for(let i=0;i+3<s.length;i+=2){const [x1,y1,x2,y2]=s.slice(i,i+4);if(l.x>=Math.min(x1,x2)&&l.x<=Math.max(x1,x2)&&l.y>=Math.min(y1,y2)&&l.y<=Math.max(y1,y2))return true;}return false;});};
out.labelMiss=plan.labels.filter(l=>!wn.some(w=>w.net===l.net&&on(l,w)));
for(const n of plan.nc){if(!await eda.sch_PrimitivePin.modify(pinIds[n].primitiveId,{noConnected:true}))throw new Error("nc failed "+n);out.nc++;}
for(const t of plan.texts){if(!await eda.sch_PrimitiveText.create(t.x,t.y,t.s,0,null,null,t.size??null,!!t.bold,false,false))throw new Error("text failed "+t.s);out.texts++;}
out.saved=await eda.sch_Document.save();
return out;
