// Repair notes whose multibyte characters were mangled in transit (U+FFFD); sch_PrimitiveText.modify persists, delete does not.
const a=__CLI__.args;const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc");
const out={fixed:[]};
for(const t of await eda.sch_PrimitiveText.getAll()){const c=t.getState_Content();const want=a.texts.find(w=>w.x===t.getState_X()&&w.y===t.getState_Y());
  if(!want)throw new Error("Unplanned text "+c);
  if(c!==want.s){await eda.sch_PrimitiveText.modify(t.getState_PrimitiveId(),{content:want.s});out.fixed.push([c,want.s]);}}
out.saved=await eda.sch_Document.save();
out.bad=(await eda.sch_PrimitiveText.getAll()).map(t=>t.getState_Content()).filter(c=>c.includes("�")||!a.texts.some(w=>w.s===c));
return out;
