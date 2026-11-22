// Design-rule adjustments, each one deliberate and recorded in docs/pcb/DESIGN_NOTES.md:
//  1. SMD pad to board outline 0.30 -> 0.19 mm: the TC-002 plug land pattern puts its shell pads 0.20 mm from the edge.
//  2. Differential pairs USB1/USB2 registered; intra-pair length tolerance 0.254 -> 1.5 mm (USB 2.0 HS guidance is 3.8 mm).
const a=__CLI__.args;const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out={nameBefore:await eda.pcb_Drc.getCurrentRuleConfigurationName()};
const cur=await eda.pcb_Drc.getCurrentRuleConfiguration();const cfg=JSON.parse(JSON.stringify(cur.config));
const ss=cfg.Spacing["Safe Spacing"].copperThickness1oz;const r=ss.row.indexOf("Board Outline"),c=ss.column.indexOf("SMD Pad");
out.before={outlinePad:ss.tables["1"].content[r][c],lenTol:cfg.Physics["Differential Pair"].differentialPair.form.differentailPairLenTolerMax};
ss.tables["1"].content[r][c]=0.19;cfg.Physics["Differential Pair"].differentialPair.form.differentailPairLenTolerMax=1.5;
out.written=await eda.pcb_Drc.overwriteCurrentRuleConfiguration(cfg);
const back=(await eda.pcb_Drc.getCurrentRuleConfiguration());const s2=back.config.Spacing["Safe Spacing"].copperThickness1oz;
out.nameAfter=back.name;out.after={outlinePad:s2.tables["1"].content[r][c],lenTol:back.config.Physics["Differential Pair"].differentialPair.form.differentailPairLenTolerMax};
// any other value that changed during the write
const diff=[];const walk=(x,y,p)=>{if(x&&typeof x==="object"){for(const k of new Set([...Object.keys(x),...Object.keys(y||{})]))walk(x[k],y?.[k],p+"/"+k);}else if(x!==y&&!(typeof x==="number"&&typeof y==="number"&&Math.abs(x-y)<1e-5))diff.push([p,x,y]);};
walk(cur.config,back.config,"");out.diff=diff;
out.pairs=[];const have=(await eda.pcb_Drc.getAllDifferentialPairs())||[];
for(const [n,pn,nn] of [["USB1","USB1_DP","USB1_DM"],["USB2","USB2_DP","USB2_DM"]]){if(have.some(h=>h.name===n))continue;out.pairs.push([n,await eda.pcb_Drc.createDifferentialPair(n,pn,nn)]);}
out.allPairs=await eda.pcb_Drc.getAllDifferentialPairs();
out.saved=await eda.pcb_Document.save();
return out;
