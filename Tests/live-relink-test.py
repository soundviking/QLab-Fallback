"""Runs only against the named, empty temporary workspace created for this test."""
from pathlib import Path
import subprocess, re, shutil, hashlib, time
root=Path(__file__).resolve().parents[1]
workspace=Path('/private/tmp/QLab54 Relink Test/QLab54 Relink Test.qlab5')
assert workspace.is_file()
source=Path.home() / 'QLab-Fallback-Test-Media/CAKE - I Will Survive.flac'
dest=workspace.parent/'received media é'/'CAKE - I Will Survive.flac'
dest.parent.mkdir(exist_ok=True)
shutil.copy2(source,dest)
original=hashlib.sha256(source.read_bytes()).hexdigest()
def run(script,*args,check=True):
 r=subprocess.run(['/usr/bin/osascript','-e',script.replace('application id "com.figure53.QLab.5"','application "/Applications/QLab.app"'),*map(str,args)],text=True,capture_output=True,timeout=30)
 if check and r.returncode: raise RuntimeError(r.stderr)
 return r
scripts=dict(re.findall(r'static let (\w+) = """\n(.*?)\n    """',(root/'Sources/LiveMirrorQLab.swift').read_text(),re.S))
setup='''on run argv
 tell application "/Applications/QLab.app"
  set matches to every workspace whose path is item 1 of argv
  if (count matches) is not 1 then error "Temporary workspace missing"
  set w to item 1 of matches
  if (count cues of w) > 1 then error "Fixture is not empty"
  make w type "Audio"
  set a to last cue of w
  set q number of a to "1"
  make w type "Audio"
  set b to last cue of w
  set q number of b to "1.5"
  make w type "Audio"
  make w type "MIDI File"
  save w
  return (unique id of w) & tab & (uniqueID of a) & tab & (uniqueID of b)
 end tell
end run'''
wid,a,b=run(setup,workspace).stdout.strip().split('\t')
old_relink=(root/'Tests/Fixtures/relink-5.3.applescript').read_text()
r=run(old_relink,wid,workspace,a,dest,check=False)
assert r.returncode and '-1700' in r.stderr, r.stdout+r.stderr
print('PASS: reproduced Build5.3 relink -1700 in real QLab',flush=True)
for cue in (a,b):
 run(scripts['relink'],wid,workspace,cue,dest)
run(scripts['saveExpected'],wid,workspace)
for cue in (a,b): run(scripts['verifyTargets'],wid,workspace,cue,dest)
print('PASS: Build5.4 relinks both Cake cues and verifies after save',flush=True)
missing=run(scripts['relink'],wid,workspace,a,dest.parent/'missing.flac',check=False)
assert missing.returncode
print('PASS: missing media rejected',flush=True)
raw=run(scripts['targets'],wid).stdout.strip().splitlines()
assert len(raw)==2,raw
print('PASS: empty Audio/MIDI File cues ignored',flush=True)
run('''on run argv
 tell application "/Applications/QLab.app"
  set matches to every workspace whose unique id is item 1 of argv
  set w to item 1 of matches
  if path of w is not item 2 of argv then error "Wrong fixture"
  close w saving no
  open POSIX file (item 2 of argv)
 end tell
end run''',wid,workspace)
for cue in (a,b): run(scripts['verifyTargets'],wid,workspace,cue,dest)
print('PASS: both targets survive close/reopen in real QLab',flush=True)
assert hashlib.sha256(source.read_bytes()).hexdigest()==original
print('PASS: original Cake media unchanged; no GO/audio executed',flush=True)
