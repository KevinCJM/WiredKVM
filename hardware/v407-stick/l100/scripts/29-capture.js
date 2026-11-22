// Canvas captures of the PCB for visual review: for each view, set visible layers, zoom to a region, save the image.
const a=__CLI__.args;const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out=[];
for(const v of a.views){
  if(v.layers)await eda.pcb_Layer.setLayerVisible(v.layers,true);else await eda.pcb_Layer.setLayerVisible();
  await new Promise(r=>setTimeout(r,600));
  const bounds=await eda.dmt_EditorControl.zoomTo(v.cx,v.cy,v.scale);await new Promise(r=>setTimeout(r,1800));
  const img=await eda.dmt_EditorControl.getCurrentRenderedAreaImage();
  out.push([v.name,bounds,img?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/"+v.name+".png",img):null]);}
await eda.pcb_Layer.setLayerVisible();
return out;
