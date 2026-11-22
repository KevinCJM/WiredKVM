const a=__CLI__.args;const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const st=o=>{const r={};for(const k of Object.keys(o))if(typeof o[k]!=="function")r[k]=o[k];return r;};
const at=await eda.pcb_PrimitiveAttribute.getAll();const keys={};for(const q of at){const s=st(q);const k=s.key+"|kv="+s.keyVisible+"|vv="+s.valueVisible+"|L"+s.layer;keys[k]=(keys[k]||0)+1;}
return {n:at.length,keys,sample:at.slice(0,2).map(st),strings:(await eda.pcb_PrimitiveString.getAll()).length,enums:{align:typeof EPCB_PrimitiveStringAlignMode!=="undefined"?EPCB_PrimitiveStringAlignMode:null}};
