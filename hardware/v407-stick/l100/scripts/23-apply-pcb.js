// Apply scripts/pcb_plan.json to PCB1: wipe own copper/outline, place parts, outline, tracks, vias, test-pad discs, pours.
// Everything is created from the plan; nothing is edited by hand. Units: mil, y up.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const tab=await eda.dmt_EditorControl.openDocument(a.pcbUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const plan=a.plan,out={steps:[]},K=1/0.0254;
const ids=async api=>await api.getAllPrimitiveId();
if(a.wipe){const w={};
  for(const [n,api] of [["pour",eda.pcb_PrimitivePour],["fill",eda.pcb_PrimitiveFill],["line",eda.pcb_PrimitiveLine],["via",eda.pcb_PrimitiveVia],["polyline",eda.pcb_PrimitivePolyline],["string",eda.pcb_PrimitiveString]]){
    const l=await ids(api);w[n]=l.length;if(l.length)await api.delete(l);}
  out.wiped=w;}
if(a.place){const cs=await eda.pcb_PrimitiveComponent.getAll();const by={};for(const c of cs)by[c.getState_Designator()]=c;
  const bad=[];
  for(const q of plan.parts){const c=by[q.ref];if(!c)throw new Error("Missing part "+q.ref);const id=c.getState_PrimitiveId();
    await eda.pcb_PrimitiveComponent.modify(id,{rotation:q.rot});await eda.pcb_PrimitiveComponent.modify(id,{x:q.x,y:q.y,layer:1});
    const r=await eda.pcb_PrimitiveComponent.get(id);
    if(Math.abs(r.getState_X()-q.x)>0.01||Math.abs(r.getState_Y()-q.y)>0.01||((r.getState_Rotation()%360)+360)%360!==q.rot)bad.push([q.ref,r.getState_X(),r.getState_Y(),r.getState_Rotation()]);}
  if(Object.keys(by).length!==plan.parts.length)throw new Error("Part count differs");
  out.placed=plan.parts.length;out.placeBad=bad;if(bad.length)throw new Error("Placement readback mismatch "+JSON.stringify(bad));
  // pad readback against the offline model
  const miss=[];for(const q of plan.parts){const pads=await eda.pcb_PrimitiveComponent.getAllPinsByPrimitiveId(by[q.ref].getState_PrimitiveId());
    for(const e of q.pads){if(!pads.some(z=>z.padNumber===e.n&&Math.abs(z.x-e.x)<0.2&&Math.abs(z.y-e.y)<0.2&&z.net===e.net))miss.push(q.ref+"."+e.n);}}
  out.padMiss=miss;if(miss.length)throw new Error("Pad model mismatch "+JSON.stringify(miss.slice(0,20)));}
if(a.outline){const o=plan.outline;const poly=eda.pcb_MathPolygon.createPolygon(o.src);if(!poly)throw new Error("Bad outline");
  const pl=await eda.pcb_PrimitivePolyline.create("",EPCB_LayerId.BOARD_OUTLINE,poly,10,false);if(!pl)throw new Error("Outline failed");
  out.outlineBBox=await eda.pcb_Primitive.getPrimitivesBBox([pl.getState_PrimitiveId()]);}
if(a.copper){let n=0;
  for(const t of plan.tracks){for(let i=0;i+1<t.pts.length;i++){const l=await eda.pcb_PrimitiveLine.create(t.net,t.layer,t.pts[i][0],t.pts[i][1],t.pts[i+1][0],t.pts[i+1][1],t.w,false);if(!l)throw new Error("Track failed "+JSON.stringify(t));n++;}}
  out.segments=n;n=0;
  for(const v of plan.vias){const q=await eda.pcb_PrimitiveVia.create(v.net,v.x,v.y,v.drill,v.dia);if(!q)throw new Error("Via failed "+JSON.stringify(v));n++;}
  out.vias=n;n=0;
  for(const f of plan.fills){const c=eda.pcb_MathPolygon.createPolygon(["CIRCLE",f.x,f.y,f.dia/2]);
    const cu=await eda.pcb_PrimitiveFill.create(f.layer,c,f.net,0,0.2,false);const mask=await eda.pcb_PrimitiveFill.create(f.layer===1?5:6,eda.pcb_MathPolygon.createPolygon(["CIRCLE",f.x,f.y,f.dia/2+2]),"",0,0.2,false);
    if(!cu||!mask)throw new Error("Disc failed "+JSON.stringify(f));n++;}
  out.discs=n;}
if(a.pour){out.pours=[];for(const q of plan.pours){const poly=eda.pcb_MathPolygon.createPolygon(q.src);
  const pour=await eda.pcb_PrimitivePour.create(q.net,q.layer,poly,"solid",false,q.name,q.priority,8,false);if(!pour)throw new Error("Pour failed "+q.name);
  let rebuilt=null;try{rebuilt=!!(await pour.rebuildCopperRegion());}catch(e){rebuilt=String(e);}out.pours.push([q.name,pour.getState_PrimitiveId(),rebuilt]);}}
if(a.silk){let hid=0;for(const q of await eda.pcb_PrimitiveAttribute.getAll()){if(q.getState_Key()==="Designator"&&q.getState_ValueVisible()){await eda.pcb_PrimitiveAttribute.modify(q.getState_PrimitiveId(),{valueVisible:false});hid++;}}
  out.designatorsHidden=hid;out.texts=[];
  for(const t of plan.texts){const q=await eda.pcb_PrimitiveString.create(t.layer,t.x,t.y,t.text,"default",t.size,t.stroke,t.align,t.rot,false,0,t.mirror,false);if(!q)throw new Error("Text failed "+t.text);
    const bb=await eda.pcb_Primitive.getPrimitivesBBox([q.getState_PrimitiveId()]);out.texts.push([t.text,t.layer,Math.round(bb.minX*2.54)/100,Math.round(bb.minY*2.54)/100,Math.round(bb.maxX*2.54)/100,Math.round(bb.maxY*2.54)/100]);}}
out.counts={lines:(await ids(eda.pcb_PrimitiveLine)).length,vias:(await ids(eda.pcb_PrimitiveVia)).length,fills:(await ids(eda.pcb_PrimitiveFill)).length,pours:(await ids(eda.pcb_PrimitivePour)).length,polylines:(await ids(eda.pcb_PrimitivePolyline)).length};
out.saved=await eda.pcb_Document.save();
return out;
