# Assinatura e notarização macOS - Hook Center

Este projeto já está preparado para assinar e notarizar o Hook Center no GitHub Actions.

## O que precisa ser assinado

1. `Hook Center.app` por dentro, usando `Developer ID Application`.
2. `Hook-Center-*-macOS.dmg` como artefato final.
3. `Hook-Center-*-macOS.pkg` como artefato final, usando também `Developer ID Installer` quando o alvo `pkg` for gerado.
4. O `.zip` do auto-update não recebe `stapler`, mas ele é gerado depois do `.app` já estar assinado e stapled.

## Secrets necessários no GitHub

Configure em `Settings > Secrets and variables > Actions > New repository secret`:

- `MACOS_CERT_P12_BASE64`
- `MACOS_CERT_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

## Certificado P12

No Mac, instale no Acesso às Chaves:

- `Developer ID Application`
- `Developer ID Installer`

Depois exporte os certificados com as chaves privadas para um único `.p12` e converta para base64:

```bash
base64 -i HookDeveloperDeveloperID.p12 | pbcopy
```

Cole o conteúdo copiado no secret `MACOS_CERT_P12_BASE64`.

## Build no GitHub

O workflow dispara com tags:

```bash
git tag hook-update-1.8.1
git push origin hook-update-1.8.1
```

O job macOS irá:

1. importar o certificado via `CSC_LINK`;
2. assinar o `.app` com hardened runtime;
3. notarizar e staplear o `.app` antes de gerar DMG/PKG/ZIP;
4. notarizar e staplear o `.dmg` e o `.pkg` finais;
5. publicar tudo no Release.
