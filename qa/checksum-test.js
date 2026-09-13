'use strict';
// 校验和算法等价性验证
// Swift 实现：s = s.addingReportingOverflow(UInt16(b)).partialValue  (UInt16 回绕加)
// 期望等价于 u16 累加和（wrap）
function swiftChecksum16(bytes){
  let s = 0; // UInt16
  for(const b of bytes){ s = (s + b) & 0xFFFF; } // addingReportingOverflow(...).partialValue == 回绕加
  return s;
}
function refSum(bytes){ let s=0; for(const b of bytes) s=(s+b)&0xFFFF; return s; }

const cases = [
  {name:'54 0d 00 03 00 00', bytes:[0x54,0x0d,0x00,0x03,0x00,0x00], expect:0x0064},
];
let ok = true;
for(const c of cases){
  const a = swiftChecksum16(c.bytes);
  const b = refSum(c.bytes);
  const pass = (a===c.expect) && (a===b);
  if(!pass) ok=false;
  console.log(`${pass?'PASS':'FAIL'} ${c.name} -> swift=0x${a.toString(16).padStart(4,'0')} ref=0x${b.toString(16).padStart(4,'0')} expect=0x${c.expect.toString(16).padStart(4,'0')}`);
}

// wrap 行为验证：超过 0xFFFF 是否回绕
const wrapBytes = new Array(300).fill(0xFF); // 300*255 = 76500 -> 76500 & 0xFFFF = 10964 = 0x2AD4
const w = swiftChecksum16(wrapBytes);
console.log(`WRAP test: 300x0xFF -> 0x${w.toString(16)} (expect 0x2ad4) ${w===0x2ad4?'PASS':'FAIL'}`);
if(w!==0x2ad4) ok=false;

// 边界：单字节 0xFF
console.log(`single 0xFF -> 0x${swiftChecksum16([0xFF]).toString(16)} (expect 0xff)`);
console.log('OVERALL', ok?'PASS':'FAIL');
