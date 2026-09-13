'use strict';
// QA 同类隐患扫描器 (Edward) — 只读，不改源码
const fs = require('fs');
const path = require('path');

const ROOT = 'C:/Users/24658/Desktop/DouPin';
const SRC = path.join(ROOT, 'Sources');

function walk(dir, out) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.name.endsWith('.swift')) out.push(p);
  }
  return out;
}

const files = walk(SRC, []);
const results = { files: [], fillStroke: [], ctxMembers: [], overflow: [], optionalBind: [], imports: [] };

// 收集所有自定义函数名 + 是否返回 Optional（粗判：函数体里 return nil / -> X? ）
const funcReturnOptional = {}; // name -> true/false/unknown

const fileTexts = {};
for (const f of files) {
  const t = fs.readFileSync(f, 'utf8');
  fileTexts[f] = t;
  results.files.push(path.relative(ROOT, f).replace(/\\/g, '/'));
}

// 1) .fill( / .stroke( 调用 —— 抓接收者
const callRe = /([A-Za-z0-9_\.\]\)\?\!\"\']+)\s*\.\s*(fill|stroke)\s*\(/g;
// 2) ctx. 成员（排除 ctx.cgContext）
const ctxRe = /\bctx\s*\.\s*([A-Za-z0-9_]+)/g;
// 3) overflow API
const overflowNames = ['addReportingOverflow','addingReportingOverflow','subtractingReportingOverflow','multipliedReportingOverflow','dividedReportingOverflow'];
// 4) if let / guard let 右侧
const bindRe = /\b(if|guard)\s+let\s+[A-Za-z0-9_]+\s*=\s*([^,{\n]+)/g;
// 5) import
const importRe = /^\s*import\s+([A-Za-z0-9_]+)/gm;

function rel(p){ return path.relative(ROOT, p).replace(/\\/g,'/'); }

for (const f of files) {
  const lines = fileTexts[f].split(/\r?\n/);
  lines.forEach((line, i) => {
    const ln = i + 1;
    let m;
    const r1 = new RegExp(callRe.source, 'g');
    while ((m = r1.exec(line)) !== null) {
      results.fillStroke.push({ file: rel(f), line: ln, recv: m[1], call: m[2], text: line.trim() });
    }
    const r2 = new RegExp(ctxRe.source, 'g');
    while ((m = r2.exec(line)) !== null) {
      results.ctxMembers.push({ file: rel(f), line: ln, member: m[1], text: line.trim() });
    }
    for (const name of overflowNames) {
      if (line.includes(name)) results.overflow.push({ file: rel(f), line: ln, name, text: line.trim() });
    }
    const r4 = new RegExp(bindRe.source, 'g');
    while ((m = r4.exec(line)) !== null) {
      results.optionalBind.push({ file: rel(f), line: ln, kw: m[1], expr: m[2].trim(), text: line.trim() });
    }
    const r5 = new RegExp(importRe.source, 'gm');
    while ((m = r5.exec(line)) !== null) {
      results.imports.push({ file: rel(f), line: ln, module: m[1] });
    }
  });
}

// 判定 .fill/.stroke 接收者是否安全
function safeRecv(recv) {
  // 安全：cgContext / CGContext 结尾；cg / ctx.cgContext；GraphicsContext (canvas/gc/graphicsContext)
  if (/cgContext/.test(recv)) return true;
  if (/^(cg|ctx\.cgContext|c)$/.test(recv)) return true;
  if (/GraphicsContext|canvas|gc\b|graphicsContext/i.test(recv)) return true;
  return false;
}

fs.writeFileSync(path.join(ROOT,'qa','scan.json'), JSON.stringify(results, null, 1));
console.log('FILES', results.files.length);
console.log('FILLSTROKE', results.fillStroke.length, 'SUSPECT', results.fillStroke.filter(x=>!safeRecv(x.recv)).length);
console.log('CTX', results.ctxMembers.length);
console.log('OVERFLOW', results.overflow.length);
console.log('BIND', results.optionalBind.length);
console.log('IMPORTS', results.imports.length);
