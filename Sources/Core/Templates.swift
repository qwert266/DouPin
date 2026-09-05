import Foundation

/// 内置图纸模板（原创像素图案）
struct PatternTemplate: Identifiable {
    let id = UUID()
    let name: String
    let category: String
    /// 字符 → 官方 colorId（0 = 空格）
    static let charMap: [Character: Int] = [
        "W": 185,  // 白 H2
        "K": 199,  // 黑 H16
        "G": 187,  // 灰 H4
        "L": 194,  // 浅灰 H11
        "R": 250,  // 红 R1
        "D": 144,  // 深红 F7
        "P": 125,  // 粉 E12
        "H": 118,  // 玫粉 E5
        "Y": 8,    // 黄 A8
        "A": 26,   // 金 A26
        "O": 252,  // 橙 R3
        "S": 127,  // 肤色 E14
        "B": 147,  // 棕 F10
        "g": 34,   // 绿 B8
        "l": 29,   // 浅绿 B3
        "d": 38,   // 深绿 B12
        "c": 82,   // 浅蓝 C24
        "b": 257,  // 蓝 R8
        "n": 70,   // 藏青 C12
        "V": 92,   // 紫 D5
        "v": 96,   // 浅紫 D9
        "M": 2,    // 米色 A2
        "C": 69,   // 青 C11
        "m": 263,  // 薄荷 R14
    ]

    var rows: [String]

    var width: Int { rows.map { $0.count }.max() ?? 0 }
    var height: Int { rows.count }

    /// 转为色号网格（colorId，0 = 空）
    var cells: [Int] {
        let w = width
        var out = [Int](repeating: 0, count: w * rows.count)
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                out[y * w + x] = PatternTemplate.charMap[ch] ?? 0
            }
        }
        return out
    }
}

enum TemplateLibrary {
    static let all: [PatternTemplate] = [
        PatternTemplate(name: "爱心", category: "经典", rows: [
            "................",
            "..RRRR....RRRR..",
            ".RRRRRR..RRRRRR.",
            "RRRRRRRRRRRRRRRR",
            "RRRRRRRRRRRRRRRR",
            "RRRRRRRRRRRRRRRR",
            ".RRRRRRRRRRRRRR.",
            "..RRRRRRRRRRRR..",
            "...RRRRRRRRRR...",
            "....RRRRRRRR....",
            ".....RRRRRR.....",
            "......RRRR......",
            ".......RR.......",
            "................",
        ]),
        PatternTemplate(name: "笑脸", category: "表情", rows: [
            "....YYYYYYYY....",
            "..YYYYYYYYYYYY..",
            ".YYYYYYYYYYYYYY.",
            ".YKKYYYYYYYYKKY.",
            ".YKKYYYYYYYYKKY.",
            "YYYYYYYYYYYYYYYY",
            "YYYYYYYYYYYYYYYY",
            "YYKYYYYYYYYYYKYY",
            "YYKKYYYYYYYYKKYY",
            "YYYKKKKKKKKKKYYY",
            ".YYYKKKKKKKKYYY.",
            "..YYYYYYYYYYYY..",
            "....YYYYYYYY....",
            "................",
        ]),
        PatternTemplate(name: "五角星", category: "经典", rows: [
            ".......AA.......",
            ".......AA.......",
            "......AAAA......",
            "......AAAA......",
            ".AAAAAAYYAAAAAA.",
            "AAAAAAAAAAAAAAAA",
            ".AAAAAAAAAAAAAA.",
            "..AAAAAAAAAAAA..",
            "...AAAAAAAAAA...",
            "...AAAAAAAAAA...",
            "..AAAAA..AAAAA..",
            "..AAA......AAA..",
            ".AAA........AAA.",
            ".AA..........AA.",
            "AA............AA",
            "................",
        ]),
        PatternTemplate(name: "西瓜", category: "食物", rows: [
            "....gggggggg....",
            "..ggllllllllgg..",
            ".gllRRRRRRRRllg.",
            ".glRRRRRRRRRRlg.",
            "gllRRRKRRKRRRllg",
            "gllRRKKRRKKRRllg",
            "gllRRRRRRRRRRllg",
            ".glRRRRRRRRRRlg.",
            ".gllRRRRRRRRllg.",
            "..ggllllllllgg..",
            "....gggggggg....",
            "......gggg......",
            ".......gg.......",
            "................",
        ]),
        PatternTemplate(name: "蘑菇", category: "自然", rows: [
            ".....RRRRRR.....",
            "...RRWWRRRRRR...",
            "..RRRWWRRRRRRR..",
            ".RRRRRRWWRRRRRR.",
            "RRWRRRRRRWWRRRRR",
            "RRWWRRRRRRWWRRRR",
            "RRRRRRRRRRRRRRRR",
            ".RRRRRRRRRRRRRR.",
            "..MMMMMMMMMMMM..",
            "...MMMMMMMMMM...",
            "...MMMMMMMMMM...",
            "....MMMMMMMM....",
            "....MMMMMMMM....",
            "....MMMMMMMM....",
            "................",
        ]),
        PatternTemplate(name: "小猫", category: "动物", rows: [
            "..KKK......KKK..",
            "..KWK......KWK..",
            "..KKK......KKK..",
            "..KKKKKKKKKKKK..",
            ".KKKKKKKKKKKKKK.",
            "KKWWKKKKKKKKWWKK",
            "KKWKKKKKKKKKKWKK",
            "KKKYYKKKKKKYYKKK",
            "KKKKKKKKKKKKKKKK",
            ".KKKWWKWWKWWKKK.",
            ".KKKKKKKKKKKKKK.",
            "..KKKKKKKKKKKK..",
            "...KKKK..KKKK...",
            "...KKK....KKK...",
            "...KKK....KKK...",
            "................",
        ]),
        PatternTemplate(name: "兔子", category: "动物", rows: [
            "...WW......WW...",
            "..WWWW....WWWW..",
            "..WKKW....WKKW..",
            "..WWWW....WWWW..",
            "..WWWWWWWWWWWW..",
            ".WWWWWWWWWWWWWW.",
            ".WWKKWWWWWWKKWW.",
            "WWWWWWWWWWWWWWWW",
            "WWWPWWWWWWWKPWWW",
            "WWWKKWWWWWWKKWWW",
            "WWWWWWPPWWWWWWWW",
            ".WWWWWWWWWWWWWW.",
            ".WWWWWWWWWWWWWW.",
            "..WWWWWWWWWWWW..",
            "...WWWWWWWWWW...",
            ".....WWWWWW.....",
        ]),
        PatternTemplate(name: "冰淇淋", category: "食物", rows: [
            "......PPPP......",
            ".....PPPPPP.....",
            "....PPPPPPPP....",
            "....PPMPPMPP....",
            "...PPPPPPPPPP...",
            "...PPMPPPPMPP...",
            "..PPPPPPPPPPPP..",
            "..PPPPMMPPPPPP..",
            ".PPPPPPPPPPPPPP.",
            ".PPPPPPPPPPPPP..",
            "PPPPPPPPPPPPPP..",
            ".PPPPPPPPPPPP...",
            "..BBBBBBBBBB....",
            "...BBBBBBBB.....",
            "....BBBBBB......",
            ".....BBBB.......",
        ]),
        PatternTemplate(name: "蝴蝶结", category: "配饰", rows: [
            "....HH....HH....",
            "..HHHHH.HHHHH...",
            ".HHPPHHHHHPPHH..",
            ".HHPHHHHHHHHPHH.",
            "..HHPPHHHPPHH...",
            "..HHHHHHHHHHHH..",
            "..HHHHHHHHHHHH..",
            "..HHPPHHHPPHH...",
            ".HHPHHHHHHHHPHH.",
            ".HHPPHHHHHPPHH..",
            "..HHHHH.HHHHH...",
            "....HH....HH....",
            "................",
        ]),
        PatternTemplate(name: "月亮", category: "自然", rows: [
            "......YYYY......",
            "....YYYYYY......",
            "...YYYYY........",
            "..YYYY..........",
            "..YYYY..........",
            ".YYYY...........",
            ".YYYY...........",
            ".YYYY...........",
            "..YYYY..........",
            "..YYYY..........",
            "...YYYYY........",
            "....YYYYYY.Y....",
            "......YYYY.YY...",
            "...........Y....",
            "................",
            "................",
        ]),
        PatternTemplate(name: "音符", category: "符号", rows: [
            ".....KKKKKKK....",
            ".....KKKKKKKK...",
            ".....KKKKKKKK...",
            ".....KKKKKKK....",
            ".....KKKKK......",
            ".....KKK........",
            ".....KKK........",
            ".....KKK........",
            "..K..KKK........",
            ".KKK.KKK........",
            ".KKKKKK.........",
            "..KKKKK.........",
            "...KKK..........",
            "................",
        ]),
        PatternTemplate(name: "圣诞树", category: "节日", rows: [
            ".......dd.......",
            "......dddd......",
            ".....dddddd.....",
            "....dddddddd....",
            "...dddddddddd...",
            "..dddddddddddd..",
            ".dddddddddddddd.",
            "..dddddddddddd..",
            "...gggggggggg...",
            "....gggggggg....",
            ".....gggggg.....",
            "......gggg......",
            "......gggg......",
            "....BBBBBBBB....",
            "................",
        ]),
        PatternTemplate(name: "南瓜", category: "节日", rows: [
            ".....gggggg.....",
            "......gggg......",
            "....OOOOOOOO....",
            "...OOOOOOOOOO...",
            "..OOOOOOOOOOOO..",
            ".OAOOOOOOOOOOAO.",
            ".OAOOOOOOOOOOAO.",
            "OAOOOOOOOOOOOOAO",
            "OAOOOOOOOOOOOOAO",
            ".OAOOOOOOOOOOAO.",
            ".OOOOOOOOOOOOOO.",
            "..OOOOOOOOOOOO..",
            "...OOOOOOOOOO...",
            "....OOOOOOOO....",
            "................",
        ]),
        PatternTemplate(name: "彩虹", category: "自然", rows: [
            ".....RRRRRR.....",
            "...RRRRRRRRRR...",
            "..RRRRRRRRRRRR..",
            ".RRRR......RRRR.",
            ".RRR........RRR.",
            "AAAA......AAAA..",
            ".AAA........AAA.",
            "YYYY........YYYY",
            "YYYY........YYYY",
            "cccc........cccc",
            ".ccc........ccc.",
            "cccc........cccc",
            "bbbb........bbbb",
            ".bbb........bbb.",
            "................",
        ]),
    ]

    static var categories: [String] {
        Array(Set(all.map { $0.category })).sorted()
    }
}
