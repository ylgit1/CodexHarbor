from pathlib import Path
import subprocess,json,hashlib,shutil,tempfile
def source(path):
    return subprocess.check_output(['git','show','origin/publish/v0.1.26:release-upload/'+path])
manifest=json.loads(source('manifest.json'))
with tempfile.TemporaryDirectory() as temporary:
    dmg=Path(temporary)/'Codex-Harbor-v0.1.26-arm64.dmg'
    with dmg.open('wb') as output:
        for chunk in manifest['chunks']:
            subprocess.run(['git','show','origin/publish/v0.1.26:release-upload/chunks/'+chunk],stdout=output,check=True)
    assert dmg.stat().st_size == manifest['size']
    assert hashlib.sha256(dmg.read_bytes()).hexdigest() == manifest['sha256']
    Path('latest').mkdir(exist_ok=True)
    Path('v0.1.26').mkdir(exist_ok=True)
    shutil.copyfile(dmg,'latest/Codex-Harbor-arm64.dmg')
    shutil.copyfile(dmg,'v0.1.26/Codex-Harbor-v0.1.26-arm64.dmg')
    for destination in ['INSTALLER.md','SHA256SUMS','latest/build-info.json','v0.1.26/SHA256SUMS']:
        Path(destination).write_bytes(source('metadata/'+destination))
print('Installer SHA-256 verified:',manifest['sha256'])
