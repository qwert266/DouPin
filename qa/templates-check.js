'use strict';
// 模板库回归检查
const fs=require('fs');
const f='C:/Users/24658/Desktop/DouPin/Sources/Core/Templates.swift';
const txt=fs.readFileSync(f,'utf8');

// 1) charMap 键集合
const cmMatch = txt.match(/charMap\s*:\s*\[Character:\s*Int\]\s*=\s*\[([\s\S]*?)\n\s*\]/);
if(!cmMatch){ console.log('charMap NOT FOUND'); process.exit(1); }
const charKeys = new Set();
for(const m of cmMatch[1].matchAll(/"([^"])"\s*:/g)) charKeys.add(m[1]);
console.log('charMap keys:', [...charKeys].join(''), '(', charKeys.size, ')');

// 2) 所有 PatternTemplate(name:..category:..rows:[...])
const tplRe = /PatternTemplate\(\s*name:\s*"([^"]*)"\s*,\s*category:\s*"([^"]*)"\s*,\s*rows:\s*\[([\s\S]*?)\]\s*\)/g;
let m; const templates=[];
while((m=tplRe.exec(txt))!==null){
  const name=m[1], cat=m[2], body=m[3];
  const rows=[...body.matchAll(/"([^"]*)"/g)].map(x=>x[1]);
  templates.push({name,cat,rows});
}
console.log('templates:', templates.length);
console.log('categories(套装):', new Set(templates.map(t=>t.cat)).size);

// 3) 行长严格相等 违规
let lenViol=0, violList=[];
for(const t of templates){
  if(t.rows.length===0) continue;
  const w=t.rows[0].length;
  const bad=t.rows.filter(r=>r.length!==w);
  if(bad.length){ lenViol++; violList.push(`${t.name} width=${w} badrows=${bad.length} lens=${[...new Set(t.rows.map(r=>r.length))].join(',')}`); }
}
console.log('行长不等 违规模板数:', lenViol);
if(violList.length) console.log(violList.join('\n'));

// 4) 非 . 字符都在 charMap 键集合内 未知
let unknown=0; const unkList=new Set();
for(const t of templates){
  for(const r of t.rows) for(const ch of r){ if(ch!=='.' && !charKeys.has(ch)){ unknown++; unkList.add(ch); } }
}
console.log('未知字符数:', unknown, 'charSet:', [...unkList].join(''));

// 5) 重复模板名
const names=templates.map(t=>t.name);
const dup=names.filter((n,i)=>names.indexOf(n)!==i);
console.log('重复模板名:', dup.length? [...new Set(dup)].join(',') : '无');

// 6) 套装明细
const catCount={};
for(const t of templates) catCount[t.cat]=(catCount[t.cat]||0)+1;
console.log('各套装模板数:', JSON.stringify(catCount));

// 结论
const pass = templates.length===61 && new Set(templates.map(t=>t.cat)).size===10 && lenViol===0 && unknown===0 && dup.length===0;
console.log('V5 OVERALL', pass?'PASS':'FAIL');
