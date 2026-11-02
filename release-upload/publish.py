from pathlib import Path
import subprocess,json,hashlib
def upload_source(path):
    return subprocess.check_output(['git','show','origin/publish/v0.1.26:release-upload/'+path])
manifest=json.loads(upload_source('manifest.json'))
subprocess.run(['git','fetch','--depth=1','https://gitee.com/yangxiaoyong01/CodexHarbor.git','release-assets:refs/remotes/gitee/release-assets'],check=True)
gitee_head=subprocess.check_output(['git','rev-parse','refs/remotes/gitee/release-assets'],text=True).strip()
assert gitee_head == manifest['giteeCommit'], 'Gitee release changed during publication'
def gitee_file(path):
    return subprocess.check_output(['git','show',gitee_head+':'+path])
dmg=gitee_file('latest/Codex-Harbor-arm64.dmg')
assert len(dmg) == manifest['size']
assert hashlib.sha256(dmg).hexdigest() == manifest['sha256']
Path('latest').mkdir(exist_ok=True)
Path('v0.1.26').mkdir(exist_ok=True)
Path('latest/Codex-Harbor-arm64.dmg').write_bytes(dmg)
Path('v0.1.26/Codex-Harbor-v0.1.26-arm64.dmg').write_bytes(dmg)
for destination in ['INSTALLER.md','SHA256SUMS','latest/build-info.json','v0.1.26/SHA256SUMS']:
    Path(destination).write_bytes(gitee_file(destination))
print('Installer SHA-256 verified:',manifest['sha256'])
