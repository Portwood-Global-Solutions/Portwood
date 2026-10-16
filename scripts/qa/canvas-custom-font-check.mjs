// Real Canvas model: pinned revisions, exact styles and every table band survive save/reopen.
import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {JSDOM} from 'jsdom';
const dom = new JSDOM('<!doctype html>');
Object.assign(globalThis,{document:dom.window.document,window:dom.window,Node:dom.window.Node});
writeFileSync('/tmp/portwood-canvas-font-model.mjs',readFileSync('force-app/main/default/lwc/docGenCanvas/canvasModel.js','utf8'));
const m=await import('/tmp/portwood-canvas-font-model.mjs?'+Date.now());
const key='a'.repeat(64), style={font:"'Barlow'",fontFaceKey:key,fontWeight:700,fontStyle:'normal',bold:false,italic:false};
const doc=m.blankDocument(), box=m.newTextBox(.2,.3,5,.8);box.html='<p>Şahin ş Company {Name}</p>';box.style={...box.style,...style};
const table=m.newTableBox(.2,2,6);table.table.relationship='Contacts';table.table.subRelationship='Cases';table.table.subColumns=[{label:'Sub',tag:'{Subject}'}];table.table.totals={enabled:true,cells:['Total']};
for(const band of ['headerText','rowText','subText','totalsText'])table.table[band]={...table.table[band],...style};
doc.artboards[0].boxes.push(box,table);
const html=m.serialize(doc,m.pageGeometry('Letter','Portrait'));
assert.equal((html.match(/-pw-font-face:/g)||[]).length,8);
assert.ok(!html.includes('PW_'+key),'Browser alias never saved');
assert.ok(html.includes('font-weight:700')||html.includes('font-weight: 700'));
const parsed=m.deserialize(html);
assert.equal(parsed.artboards[0].boxes[0].style.fontFaceKey,key);
const savedTable=parsed.artboards[0].boxes.find(b=>b.kind==='table');
for(const band of ['headerText','rowText','subText','totalsText'])assert.equal(savedTable.table[band].fontFaceKey,key,band);
assert.ok(!m.symbolMarkup({unicode:true,value:'Ş'},true).includes('Arial Unicode'));
assert.ok(m.symbolMarkup({unicode:true,value:'✓'}).includes('Arial Unicode'));
console.log('PASS custom font bindings: text, four table bands, save/reopen, exact weight and inherited symbols');

assert.equal(m.applyFontFaceToInline('<p style="color:red;font-family:Arial;font-weight:bold;font-size:12px"><strong>Şahin</strong></p>'),'<p style="color:red;font-size:12px"><span>Şahin</span></p>');
