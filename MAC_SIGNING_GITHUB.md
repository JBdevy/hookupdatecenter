# macOS signing / notarization

Os builds macOS agora estão preparados para assinatura.

## Certificado
Use um certificado **Developer ID Application** via uma das formas abaixo:

### GitHub Actions / CI
Defina os secrets:

- `CSC_LINK`: certificado `.p12` em base64 ou link seguro
- `CSC_KEY_PASSWORD`: senha do `.p12`
- `APPLE_ID`: Apple ID
- `APPLE_APP_SPECIFIC_PASSWORD`: senha específica do app
- `APPLE_TEAM_ID`: Team ID da conta Apple

### Mac local
Instale o certificado no Keychain e rode:

```bash
npm install
npm run build:mac
```

A notarização só roda quando `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD` e `APPLE_TEAM_ID` estiverem definidos.
Sem essas variáveis, o app será apenas assinado.

## Legacy macOS 10.13+
```bash
npm run build:mac:legacy
```

## Build sem assinatura
```bash
npm run build:mac:unsigned
```
