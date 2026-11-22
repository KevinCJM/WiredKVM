// The project copy of the TC-002 footprint carries three BOARD_OUTLINE lines (a notch for a board that surrounds the plug).
// On this board the plug overhangs the end edge, so those lines would hang outside the outline. Remove them from the
// project-library copy only (the system library is untouched) through the official footprint source API.
const a=__CLI__.args;const p=await eda.dmt_Project.getCurrentProjectInfo();if(p?.uuid!==a.projectUuid)throw new Error("Wrong project");
const out={};
const src=await eda.lib_Footprint.getDocumentSource(a.footprintUuid,a.projectUuid);
if(!src)throw new Error("No footprint source");
out.before={length:src.length,lines:src.split("\n").length};
const keep=[],removed=[];
for(const line of src.split("\n")){if(line.includes('"type":"POLY"')&&line.includes('"polyType":"BOARD_OUTLINE"'))removed.push(line);else keep.push(line);}
out.removed=removed;
if(a.apply){if(removed.length!==3)throw new Error("Expected 3 outline lines, found "+removed.length);
  out.updated=await eda.lib_Footprint.updateDocumentSource(a.footprintUuid,a.projectUuid,keep.join("\n"));
  const after=await eda.lib_Footprint.getDocumentSource(a.footprintUuid,a.projectUuid);out.after={length:after?.length,outlineLeft:(after||"").split("\n").filter(l=>l.includes('"polyType":"BOARD_OUTLINE"')).length};}
return out;
