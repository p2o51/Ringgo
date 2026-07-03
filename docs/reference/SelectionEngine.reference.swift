import Foundation
import CoreGraphics

// 选词手势【正解】—— 对抗验证后收敛的单一规则:
//   最终选区 = 触碰集 ∪ {同一 block、同一行、夹在相邻已保留词之间、且离前一个已保留词的水平间距 ≤ maxGap 的词}
//   三条硬不变式:①笔画真正穿过的词永远保留(绝不丢弃)②只在相邻已保留词之间回填(不拉入弧线绕过的词)
//   ③一切分组/回填强制不跨 block(同 y 的两栏也隔离)。maxGap 用"该行相邻词间距中位数×k",自适应两端对齐/宽制表符/CJK。

struct Word { let text: String; let rect: CGRect; let block: Int }
func c(_ w: Word) -> CGPoint { CGPoint(x: w.rect.midX, y: w.rect.midY) }
func mk(_ t:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ b:Int)->Word{ Word(text:t,rect:CGRect(x:x,y:y,width:w,height:h),block:b) }

// ---- 几何 ----
func cross(_ a:CGPoint,_ b:CGPoint,_ p:CGPoint)->CGFloat{(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)}
func segI(_ a:CGPoint,_ b:CGPoint,_ cc:CGPoint,_ d:CGPoint)->Bool{let d1=cross(cc,d,a),d2=cross(cc,d,b),d3=cross(a,b,cc),d4=cross(a,b,d);return ((d1>0) != (d2>0)) && ((d3>0) != (d4>0))}
func pathHits(_ pts:[CGPoint],_ r:CGRect)->Bool{
  for p in pts where r.contains(p){return true}
  let tl=CGPoint(x:r.minX,y:r.minY),tr=CGPoint(x:r.maxX,y:r.minY),br=CGPoint(x:r.maxX,y:r.maxY),bl=CGPoint(x:r.minX,y:r.maxY)
  for i in 0..<max(0,pts.count-1){let a=pts[i],b=pts[i+1];if segI(a,b,tl,tr)||segI(a,b,tr,br)||segI(a,b,br,bl)||segI(a,b,bl,tl){return true}}
  return false
}
func median(_ xs:[CGFloat])->CGFloat{ xs.isEmpty ? 0 : xs.sorted()[xs.count/2] }

// ---- 旧算法(有 bug):全局阅读顺序 min…max 填充(忽略 block) ----
func oldSelect(_ words:[Word],_ path:[CGPoint],_ radius:CGFloat=16)->[Word]{
  let order = words.enumerated().sorted{ a,b in a.element.rect.midY != b.element.rect.midY ? a.element.rect.midY < b.element.rect.midY : a.element.rect.minX < b.element.rect.minX }.map{$0.element}
  let touchedIdx = order.enumerated().filter{ pathHits(path,$0.element.rect.insetBy(dx:-radius,dy:-radius)) }.map{$0.offset}
  guard let lo=touchedIdx.min(),let hi=touchedIdx.max() else {return []}
  return Array(order[lo...hi])
}

// ---- 正解 ----
func newSelect(_ words:[Word],_ path:[CGPoint],_ radius:CGFloat=16,_ k:CGFloat=1.4)->[Word]{
  // ① 触碰集(永远保留)
  let touched = words.filter{ pathHits(path,$0.rect.insetBy(dx:-radius,dy:-radius)) }
  if touched.isEmpty { return [] }
  func id(_ w:Word)->String{ "\(w.text)@\(Int(w.rect.minX)),\(Int(w.rect.minY))" }
  let touchedIds = Set(touched.map(id))
  // ③ 按 (block, 行) 分组;行 = 同 block 内 midY 聚类
  func lineKey(_ w:Word)->Int{ Int((w.rect.midY/14).rounded()) }  // ~行高粒度
  var groups:[String:[Word]]=[:]
  for w in words { groups["\(w.block)#\(lineKey(w))",default:[]].append(w) }
  var result:[Word]=[]
  for (_, g0) in groups {
    let ls = g0.sorted{$0.rect.minX<$1.rect.minX}
    let tpos = ls.enumerated().filter{ touchedIds.contains(id($0.element)) }.map{$0.offset}
    guard let lo=tpos.min(), let hi=tpos.max() else { continue }  // 本组没被碰到 → 跳过
    // maxGap:本行相邻词间距中位数 × k + radius(自适应两端对齐/宽制表符)
    var gaps:[CGFloat]=[]; for i in 1..<max(1,ls.count){ gaps.append(ls[i].rect.minX - ls[i-1].rect.maxX) }
    let maxGap = median(gaps)*k + radius
    var prevKeptMaxX: CGFloat? = nil
    for i in lo...hi {
      let w = ls[i]
      if i==lo || touchedIds.contains(id(w)) { result.append(w); prevKeptMaxX=w.rect.maxX; continue } // ①永不丢触碰词
      // ②只在相邻已保留词之后、gap 合法时回填未触碰词(弧线绕过的远词因 gap 大被拒)
      if let pk=prevKeptMaxX, (w.rect.minX - pk) <= maxGap { result.append(w); prevKeptMaxX=w.rect.maxX }
      // else 跳过(不 break、不更新 prevKept → 不把后面的远词链进来,但后面的触碰词仍会在 touched 分支保留)
    }
  }
  return result.sorted{ $0.rect.midY != $1.rect.midY ? $0.rect.midY<$1.rect.midY : $0.rect.minX<$1.rect.minX }
}

func txt(_ ws:[Word])->String{ ws.map{$0.text}.joined(separator:" ") }
var pass=0,fail=0
func check(_ n:String,_ ok:Bool,_ d:String=""){ print((ok ? "  ✅ ":"  ❌ ")+n+(d.isEmpty ? "":" — "+d)); if ok{pass+=1}else{fail+=1} }
func touchedOf(_ words:[Word],_ path:[CGPoint],_ r:CGFloat=16)->Set<String>{ Set(words.filter{pathHits(path,$0.rect.insetBy(dx:-r,dy:-r))}.map{"\($0.text)"}) }

print("========== S1:用户实测 bug —— 大对角线从底部终端斜穿到顶部聊天 ==========")
do {
  let ws=[ mk("Meet",60,96,74,28,0),mk("Sonnet",140,96,96,28,0),mk("smarter",250,96,110,28,0),
           mk("Switch",60,136,92,28,0),mk("anytime",160,136,110,28,0),mk("model",290,136,86,28,0),
           mk("nFirstLaunch",60,620,158,28,1),mk("sudo",228,620,66,28,1),mk("Applications",304,620,150,28,1),mk("Xcode",464,620,86,28,1) ]
  let s=[c(ws[8]), CGPoint(x:250,y:400), c(ws[1])]  // Applications(底) → 中间 → Sonnet(顶)
  let old=oldSelect(ws,s), new=newSelect(ws,s), t=touchedOf(ws,s)
  print("  物理碰到的词:", t.sorted()); print("  【旧】", txt(old), "  (\(old.count) 词)"); print("  【新】", txt(new), "  (\(new.count) 词)")
  check("旧算法复现 bug:跨块填一大片", old.count>=6)
  check("新算法只保留真正碰到的词、不跨块乱填", Set(new.map{$0.text}).isSubset(of:t) && new.count<=t.count+1, "新=\(txt(new))")
}

print("\n========== ADV-2:同行两远隔词,中间大空白,直线全程穿过 ==========")
do {
  let ws=[ mk("swiftc",60,300,110,28,0), mk("done",700,300,80,28,0) ]  // 中间 500px 空白
  let s=[c(ws[0]), c(ws[1])]
  let new=newSelect(ws,s)
  print("  【新】", txt(new))
  check("两个触碰词都保留(不再只剩 swiftc)", Set(new.map{$0.text})==["swiftc","done"], txt(new))
}

print("\n========== ADV-8:同 y 左右两栏(不同 block),V 形笔画只碰两栏各一词、绕开中间词 ==========")
do {
  let ws=[ mk("hello",60,300,90,28,0), mk("MID",300,300,80,28,0),        // 左栏 block0(MID 未被碰)
           mk("sudo",560,300,70,28,1), mk("Applications",660,300,150,28,1) ] // 右栏 block1(同 y)
  let s=[c(ws[0]), CGPoint(x:330,y:384), c(ws[2])]  // V 形:hello → 下沉绕过 MID → sudo
  let old=oldSelect(ws,s), new=newSelect(ws,s), t=touchedOf(ws,s)
  print("  碰到:", t.sorted(), "  【旧】", txt(old), "  【新】", txt(new))
  check("旧算法跨栏桥接(把 MID 桥进来)", old.contains{$0.text=="MID"})
  check("新算法两栏各自只出触碰词,不桥接 MID/不跨栏合并", Set(new.map{$0.text})==["hello","sudo"], txt(new))
}

print("\n========== ADV-6:两端对齐/宽制表符,合法整行(全触碰),大间距不应砍断 ==========")
do {
  let ws=[ mk("col1",60,300,80,28,0), mk("col2",320,300,80,28,0), mk("col3",600,300,80,28,0) ] // 均匀大间距
  let s=[c(ws[0]),c(ws[1]),c(ws[2])]
  let new=newSelect(ws,s)
  check("整行三词全保留(不被大空白砍断)", Set(new.map{$0.text})==["col1","col2","col3"], txt(new))
}

print("\n========== ADV-4:陡对角线斜穿多行段落(每行只碰 1 词) ==========")
do {
  var ws:[Word]=[]; let rows=6
  for r in 0..<rows { for cch in 0..<4 { ws.append(mk("w\(r)\(cch)", 60+CGFloat(cch)*120, 300+CGFloat(r)*36, 100, 28, 0)) } }
  // 对角线:每行大约只穿过一个词
  var s:[CGPoint]=[]
  for r in 0..<rows { let rx: CGFloat = 110 + CGFloat(r)*70; let ry: CGFloat = 314 + CGFloat(r)*36; s.append(CGPoint(x: rx, y: ry)) }
  let new=newSelect(ws,s); let t=touchedOf(ws,s)
  print("  碰到:", t.sorted(), "  【新】", txt(new))
  check("只出被物理穿过的词,不把每行中段未触碰词回填成碎片", Set(new.map{$0.text})==t)
}

print("\n========== 回归:正常沿行划 / 长段 / 轻点 / 弧线绕过 ==========")
do {
  let ws=[ mk("sudo",60,300,70,28,0),mk("brew",140,300,70,28,0),mk("install",220,300,90,28,0),mk("xcode",320,300,90,28,0) ]
  check("沿行划全选", Set(newSelect(ws,[c(ws[0]),c(ws[3])]).map{$0.text})==["sudo","brew","install","xcode"])
  check("轻点单词", txt(newSelect(ws,[c(ws[2])]))=="install")
  // 弧线绕过 brew(swipe 语义:相邻小 gap → 回填,但绝不丢触碰词)
  let arc=[c(ws[0]), CGPoint(x:175,y:340), c(ws[2]), c(ws[3])]  // 碰 sudo/install/xcode,从 brew 下方绕过
  let a=newSelect(ws,arc); let ta=touchedOf(ws,arc)
  print("  弧线碰到:", ta.sorted(), " → 选中:", txt(a))
  check("弧线绕过:所有触碰词都在(一致性:不丢触碰词)", ta.isSubset(of:Set(a.map{$0.text})), txt(a))
}

print("\n========== 小结 ==========")
print("PASS \(pass) / FAIL \(fail)")
print(fail==0 ? "→ 正解通过全部对抗场景(含 ADV-2/4/6/8 与用户实测 bug),是真的修好,不是选择性测试" : "→ 仍有问题")
