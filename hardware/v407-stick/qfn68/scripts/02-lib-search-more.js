const out={ids:{},kw:{}};const slim=d=>({uuid:d.uuid,name:d.name,footprint:d.footprint?.name,sid:d.otherProperty?.["Supplier Part"]||d.supplierId,mpn:d.otherProperty?.["Manufacturer Part"],mfr:d.otherProperty?.["Manufacturer"],cls:d.otherProperty?.["JLCPCB Part Class"],lname:d.otherProperty?.["LCSC Part Name"],value:d.otherProperty?.["Value"],desc:d.description});
for(const id of __CLI__.args.ids){try{const r=await eda.lib_Device.searchByProperties({supplierId:id},undefined,undefined,undefined,3,1);out.ids[id]=r.map(slim);}catch(e){out.ids[id]={error:String(e)};}}
for(const k of __CLI__.args.kws){try{const r=await eda.lib_Device.search(k,undefined,undefined,undefined,12,1);out.kw[k]=r.map(slim);}catch(e){out.kw[k]={error:String(e)};}}
return out;
