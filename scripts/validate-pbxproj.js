#!/usr/bin/env node
/**
 * pbxproj 完整性校验（Windows 无 Xcode 时的替代防线）
 *
 * 背景：`project.pbxproj` 是手写 plist。任何手改都可能引入 Xcode 无法解析的问题，
 * 而 Windows 上无法本地编译，只能等 GitHub Actions 跑到一半才暴露。
 * 本脚本把这些检查前移到提交前。
 *
 * 校验项：
 *  1. archiveVersion / objectVersion 必须是 <string>（Xcode 16.x 硬性要求，写成 <integer> 会 abort）
 *  2. 文件引用数 F == 构建文件数 B == PBXSourcesBuildPhase.files 条目数
 *  3. 磁盘上的 .swift 文件数与 F 引用数一致，且双向无孤儿
 *  4. 每个 B 的 fileRef 指向存在的 F；每个 F 都被至少一个 B 引用
 *  5. plist 基本结构配平（<dict>/<array> 开闭标签数量一致）
 *
 * 用法：node scripts/validate-pbxproj.js
 * 退出码：0 = 通过，1 = 发现问题
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const PBX = path.join(ROOT, 'DouPin.xcodeproj', 'project.pbxproj');
const SRC = path.join(ROOT, 'Sources');

const problems = [];
const warn = (m) => problems.push(m);

if (!fs.existsSync(PBX)) {
  console.error(`✗ 找不到 ${PBX}`);
  process.exit(1);
}
const raw = fs.readFileSync(PBX, 'utf8');

// --- 1. archiveVersion / objectVersion 必须是 string ---
for (const key of ['archiveVersion', 'objectVersion']) {
  const intForm = new RegExp(`<key>${key}</key>\\s*<integer>([^<]*)</integer>`);
  const strForm = new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`);
  if (intForm.test(raw)) {
    warn(`[P0] ${key} 是 <integer>，必须改成 <string>（Xcode 16.x 会 abort）`);
  } else if (!strForm.test(raw)) {
    warn(`[P0] 找不到 ${key}（<string> 形式），pbxproj 可能损坏`);
  }
}

// --- 2/3/4. F / B / SourcesBuildPhase 数量与闭环 ---
const fDefs = [...raw.matchAll(/^\s*<key>(F\d{23})<\/key>/gm)].map((m) => m[1]);
const bDefs = [...raw.matchAll(/^\s*<key>(B\d{23})<\/key>/gm)].map((m) => m[1]);

const phase = raw.match(/PBXSourcesBuildPhase[\s\S]*?<key>files<\/key>\s*<array>([\s\S]*?)<\/array>/);
const phaseFiles = phase ? [...phase[1].matchAll(/B\d{23}/g)].map((m) => m[0]) : [];

// 资源构建阶段（资产目录等走这里，不占 Sources 阶段名额）
const resPhase = raw.match(/PBXResourcesBuildPhase[\s\S]*?<key>files<\/key>\s*<array>([\s\S]*?)<\/array>/);
const resourcePhaseFiles = resPhase ? [...resPhase[1].matchAll(/B\d{23}/g)].map((m) => m[0]) : [];

const fSet = new Set(fDefs);
const bSet = new Set(bDefs);

if (fDefs.length !== bDefs.length) {
  warn(`[P0] 数量不等：PBXFileReference=${fDefs.length}，PBXBuildFile=${bDefs.length}`);
}
// Sources + Resources 两阶段合计应覆盖全部 BuildFile
const allPhaseFiles = [...phaseFiles, ...resourcePhaseFiles];
if (allPhaseFiles.length !== bDefs.length) {
  warn(`[P0] 构建阶段条目合计=${allPhaseFiles.length}（Sources ${phaseFiles.length} + Resources ${resourcePhaseFiles.length}）与 PBXBuildFile=${bDefs.length} 不等`);
}

// 每个 B 的 fileRef 必须指向已定义的 F
const refs = [...raw.matchAll(/<key>fileRef<\/key>\s*<string>(F\d{23})<\/string>/g)].map((m) => m[1]);
for (const r of refs) {
  if (!fSet.has(r)) warn(`[P0] 有 PBXBuildFile 引用了未定义的 fileRef: ${r}`);
}
// 每个 F 都应在某个 fileRef 中出现（排除 Products 里的 .app）
const referenced = new Set(refs);
for (const f of fDefs) {
  if (!referenced.has(f)) {
    // 允许 A00000000000000000000004 这类产品引用（F 格式不同，天然不在 fDefs）
    warn(`[P1] PBXFileReference ${f} 没有被任何 PBXBuildFile 引用（可能是死条目）`);
  }
}
// 每个 B 都必须落在某个构建阶段（Sources 或 Resources）
for (const b of bDefs) {
  if (!allPhaseFiles.includes(b)) warn(`[P0] PBXBuildFile ${b} 不在任何构建阶段（Sources/Resources）`);
}

// 磁盘 .swift ↔ F 引用
let diskSwift = [];
if (fs.existsSync(SRC)) {
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.name.endsWith('.swift')) diskSwift.push(e.name);
    }
  };
  walk(SRC);
}
const pbxPaths = [...raw.matchAll(/<key>path<\/key>\s*<string>([A-Za-z0-9_+.-]+\.swift)<\/string>/g)].map((m) => m[1]);
const diskSet = new Set(diskSwift);
const pbxSet = new Set(pbxPaths);

// 非源码资源引用（资产目录 / storyboard / plist 等）——它们也占 PBXFileReference 名额，
// 计算「源码引用数」时必须剔除，否则磁盘 .swift 数永远对不上。
// 按 lastKnownFileType 判定资源引用（folder / xcassets 等无扩展名，不能只看 path）
const resourceRefs = [...raw.matchAll(/<key>(F\d{23})<\/key>\s*<dict>([\s\S]*?)<\/dict>/g)]
  .filter((m) => !/<string>sourcecode\.swift<\/string>/.test(m[2]))
  .map((m) => m[1]);

for (const f of diskSwift) {
  if (!pbxSet.has(f)) warn(`[P0] ${f} 在磁盘上但未注册到 pbxproj`);
}
for (const f of pbxPaths) {
  if (!diskSet.has(f)) warn(`[P0] pbxproj 引用了不存在的源文件：${f}`);
}
const swiftRefCount = fDefs.length - resourceRefs.length;
if (diskSwift.length !== swiftRefCount) {
  warn(`[P1] 磁盘 .swift 数=${diskSwift.length} 与 pbxproj 中 .swift 引用数=${swiftRefCount} 不一致（另有资源引用 ${resourceRefs.length} 个）`);
}

// --- 5. 结构配平 ---
const count = (re) => (raw.match(re) || []).length;
const dictOpen = count(/<dict>/g);
const dictClose = count(/<\/dict>/g);
const arrOpen = count(/<array>/g);
const arrClose = count(/<\/array>/g);
if (dictOpen !== dictClose) warn(`[P0] <dict> 不配平：开=${dictOpen} 闭=${dictClose}`);
if (arrOpen !== arrClose) warn(`[P0] <array> 不配平：开=${arrOpen} 闭=${arrClose}`);

// --- 报告 ---
console.log('pbxproj 校验');
console.log(`  PBXFileReference      = ${fDefs.length}（其中 .swift ${fDefs.length - resourceRefs.length} + 资源 ${resourceRefs.length}）`);
console.log(`  PBXBuildFile          = ${bDefs.length}`);
console.log(`  SourcesBuildPhase.files = ${phaseFiles.length}`);
console.log(`  磁盘 .swift            = ${diskSwift.length}`);
console.log(`  archiveVersion        = ${/<key>archiveVersion<\/key>\s*<string>/.test(raw) ? 'string ✓' : '✗ 非 string'}`);
console.log(`  objectVersion         = ${/<key>objectVersion<\/key>\s*<string>/.test(raw) ? 'string ✓' : '✗ 非 string'}`);

if (problems.length === 0) {
  console.log('\n✓ 全部校验通过');
  process.exit(0);
} else {
  console.log(`\n✗ 发现 ${problems.length} 个问题：`);
  problems.forEach((p) => console.log('  - ' + p));
  process.exit(1);
}
