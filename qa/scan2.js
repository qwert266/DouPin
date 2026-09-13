'use strict';
// QA 隐患扫描 v2 — 去注释 + 更精确的接收者解析
const fs = require('fs');
const path = require('path');
const ROOT = 'C:/Users/24658/Desktop/DouPin';
const SRC = path.join(ROOT, 'Sources');

function walk(dir, out){ for(const e of fs.readdirSync(dir,{withFileTypes:true})){ const p=path.join(dir,e.name); if(e.isDirectory()) walk(p,out); else if(e.name.endsWith('.swift')) out.push(p);} return out;}
const files = walk(SRC, []);
const rel = p => path.relative(ROOT,p).replace(/\\/g,'/');

// 去注释（保留行数）：简单状态机，处理 // 与 /* */
function stripComments(text){
  const lines = text.split(/\r?\n/);
  let inBlock = false;
  return lines.map(line => {
    let out = '';
    for(let i=0;i<line.length;i++){
      const two = line.substr(i,2);
      if(inBlock){ if(two==='*/'){ inBlock=false; i++; } continue; }
      if(two==='//'){ break; }
      if(two==='/*'){ inBlock=true; i++; continue; }
      out += line[i];
    }
    return out;
  });
}

// 收集每个文件里“接收者变量”的定义类型： let cg = ctx.cgContext / let ctx = GraphicsContext...
// 以及 ctx 变量的来源

const findings = { fillStroke:[], ctxMembers:[], overflow:[], binds:[] };

// SwiftUI GraphicsContext 只存在于 Canvas 闭包内
for(const f of files){
  const raw = fs.readFileSync(f,'utf8');
  const lines = stripComments(raw);
  lines.forEach((line,i)=>{
    const ln=i+1;
    if(!line.trim()) return;
    // .fill( / .stroke( 只取“紧邻点号前的标识符或成员访问链”
    let m;
    const re = /([A-Za-z_$][A-Za-z0-9_$]*(?:\.[A-Za-z_$][A-Za-z0-9_$]*)*)\s*\.\s*(fill|stroke)\s*\(/g;
    while((m=re.exec(line))!==null){
      findings.fillStroke.push({file:rel(f),line:ln,recv:m[1],call:m[2],text:line.trim()});
    }
    // ctx. 成员
    const re2 = /\bctx\s*\.\s*([A-Za-z_$][A-Za-z0-9_$]*)/g;
    while((m=re2.exec(line))!==null){ findings.ctxMembers.push({file:rel(f),line:ln,member:m[1],text:line.trim()}); }
    // overflow
    for(const nm of ['addReportingOverflow','addingReportingOverflow','subtractingReportingOverflow','multipliedReportingOverflow','dividedReportingOverflow']){
      if(line.includes(nm)) findings.overflow.push({file:rel(f),line:ln,name:nm,text:line.trim()});
    }
    // if let / guard let
    const re4=/\b(if|guard)\s+let\s+([A-Za-z0-9_]+)\s*=\s*([^,{\n]+?)\s*(?:,|else|\{)/g;
    while((m=re4.exec(line))!==null){ findings.binds.push({file:rel(f),line:ln,kw:m[1],varName:m[2],expr:m[3].trim(),text:line.trim()}); }
  });
}

fs.writeFileSync(path.join(ROOT,'qa','scan2.json'), JSON.stringify(findings,null,1));
// 汇总打印可疑项
const CGOK = /^(cg|cgContext)$/;
console.log('=== FILL/STROKE receivers (unique) ===');
const recvs = {};
for(const x of findings.fillStroke) recvs[x.recv]=(recvs[x.recv]||0)+1;
for(const [r,n] of Object.entries(recvs).sort()) console.log(`  ${r}  x${n}`);
console.log('=== ctx members (unique) ===');
const cm={}; for(const x of findings.ctxMembers) cm[x.member]=(cm[x.member]||0)+1;
for(const [r,n] of Object.entries(cm).sort()) console.log(`  ${r}  x${n}`);
console.log('=== overflow usages ===');
for(const x of findings.overflow) console.log(`  ${x.file}:${x.line} [${x.name}] ${x.text}`);
console.log('=== bind count ===', findings.binds.length);
