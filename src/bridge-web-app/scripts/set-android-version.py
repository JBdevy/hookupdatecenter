from pathlib import Path
import argparse
import re

parser = argparse.ArgumentParser()
parser.add_argument('--version-name', required=True)
parser.add_argument('--version-code', required=True)
args = parser.parse_args()

gradle = Path('android/app/build.gradle')
if not gradle.exists():
    raise SystemExit('android/app/build.gradle não encontrado')

text = gradle.read_text()
text = re.sub(r'versionCode\s+\d+', f'versionCode {int(args.version_code)}', text)
text = re.sub(r'versionName\s+["\'][^"\']+["\']', f'versionName "{args.version_name}"', text)
gradle.write_text(text)
print(f'Android version atualizado: {args.version_name} ({args.version_code})')
