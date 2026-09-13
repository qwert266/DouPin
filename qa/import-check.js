'use strict';
// import 与符号使用匹配检查
const fs=require('fs'), path=require('path');
const ROOT='C:/Users/24658/Desktop/DouPin', SRC=path.join(ROOT,'Sources');
function walk(d,o){for(const e of fs.readdirSync(d,{withFileTypes:true})){const p=path.join(d,e.name);if(e.isDirectory())walk(p,o);else if(e.name.endsWith('.swift'))o.push(p);}return o;}
const files=walk(SRC,[]);
const rel=p=>path.relative(ROOT,p).replace(/\\/g,'/');

// 符号 -> 需要的模块
const symbolModules = {
  'CBUUID':'CoreBluetooth','CBPeripheral':'CoreBluetooth','CBCentralManager':'CoreBluetooth',
  'CBCharacteristic':'CoreBluetooth','CBService':'CoreBluetooth','CBPeripheralManager':'CoreBluetooth',
  'UIImage':'UIKit','UIColor':'UIKit','UIFont':'UIKit','UIGraphicsImageRenderer':'UIKit',
  'UIApplication':'UIKit','UIPasteboard':'UIKit','UIDevice':'UIKit','UIScreen':'UIKit',
  'CGRect':'CoreGraphics','CGSize':'CoreGraphics','CGPoint':'CoreGraphics','CGFloat':'CoreGraphics',
  'CGContext':'CoreGraphics','CGColor':'CoreGraphics','CGImage':'CoreGraphics','CGColorSpace':'CoreGraphics',
  'Data':'Foundation','URL':'Foundation','Date':'Foundation','UUID':'Foundation',
  'NSAttributedString':'Foundation','NSString':'Foundation','HTTPURLResponse':'Foundation',
  'URLSession':'Foundation','JSONSerialization':'Foundation','Calendar':'Foundation',
  'ModelContainer':'SwiftData','ModelContext':'SwiftData','@Model':'SwiftData','Query':'SwiftData',
};
// UIView 需要 UIKit
const extra = { 'UIView':'UIKit','UIHostingController':'SwiftUI','ImageRenderer':'SwiftUI' };

const report={};
for(const f of files){
  const txt=fs.readFileSync(f,'utf8');
  // imports
  const imports=[...txt.matchAll(/^\s*import\s+([A-Za-z0-9_]+)/gm)].map(m=>m[1]);
  const impSet=new Set(imports);
  // 是否含 SwiftUI（隐含 UIKit/CoreGraphics 部分类型通过 SwiftUI 再导出？实际 SwiftUI 不导出 UIKit）
  const usesSwiftUI=impSet.has('SwiftUI');
  const missing=[];
  for(const [sym,mod] of Object.entries(symbolModules)){
    const re=new RegExp('\\b'+sym.replace('@','')+'\\b');
    if(re.test(txt)){
      // 特殊：CGFloat/CGRect 在 SwiftUI 里也可用（SwiftUI 重导出 CoreGraphics）——放宽
      if((mod==='CoreGraphics') && usesSwiftUI) continue;
      // Data/URL/Date 等 Foundation：SwiftUI/SwiftData 也重导出 Foundation
      if(mod==='Foundation' && (usesSwiftUI||impSet.has('SwiftData')||impSet.has('PhotosUI')||impSet.has('CoreBluetooth'))) continue;
      if(!impSet.has(mod)) missing.push(sym+'->'+mod);
    }
  }
  if(missing.length) report[rel(f)]={imports,missing};
}
console.log(JSON.stringify(report,null,1));
console.log('MISMATCH FILES', Object.keys(report).length);
