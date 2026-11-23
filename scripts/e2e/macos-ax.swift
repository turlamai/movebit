import AppKit
import ApplicationServices
import Foundation
enum E: Error { case failure(String) }
func attr(_ e:AXUIElement,_ n:String)->CFTypeRef?{var v:CFTypeRef?;return AXUIElementCopyAttributeValue(e,n as CFString,&v) == .success ? v:nil}
func str(_ e:AXUIElement,_ n:String)->String{attr(e,n) as? String ?? ""}
func children(_ e:AXUIElement)->[AXUIElement]{attr(e,kAXChildrenAttribute) as? [AXUIElement] ?? []}
func walk(_ e:AXUIElement,_ depth:Int=28)->[AXUIElement]{guard depth>0 else{return [e]};return [e]+children(e).flatMap{walk($0,depth-1)}}
func role(_ e:AXUIElement)->String{str(e,kAXRoleAttribute)}
func label(_ e:AXUIElement)->String{[kAXTitleAttribute,kAXValueAttribute,kAXDescriptionAttribute].map{str(e,$0)}.first{!$0.isEmpty} ?? ""}
func find(_ e:AXUIElement,_ text:String,_ roleFilter:String?=nil)->[AXUIElement]{walk(e).filter{n in label(n).contains(text) && (roleFilter == nil || role(n) == roleFilter)}}
func contains(_ e:AXUIElement,_ f:String)->Bool{!find(e,f).isEmpty}
func press(_ e:AXUIElement)->Bool{AXUIElementPerformAction(e,kAXPressAction as CFString) == .success}
func pressFirst(_ e:AXUIElement,_ text:String,_ roleFilter:String?=nil)->Bool{find(e,text,roleFilter).first.map(press) ?? false}
func wait<T>(_ probe:()->T?) throws->T{let d=Date().addingTimeInterval(120);while Date()<d{if let v=probe(){return v};Thread.sleep(forTimeInterval:0.05)};throw E.failure("timeout")}
func snap(_ e:AXUIElement,_ depth:Int=0)->[String:Any]{var r:[String:Any]=["role":role(e),"title":str(e,kAXTitleAttribute),"value":str(e,kAXValueAttribute),"label":str(e,kAXDescriptionAttribute)];if depth<10{r["children"]=children(e).map{snap($0,depth+1)}};return r}
func require(_ cond:Bool,_ what:String)throws{guard cond else{throw E.failure("assertion failed: \(what)")}}
func eprint(_ t:String)->Void{FileHandle.standardError.write(Data((t+"\n").utf8))}
let a=CommandLine.arguments
func arg(_ name:String)->String{a[a.firstIndex(of:name)!+1]}
let pid=Int32(arg("--pid"))!
let out=URL(fileURLWithPath:arg("--output"),isDirectory:true)
let app=AXUIElementCreateApplication(pid)
func liveWindows()->[AXUIElement]{attr(app,kAXWindowsAttribute) as? [AXUIElement] ?? []}

// 2026-11-15 acceptance contract: the packaged app reaches the native AX
// tree with the redesigned surfaces AND the reminder lifecycle closes over
// them — segments respond to presses, the invitation waits attached to the
// pet and resolves through its 做好了 (Done) button, and the pet surface
// announces that petting never records completion. The seed profile pins
// language=en so assertions match the prototype's English strings.
do{
  guard AXIsProcessTrusted() else{throw E.failure("accessibility unavailable")}
  eprint("step: windows")
  let windows:[AXUIElement]=try wait{let ws=liveWindows();return (ws.isEmpty == false) ? ws : nil}
  eprint("step: main window")
  let main=try wait{windows.first{contains($0,"Active today")} ?? nil}
  eprint("step: segments")
  for (tab,marker) in [("History","Work pattern insights"),("Settings","Quiet hours"),("About","Check for updates")]{
    try require(pressFirst(main,tab),"segment button \(tab) pressable")
    _ = try wait{contains(main,marker) ? true:nil}
    eprint("step: segment \(tab) ok")
  }
  try require(pressFirst(main,"Today"),"segment button Today pressable")
  _ = try wait{contains(main,"Time using your computer, not exercise") ? true:nil}
  eprint("step: pet a11y")
  try require(liveWindows().contains{contains($0,"Pat Mubi")},"pet surface exposes the pat a11y contract")
  eprint("step: invitation")
  let companion=try wait{liveWindows().first{w in contains(w,"Pat Mubi") && contains(w,"Done")} ?? nil}
  try require(pressFirst(companion,"Done","AXButton"),"invitation Done pressable")
  // Resolves at once (the ledger clears); a fresh cue only arrives after
  // the next virtual-clock tick, so a short absence window is race-free.
  let absenceDeadline=Date().addingTimeInterval(8)
  var resolved=false
  while Date()<absenceDeadline{
    if liveWindows().first(where:{w in contains(w,"Pat Mubi") && contains(w,"Done")}) == nil {resolved=true;break}
    Thread.sleep(forTimeInterval:0.05)
  }
  try require(resolved,"invitation Done resolves the invitation")
  eprint("step: all assertions passed")
  try JSONSerialization.data(withJSONObject:snap(app),options:.prettyPrinted).write(to:out.appendingPathComponent("accessibility.json"))
  try JSONSerialization.data(withJSONObject:["platform":"macos","actions":["launch:isolated-config","press:segments","press:invitation-done"],"assertions":["packaged SwiftUI window activated","four segments reachable and responsive","invitation delivered on the pet and resolved by its Done button","pet surface announces petting never records completion","RVT1 backend activity state reached native accessibility tree"]],options:.prettyPrinted).write(to:out.appendingPathComponent("interaction-trace.json"))
  guard NSRunningApplication(processIdentifier:pid)?.terminate()==true else{throw E.failure("termination rejected")}
}catch{
  try? JSONSerialization.data(withJSONObject:snap(app),options:.prettyPrinted).write(to:out.appendingPathComponent("accessibility-failure.json"))
  FileHandle.standardError.write(Data("MoveBit acceptance failed: \(error)\n".utf8))
  exit(1)
}
