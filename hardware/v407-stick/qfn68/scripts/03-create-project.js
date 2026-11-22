const before=await eda.dmt_Project.getCurrentProjectInfo();if(before)throw new Error("Expected an empty session, got "+before.friendlyName);
const name="WiredKVM-V407-Stick";
const uuid=await eda.dmt_Project.createProject(name,name,undefined,undefined,"WiredKVM CH32V407WEU6 dual USB2.0 HS bridge, USB-stick form, 2-layer single-side SMT. WIP, not for order.",undefined,EDMT_ProjectFileFormat.EPRJ3);
if(!uuid)throw new Error("Project creation returned no UUID");
const opened=await eda.dmt_Project.openProject(uuid);
await new Promise(r=>setTimeout(r,2000));
return {uuid,opened,info:await eda.dmt_Project.getProjectInfo(uuid),current:await eda.dmt_Project.getCurrentProjectInfo(),paths:await eda.sys_FileSystem.getProjectsPaths()};
