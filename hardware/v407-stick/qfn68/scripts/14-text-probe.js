const a=__CLI__.args;const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
let doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc");
const all=await eda.sch_PrimitiveText.getAll();const out={before:all.map(t=>[t.getState_PrimitiveId(),t.getState_Content().slice(0,24)])};
const victims=all.filter(t=>/^[\x00-\x7F]+$/.test(t.getState_Content()));out.victims=victims.length;
out.ret=[];for(const t of victims.slice(0,a.n||1)){out.ret.push([t.getState_PrimitiveId(),await eda.sch_PrimitiveText.delete(t.getState_PrimitiveId())]);}
out.mid=(await eda.sch_PrimitiveText.getAllPrimitiveId()).length;
out.saved=await eda.sch_Document.save();
await eda.dmt_EditorControl.closeDocument(doc.tabId);await new Promise(r=>setTimeout(r,800));
const t2=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await eda.dmt_EditorControl.activateDocument(t2);await new Promise(r=>setTimeout(r,2500));
out.after=(await eda.sch_PrimitiveText.getAll()).map(t=>[t.getState_PrimitiveId(),t.getState_Content().slice(0,24)]);
return out;
