const a=__CLI__.args;const doc=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(doc?.uuid!==a.schPageUuid)throw new Error("Wrong doc");
const saved=await eda.sch_Document.save();
const closed=await eda.dmt_EditorControl.closeDocument(doc.tabId);await new Promise(r=>setTimeout(r,1000));
const tab=await eda.dmt_EditorControl.openDocument(a.schPageUuid);await new Promise(r=>setTimeout(r,2500));
const d2=await eda.dmt_SelectControl.getCurrentDocumentInfo();
const f=await eda.sch_ManufactureData.getPngFile("t.png",{width:4096});const png=f?await eda.sys_FileSystem.saveFileToFileSystem(a.outDir+"/"+(a.png||"reload.png"),f):null;
return {saved,closed,tab,d2,png};
