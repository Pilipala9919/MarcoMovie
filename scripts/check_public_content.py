"""Check tracked/public source scope. This is a guardrail, not a secret scanner guarantee."""
from pathlib import Path
import re, subprocess, sys, hashlib

ROOT=Path(__file__).resolve().parents[1]
EXCLUDED={'.git','private','tools','dist','build','__pycache__','lib','classes'}
ALLOWED_HOSTS={'github.com','raw.githubusercontent.com','chromium.googlesource.com','android.googlesource.com','ffmpeg.org','trac.ffmpeg.org','dl.google.com','repo.maven.apache.org',
 'dl.frostwire.com','schemas.android.com','maven.apache.org','www.apache.org','www.boost.org',
 'www.unicode.org','unicode.org','opensource.org','jsoup.org','developer.mozilla.org',
 'perfectionkills.com','www.engr.mun.ca','android.git.kernel.org','fsf.org','www.gnu.org',
 'gnu.org','www.fsf.org','127.0.0.1','localhost','…','x'}

def paths():
    if (ROOT/'.git').exists():
        result=subprocess.run(['git','ls-files','-z'],cwd=ROOT,check=True,capture_output=True)
        return [ROOT/p for p in result.stdout.decode('utf-8').split('\0') if p]
    return [p for p in ROOT.rglob('*') if p.is_file() and not any(
        part in EXCLUDED or part.endswith(('-classes','-compile')) for part in p.relative_to(ROOT).parts)
        and not p.name.endswith('results.txt')]

issues=[];files=paths()
for p in files:
    relative=p.relative_to(ROOT)
    # Exact reviewed, owner-supplied brand asset; all other videos remain excluded.
    if relative.as_posix()=='android/src/main/assets/branding/startup.mp4':
        if hashlib.sha256(p.read_bytes()).hexdigest()!='915d0b8e337d7980ef67f71864eed346407e0061602ca67ff3272502b5d8ec1b':issues.append(f'{relative}: unreviewed brand video')
        continue
    if any(part in EXCLUDED for part in relative.parts) or p.suffix in {'.apk','.aab','.p12','.jks','.keystore','.rar','.zip','.bin','.mp4'}:
        issues.append(f'{relative}: excluded file type/path');continue
    if p.suffix=='.png':continue
    data=p.read_bytes()
    try: text=data.decode('utf-8')
    except UnicodeDecodeError:issues.append(f'{relative}: unexpected binary');continue
    if p.name==Path(__file__).name:continue
    for pattern in [r'gh[pousr]_[A-Za-z0-9]{25,}',r'github_pat_[A-Za-z0-9_]{30,}',
                    r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
                    r'[A-Za-z]:[/\\](?:Users|TV)[/\\]',r'192\.168\.\d+\.\d+']:
        if re.search(pattern,text):issues.append(f'{relative}: private value pattern')
    for authority in re.findall(r'https?://([^/\s\"\'<>\\)]+)',text):
        host=authority.split(':')[0].lower().rstrip('.,;')
        if host not in ALLOWED_HOSTS and not host.endswith(('.test','.example','.invalid')):
            issues.append(f'{relative}: review network domain {host}')

main=(ROOT/'android/src/main/java/com/pilipala/marcomovie/MainActivity.java').read_text(encoding='utf-8')
if 'prefs.getString("origin","")' not in main:issues.append('First-run configuration address must be empty')
if '不内置、不提供、不托管' not in main:issues.append('Missing first-run tool declaration')
if issues:
    print('\n'.join(sorted(set(issues))));sys.exit(1)
print(f'PASS public file scope, address default, declaration and network/secret patterns ({len(files)} files)')
