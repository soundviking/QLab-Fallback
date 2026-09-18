from pathlib import Path
import re, shutil, subprocess, json, hashlib
root=Path(__file__).resolve().parents[1]
fixture=Path('/private/tmp/QLab55 Integration')
fixture.mkdir(exist_ok=False)
source=Path('/private/tmp/QLab54 Relink Test/QLab54 Relink Test.qlab5')
assert source.is_file()
received=fixture/'Received'; received.mkdir()
first=received/'First'; first.mkdir()
second=received/'Second'; second.mkdir()
w1=first/'QLab55 Fixture.qlab5'; w2=second/'QLab55 Fixture.qlab5'
shutil.copy2(source,w1); shutil.copy2(source,w2)
media=second/'Audio é'; media.mkdir()
cake=Path.home() / 'QLab-Fallback-Test-Media/CAKE - I Will Survive.flac'
shutil.copy2(cake,media/cake.name)
scripts=dict(re.findall(r'static let (\w+) = """\n(.*?)\n    """',(root/'Sources/LiveMirrorQLab.swift').read_text(),re.S))
def run(script,*args):
 r=subprocess.run(['/usr/bin/osascript','-e',script.replace('application id "com.figure53.QLab.5"','application "/Applications/QLab.app"'),*map(str,args)],capture_output=True,text=True,timeout=30)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip()
before=run('tell application "/Applications/QLab.app" to get path of every workspace')
run('on run argv\ntell application "/Applications/QLab.app" to open POSIX file (item 1 of argv)\nend run',w1)
wid=run('on run argv\ntell application "/Applications/QLab.app"\nset w to item 1 of (every workspace whose path is item 1 of argv)\nreturn unique id of w\nend tell\nend run',w1)
run(scripts['openReceived'],wid,w2,received)
assert run(scripts['idle'],wid)==str(w2)
print('PASS: openReceived switches an existing received copy to exact new path',flush=True)
cues=run('''on run argv
 tell application "/Applications/QLab.app"
  set w to item 1 of (every workspace whose unique id is item 1 of argv)
  set a to item 1 of (every cue of w whose q number is "1")
  set b to item 1 of (every cue of w whose q number is "1.5")
  return (uniqueID of a) & tab & (uniqueID of b)
 end tell
end run''',wid).split('\t')
for c in cues: run(scripts['relink'],wid,w2,c,media/cake.name)
run(scripts['saveExpected'],wid,w2)
for c in cues: run(scripts['verifyTargets'],wid,w2,c,media/cake.name)
print('PASS: both Cake targets relinked and read back from real QLab',flush=True)
# A silent Wait cue permits real GO tests without playing the show or audio.
waitid=run('''on run argv
 tell application "/Applications/QLab.app"
  set w to item 1 of (every workspace whose unique id is item 1 of argv)
  make w type "Wait"
  set c to last item of (every cue of w whose q type is "Wait")
  set q name of c to "Silent Build55 GO Test"
  set duration of c to 30
  save w
  return uniqueID of c
 end tell
end run''',wid)
info={'id':wid,'path':str(w2),'cues':cues,'wait':waitid,'cake':str(media/cake.name),'originalCake':str(cake),'originalHash':hashlib.sha256(cake.read_bytes()).hexdigest(),'before':before}
(fixture/'fixture.json').write_text(json.dumps(info))
print('PASS: silent Wait fixture prepared; original workspace untouched',flush=True)
