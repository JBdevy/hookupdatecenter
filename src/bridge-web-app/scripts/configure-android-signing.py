from pathlib import Path

path = Path('android/app/build.gradle')
if not path.exists():
    raise SystemExit('android/app/build.gradle não encontrado')

text = path.read_text()

prefix = """def keystoreProperties = new Properties()\ndef keystorePropertiesFile = rootProject.file('keystore.properties')\nif (keystorePropertiesFile.exists()) {\n    keystoreProperties.load(new FileInputStream(keystorePropertiesFile))\n}\n\n"""

if 'def keystoreProperties = new Properties()' not in text:
    text = prefix + text

start = '// VS_HOOK_SIGNING_CONFIG_START'
end = '// VS_HOOK_SIGNING_CONFIG_END'

# Remove bloco antigo, se existir.
while start in text and end in text:
    a = text.index(start)
    b = text.index(end, a) + len(end)
    text = text[:a].rstrip() + '\n' + text[b:].lstrip()

signing_block = r'''

// VS_HOOK_SIGNING_CONFIG_START
android {
    signingConfigs {
        release {
            keyAlias keystoreProperties['keyAlias']
            keyPassword keystoreProperties['keyPassword']
            storeFile file(keystoreProperties['storeFile'])
            storePassword keystoreProperties['storePassword']
        }
    }

    buildTypes {
        release {
            signingConfig signingConfigs.release
        }
    }
}
// VS_HOOK_SIGNING_CONFIG_END
'''

# Usar um segundo bloco android {} evita inserir signingConfig dentro de signingConfigs.release por engano.
text = text.rstrip() + signing_block

path.write_text(text)
print('Signing Android release configurado.')
