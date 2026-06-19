# Assinatura e notarização macOS - Hook Center

Este workflow foi ajustado para entregar artefatos adequados para clientes.

## Fluxo correto

1. `electron-builder` gera o app universal e assina o `.app` com `Developer ID Application`.
2. O workflow gera os arquivos finais `.dmg`, `.pkg` e `.zip`.
3. O script `build/notarize-artifacts.sh` envia apenas os artefatos finais `.dmg` e `.pkg` para a Apple.
4. Ao receber `Accepted`, o script aplica `stapler staple` e valida o ticket.

## Importante

- Para cliente final, entregue preferencialmente o `.dmg` ou `.pkg` notarizado e stapled.
- O `.zip` fica como artefato técnico/update, mas o fluxo de cliente deve usar `.dmg` ou `.pkg`.
- Se a Apple ficar em `In Progress` por muito tempo, o script falha após 45 minutos para não gastar horas de GitHub Actions.
- Se falhar por timeout, rode a tag novamente. A Apple precisa retornar `Accepted` para liberar uma versão realmente pronta para cliente.

## Secrets usados

- `MACOS_CERT_P12_BASE64`
- `MACOS_CERT_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`
