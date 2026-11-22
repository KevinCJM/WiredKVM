// Read-only: is a modal dialog open in the editor window? (No clicks, no edits.)
const out={hasDocument:typeof document!=="undefined",hasWindow:typeof window!=="undefined"};
try{const d=(typeof document!=="undefined"?document:null)||(typeof window!=="undefined"&&window.parent?window.parent.document:null);
  if(d){const sel='[class*="modal"],[class*="dialog"],[role="dialog"],[class*="Modal"],[class*="Dialog"],[class*="popup"],[class*="message-box"]';
    out.dialogs=[...d.querySelectorAll(sel)].filter(e=>e.offsetParent!==null).slice(0,12).map(e=>({cls:String(e.className).slice(0,80),text:(e.innerText||"").replace(/\s+/g," ").slice(0,300)}));out.title=d.title;}}catch(e){out.err=String(e);}
try{out.top=typeof top!=="undefined"&&top!==self?"framed":"top";out.topDoc=!!(top&&top.document);
  if(top&&top.document&&top!==self){const d=top.document;const sel='[class*="modal"],[class*="dialog"],[role="dialog"],[class*="Modal"],[class*="Dialog"],[class*="message-box"]';
    out.topDialogs=[...d.querySelectorAll(sel)].filter(e=>e.offsetParent!==null).slice(0,12).map(e=>({cls:String(e.className).slice(0,80),text:(e.innerText||"").replace(/\s+/g," ").slice(0,300)}));}}catch(e){out.topErr=String(e);}
return out;
