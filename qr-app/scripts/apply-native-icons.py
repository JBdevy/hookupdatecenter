import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
platform = sys.argv[1] if len(sys.argv) > 1 else 'all'

def copytree_contents(src: Path, dst: Path):
    if not src.exists():
        raise SystemExit(f'{src} não encontrado')
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        target = dst / item.name
        if item.is_dir():
            # Merge directories instead of replacing them. Android's res/values
            # contains strings.xml and styles.xml created by Capacitor; deleting
            # that folder breaks app_name/AppTheme resources.
            copytree_contents(item, target)
        else:
            shutil.copy2(item, target)

if platform in ('android', 'all'):
    android_res = ROOT / 'android' / 'app' / 'src' / 'main' / 'res'
    android_icons = ROOT / 'android-icons'
    if android_res.exists():
        copytree_contents(android_icons, android_res)
        print('Ícones Android VS Hook aplicados.')
    else:
        print('Android ainda não criado; pulando ícones Android.')

if platform in ('ios', 'all'):
    app_icon_dst = ROOT / 'ios' / 'App' / 'App' / 'Assets.xcassets' / 'AppIcon.appiconset'
    app_icon_src = ROOT / 'ios-icons' / 'AppIcon.appiconset'
    if app_icon_dst.parent.exists():
        if app_icon_dst.exists():
            shutil.rmtree(app_icon_dst)
        shutil.copytree(app_icon_src, app_icon_dst)
        print('Ícone iOS VS Hook aplicado no AppIcon.appiconset.')
    else:
        print('iOS ainda não criado; pulando ícone iOS.')
