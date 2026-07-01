import os
import re
from pathlib import Path

PROJECT = Path('ios/App/App.xcodeproj/project.pbxproj')
BUNDLE_ID = 'com.hookdeveloper.vshook'
TARGET_NAME = 'App'

team_id = os.environ.get('IOS_TEAM_ID', '').strip()
profile_uuid = os.environ.get('PROFILE_UUID', '').strip()
profile_name = os.environ.get('PROFILE_NAME', '').strip()

if not team_id:
    raise SystemExit('Falta IOS_TEAM_ID')
if not profile_uuid:
    raise SystemExit('Falta PROFILE_UUID')
if not profile_name:
    raise SystemExit('Falta PROFILE_NAME')
if not PROJECT.exists():
    raise SystemExit(f'{PROJECT} não encontrado')

text = PROJECT.read_text()

id_re = r'[A-Za-z0-9]+'

def find_object_block(src: str, object_id: str):
    pat = re.compile(r'(?m)^\s*' + re.escape(object_id) + r'\s*/\*.*?\*/\s*=\s*\{')
    m = pat.search(src)
    if not m:
        return None
    i = m.end()
    depth = 1
    j = i
    while j < len(src):
        ch = src[j]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                end = src.find(';', j)
                if end == -1:
                    end = j
                return m.start(), end + 1, src[m.start():end + 1]
        j += 1
    return None

# Localiza o target App pelo nome/productType, sem depender de posição fixa do pbxproj.
native_section = re.search(r'/\* Begin PBXNativeTarget section \*/(?P<body>.*?)/\* End PBXNativeTarget section \*/', text, re.S)
if not native_section:
    raise SystemExit('Seção PBXNativeTarget não encontrada')

app_target_id = None
for m in re.finditer(r'(?P<id>' + id_re + r')\s*/\*\s*([^*]+?)\s*\*/\s*=\s*\{(?P<block>.*?)\n\s*\};', native_section.group('body'), re.S):
    block = m.group('block')
    has_app_name = re.search(r'\bname\s*=\s*' + re.escape(TARGET_NAME) + r'\s*;', block) or re.search(r'\bproductName\s*=\s*' + re.escape(TARGET_NAME) + r'\s*;', block)
    is_app = 'com.apple.product-type.application' in block
    if has_app_name and is_app:
        app_target_id = m.group('id')
        target_block = block
        break

if not app_target_id:
    raise SystemExit(f'Target {TARGET_NAME} não encontrado')

build_list_match = re.search(r'buildConfigurationList\s*=\s*(?P<id>' + id_re + r')\s*/\*', target_block)
if not build_list_match:
    raise SystemExit('buildConfigurationList do target App não encontrado')

config_list_id = build_list_match.group('id')
config_block_tuple = find_object_block(text, config_list_id)
if not config_block_tuple:
    raise SystemExit('XCConfigurationList do target App não encontrada')

config_block = config_block_tuple[2]
configs = re.findall(r'(' + id_re + r')\s*/\*\s*([^*]+?)\s*\*/', config_block)
release_config_ids = [cid for cid, name in configs if name.strip() == 'Release']
debug_config_ids = [cid for cid, name in configs if name.strip() == 'Debug']

if not release_config_ids:
    raise SystemExit('Build configuration Release do App não encontrada')

base_settings = {
    'CODE_SIGN_STYLE': 'Manual',
    'DEVELOPMENT_TEAM': team_id,
    'PRODUCT_BUNDLE_IDENTIFIER': BUNDLE_ID,
}

release_settings = {
    **base_settings,
    'CODE_SIGN_IDENTITY': '"Apple Distribution"',
    '"CODE_SIGN_IDENTITY[sdk=iphoneos*]"': '"Apple Distribution"',
    'PROVISIONING_PROFILE': profile_uuid,
    'PROVISIONING_PROFILE_SPECIFIER': f'"{profile_name}"',
}

# Debug não recebe profile App Store; evita conflito se algum build auxiliar encostar no Debug.
debug_settings = {
    **base_settings,
}

def set_key(settings_text: str, key: str, value: str) -> str:
    line = f'\t\t\t\t{key} = {value};'
    existing = re.compile(r'^\s*' + re.escape(key) + r'\s*=\s*.*?;\s*$', re.M)
    if existing.search(settings_text):
        return existing.sub(line, settings_text)
    return settings_text.rstrip() + '\n' + line

def apply_settings(src: str, config_id: str, settings: dict) -> str:
    obj = find_object_block(src, config_id)
    if not obj:
        raise SystemExit(f'XCBuildConfiguration {config_id} não encontrada')
    start, end, full = obj
    bm = re.search(r'buildSettings\s*=\s*\{(?P<settings>.*?)\n\s*\};', full, re.S)
    if not bm:
        raise SystemExit(f'buildSettings não encontrado em {config_id}')
    settings_text = bm.group('settings')
    for key, value in settings.items():
        settings_text = set_key(settings_text, key, value)
    new_full = full[:bm.start('settings')] + settings_text + full[bm.end('settings'):]
    return src[:start] + new_full + src[end:]

for cid in release_config_ids:
    text = apply_settings(text, cid, release_settings)

for cid in debug_config_ids:
    text = apply_settings(text, cid, debug_settings)

PROJECT.write_text(text)
print(f'iOS signing configurado apenas no target App: {profile_name} ({profile_uuid})')
print(f'Target App: {app_target_id}')
print(f'Release configs: {", ".join(release_config_ids)}')
