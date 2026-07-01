# VS Hook Mobile - APK, AAB e IPA

Esta versão usa o QR App como base do front, mas preserva o fluxo correto dos apps de loja.

## Fluxo preservado

- App instalado por APK/AAB/IPA: abre na tela inicial do VS Hook, procura o projeto automaticamente na rede Wi-Fi e também mostra o campo para entrar pelo IP.
- QR App aberto pelo Hook Center: carrega o projeto do Hook Center direto pelo endereço do QR.
- Depois da conexão, os três modos continuam iguais: Diretor, Músico e Recados.

A diferença é controlada em `app-shell.js`:

- `isBridgeBrowserMode()` detecta quando está no QR/Hook Center.
- Fora do QR/Hook Center, `startDiscovery()` mantém a busca automática e entrada manual por IP.

## Android

O workflow `.github/workflows/android-apk-aab.yml` gera APK e AAB.

Secrets para AAB assinado:

```txt
KEYSTORE_BASE64
KEYSTORE_PASSWORD
KEY_ALIAS
KEY_PASSWORD
```

## iOS

O workflow `.github/workflows/ios-ipa.yml` gera IPA, mas o iOS usa certificado diferente do macOS Developer ID.

Secrets necessários para IPA:

```txt
IOS_CERT_P12_BASE64
IOS_CERT_PASSWORD
IOS_PROVISION_PROFILE_BASE64
IOS_TEAM_ID
```

Observação: o certificado Developer ID usado no Hook Center macOS não serve para IPA. IPA precisa de certificado Apple Distribution e provisioning profile do bundle `com.hookdeveloper.vshook`.


## Ícone VS Hook

O workflow aplica automaticamente os ícones nativos do VS Hook no Android e no iOS após o `npx cap sync`.
