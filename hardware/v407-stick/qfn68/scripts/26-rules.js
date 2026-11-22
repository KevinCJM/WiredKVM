// Read (and optionally overwrite) the PCB design-rule configuration and physical stackup.
const a=__CLI__.args;const d=await eda.dmt_SelectControl.getCurrentDocumentInfo();if(d?.uuid!==a.pcbUuid)throw new Error("Wrong PCB");
const out={name:await eda.pcb_Drc.getCurrentRuleConfigurationName()};
const cfg=await eda.pcb_Drc.getCurrentRuleConfiguration();out.cfg=cfg;
out.stackName=await eda.pcb_Layer.getCurrentPhysicalStackingConfigurationName();out.stack=await eda.pcb_Layer.getCurrentPhysicalStackingConfiguration();
out.netRules=await eda.pcb_Drc.getNetRules();out.diff=await eda.pcb_Drc.getAllDifferentialPairs();
return out;
