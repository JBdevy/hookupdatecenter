# macOS signing / notarization

Os builds macOS geram um instalador `.pkg` assinado e notarizado. O PKG instala
o runtime VLC, o Teleprompt Settings e os temas do REAPER antes da primeira
abertura da Hook Center.

## Certificados

São necessários dois certificados da mesma Apple Developer Team:

- **Developer ID Application**: assina a Hook Center e o Teleprompt Settings.
- **Developer ID Installer**: assina o instalador `.pkg`.

### GitHub Actions / CI
Defina os secrets:

- `MACOS_CERT_P12_BASE64`: `.p12` em base64 do **Developer ID Application**
- `MACOS_CERT_PASSWORD`: senha desse `.p12`
- `MACOS_INSTALLER_CERT_P12_BASE64`: `.p12` em base64 do **Developer ID Installer**
- `MACOS_INSTALLER_CERT_PASSWORD`: senha desse `.p12`
- `APPLE_ID`: Apple ID
- `APPLE_APP_SPECIFIC_PASSWORD`: senha específica do app
- `APPLE_TEAM_ID`: Team ID da conta Apple

### Mac local
Instale os dois certificados no Keychain e rode:

```bash
npm install
npm run build:mac
```

A notarização só roda quando `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` e `APPLE_TEAM_ID` estiverem definidos.
Sem essas variáveis, o app será apenas assinado.

O build `build:mac` gera um PKG universal único, compatível com macOS 10.13
ou superior. Não existe mais uma variante Legacy.

## Build sem assinatura
```bash
npm run build:mac:unsigned
```
