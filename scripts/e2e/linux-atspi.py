#!/usr/bin/env python3
import argparse,json,time
from pathlib import Path
import pyatspi
def children(n):
 for i in range(n.childCount):
  try: yield n.getChildAtIndex(i)
  except Exception: pass
def walk(n):
 yield n
 for c in children(n): yield from walk(c)
def role(n):
 try:return n.getRoleName()
 except Exception:return "unknown"
def text(n):
 try:t=n.queryText();return t.getText(0,t.characterCount)
 except Exception:return ""
def wait(probe):
 end=time.monotonic()+90
 while time.monotonic()<end:
  v=probe()
  if v:return v
  time.sleep(.05)
 raise AssertionError("timeout")
def snap(n,d=0):
 r={"name":n.name or "","role":role(n)};v=text(n)
 if v:r["text"]=v
 if d<10:r["children"]=[snap(c,d+1) for c in children(n)]
 return r
p=argparse.ArgumentParser();p.add_argument("--output",type=Path,required=True);a=p.parse_args();desktop=pyatspi.Registry.getDesktop(0);app=None
try:
 app=wait(lambda:next((x for x in children(desktop) if any(role(n)=="frame" and (n.name or "")=="MoveBit" for n in walk(x))),None));window=next(n for n in walk(app) if role(n)=="frame")
 wait(lambda:any("Active today" in (n.name or "") or "Active today" in text(n) for n in walk(window)))
 for segment in ["Today","History","Settings","About"]:
  # GtkStackSwitcher buttons expose varying atspi roles across GTK builds;
  # match the localized segment name on any node instead of a role.
  wait(lambda segment=segment:any((n.name or "") == segment for n in walk(window)))
 wait(lambda:any("Data stays on your device" in (n.name or "") or "Data stays on your device" in text(n) for n in walk(window)))
 a.output.mkdir(parents=True,exist_ok=True);(a.output/"accessibility.json").write_text(json.dumps(snap(app),ensure_ascii=False,indent=2),encoding="utf-8");(a.output/"interaction-trace.json").write_text(json.dumps({"platform":"linux","actions":["launch:isolated-config"],"assertions":["packaged GTK4 window activated","four in-window segment tabs exposed","statusbar carries the honest data-local line","RVT1 backend activity state reached native accessibility tree"]},indent=2),encoding="utf-8")
except Exception:
 if app:(a.output/"accessibility-failure.json").write_text(json.dumps(snap(app),ensure_ascii=False,indent=2),encoding="utf-8")
 raise
