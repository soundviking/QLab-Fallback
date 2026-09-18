import copy, plistlib, subprocess, sys, tempfile
from pathlib import Path
U = plistlib.UID

def archive(objects, root=1):
    return {'$archiver': 'NSKeyedArchiver', '$version': 100000, '$objects': objects, '$top': {'root': U(root)}}

def dump(a):
    return plistlib.dumps(a, fmt=plistlib.FMT_BINARY)

cue = archive(['$null', {'name': U(2), 'duration': 30, 'expanded': True, 'parent': U(1)}, 'Silent Wait'])
base = archive(['$null', {'NS.keys': [U(2), U(3), U(4)], 'NS.objects': [U(5), U(6), U(7)]},
                'controller', 'cueLists', 'settings', {'playhead': 'A'}, {'NS.data': dump(cue)},
                {'volume': -6, 'muteChannels': [1], '$class': U(8)}, {'$classname': 'AudioOutputPatch'}])
checks = 0
with tempfile.TemporaryDirectory(prefix='qlab59-signature-') as temp:
    def signature(a):
        p = Path(temp) / 'test.qlab5'; p.write_bytes(dump(a))
        return subprocess.check_output([sys.argv[1], str(p)], text=True).strip()
    original = signature(base)
    def check(a, equal, label):
        global checks
        assert (signature(a) == original) == equal, label
        checks += 1; print('PASS: ' + label)
    changed = copy.deepcopy(base); changed['$objects'][5]['playhead'] = 'B'
    check(changed, True, 'Controller/playhead changes preserve cue signature')
    changed = copy.deepcopy(base); changed['$objects'][7]['muteChannels'] = [1, 2]
    check(changed, True, 'Owned audio isolation does not invalidate content')
    changed = copy.deepcopy(base); changed['$objects'][7]['volume'] = -12
    check(changed, False, 'Real audio level edits invalidate signature')
    changed = copy.deepcopy(base); c = copy.deepcopy(cue); c['$objects'][1]['duration'] = 15; changed['$objects'][6]['NS.data'] = dump(c)
    check(changed, False, 'Nested cue duration edit is detected')
    changed = copy.deepcopy(base); c = copy.deepcopy(cue); c['$objects'][1]['expanded'] = False; changed['$objects'][6]['NS.data'] = dump(c)
    check(changed, True, 'Nested cue expansion remains presentation-only')
    changed = copy.deepcopy(base); c = copy.deepcopy(cue); c['$objects'][1]['fileTarget'] = 'different.wav'; changed['$objects'][6]['NS.data'] = dump(c)
    check(changed, False, 'Media target edits are detected')
    if len(sys.argv) > 2:
        base = plistlib.loads(Path(sys.argv[2]).read_bytes()); original = signature(base)
        o = base['$objects']; root = o[base['$top']['root'].data]
        pairs = {o[k.data]: v.data for k, v in zip(root['NS.keys'], root['NS.objects'])}
        changed = copy.deepcopy(base); changed['$objects'][pairs['controller']] = {'playhead': 'new-selection'}
        check(changed, True, 'Real QLab archive controller changes preserve signature')
        changed = copy.deepcopy(base); index = pairs['cueLists']; nested = plistlib.loads(o[index]['NS.data'])
        nested['$objects'][nested['$top']['root'].data]['preWait'] = 7
        changed['$objects'][index]['NS.data'] = dump(nested)
        check(changed, False, 'Real QLab archive cue edit invalidates signature')
print(f'PASS: {checks} workspace signature checks')
