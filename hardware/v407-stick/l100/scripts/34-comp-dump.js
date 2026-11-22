// Dump every PCB component's full state (for before/after comparisons). Read-only unless args.doImport.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const tab=await eda.dmt_EditorControl.openDocument(a.pcbUuid);await eda.dmt_EditorControl.activateDocument(tab);await new Promise(r=>setTimeout(r,1500));
const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const st=o=>{const r={};for(const k of Object.keys(o))if(typeof o[k]!=="function")r[k]=o[k];return r;};
const out={};
if(a.doImport){out.imported=await eda.pcb_Document.importChanges(a.schematicUuid,true);await new Promise(r=>setTimeout(r,3000));}
out.parts=(await eda.pcb_PrimitiveComponent.getAll()).map(st);
if(a.drc){out.drc=await eda.pcb_Drc.check(true,false,false);}
if(a.save)out.saved=await eda.pcb_Document.save();
return out;
