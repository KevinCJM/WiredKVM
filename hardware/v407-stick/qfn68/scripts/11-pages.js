const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
let pages=await eda.dmt_Schematic.getAllSchematicPagesInfo();const out={before:pages.map(x=>[x.uuid,x.name])};
if(pages.length===1){out.created=await eda.dmt_Schematic.createSchematicPage(pages[0].parentSchematicUuid);await new Promise(r=>setTimeout(r,1500));}
pages=await eda.dmt_Schematic.getAllSchematicPagesInfo();
out.rename=[];const names=["MCU","USB_Power"];
for(const [i,pg] of pages.entries()){if(names[i]&&pg.name!==names[i])out.rename.push(await eda.dmt_Schematic.modifySchematicPageName(pg.uuid,names[i]));}
out.schName=await eda.dmt_Schematic.modifySchematicName(pages[0].parentSchematicUuid,"WiredKVM-V407-Stick");
out.after=(await eda.dmt_Schematic.getAllSchematicPagesInfo()).map(x=>[x.uuid,x.name]);
return out;
