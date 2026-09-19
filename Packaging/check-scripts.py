from pathlib import Path
import re, subprocess, tempfile
source = Path('Sources/LiveMirrorQLab.swift').read_text() + '\n' + Path('Sources/RecoverySupport.swift').read_text()
with tempfile.TemporaryDirectory(prefix='qlab-build5-script-') as tmp:
    scripts = re.findall(r'static let (\w+) = """\n(.*?)\n    """', source, re.S)
    discovery = Path('Sources/QLabDiscoveryService.swift').read_text()
    discovery_script = re.search(r'MirrorQLab.run\("""\n(.*?)\n        """, \[\]\)', discovery, re.S)
    assert discovery_script, "Discovery AppleScript must be included in syntax validation"
    scripts.append(('discovery', discovery_script.group(1)))
    assert scripts
    for name, script in scripts:
        path = Path(tmp) / (name + '.applescript')
        path.write_text(script.replace('application id "com.figure53.QLab.5"', 'application "/Applications/QLab.app"'))
        subprocess.run(['/usr/bin/osacompile', '-o', str(Path(tmp) / (name + '.scpt')), str(path)], check=True)
        print(name + ': PASS (compilation dictionnaire QLab installé ; pas une exécution)')
