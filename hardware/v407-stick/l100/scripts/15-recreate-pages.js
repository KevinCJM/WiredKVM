// Host 4.1.78 does not persist sch_PrimitiveText.delete (text returns after save+reload), so stale notes can only be
// removed by replacing the page. Creates fresh pages, deletes the old generated ones, restores the names.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const old=await eda.dmt_Schematic.getAllSchematicPagesInfo();if(old.length!==2||old[0].name!=="MCU"||old[1].name!=="USB_Power")throw new Error("Unexpected pages "+JSON.stringify(old.map(x=>x.name)));
const out={old:old.map(x=>[x.uuid,x.name]),created:[],deleted:[]};
for(let i=0;i<2;i++){out.created.push(await eda.dmt_Schematic.createSchematicPage(old[0].parentSchematicUuid));await new Promise(r=>setTimeout(r,1200));}
if(out.created.some(x=>!x))throw new Error("create failed");
for(const pg of old){try{await eda.dmt_EditorControl.closeDocument(pg.uuid+"@"+a.projectUuid);}catch(e){}out.deleted.push(await eda.dmt_Schematic.deleteSchematicPage(pg.uuid));await new Promise(r=>setTimeout(r,800));}
out.rename=[await eda.dmt_Schematic.modifySchematicPageName(out.created[0],"MCU"),await eda.dmt_Schematic.modifySchematicPageName(out.created[1],"USB_Power")];
out.after=(await eda.dmt_Schematic.getAllSchematicPagesInfo()).map(x=>[x.uuid,x.name]);
return out;
