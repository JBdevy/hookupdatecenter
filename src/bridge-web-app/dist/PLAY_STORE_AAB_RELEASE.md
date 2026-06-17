# Gerar AAB Release para Google Play

Este projeto agora tem um workflow separado:

`.github/workflows/android-release-aab.yml`

Ele gera o arquivo:

`VS-Hook-Android-release.aab`

## 1. Criar a keystore no seu PC

No PowerShell, dentro de qualquer pasta segura do seu computador:

```powershell
keytool -genkeypair -v -keystore vshook-upload-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias vshook
```

Use uma senha que você vai guardar. Essa senha será usada em:

- `KEYSTORE_PASSWORD`
- `KEY_PASSWORD`

O alias recomendado é:

- `vshook`

## 2. Converter a keystore para Base64

PowerShell:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("vshook-upload-key.jks")) | Set-Clipboard
```

Isso copia o conteúdo Base64 para a área de transferência.

## 3. Criar os GitHub Secrets

No repositório:

`Settings > Secrets and variables > Actions > New repository secret`

Crie estes 4 secrets:

```txt
KEYSTORE_BASE64 = cole o Base64 copiado
KEYSTORE_PASSWORD = senha da keystore
KEY_ALIAS = vshook
KEY_PASSWORD = senha da key
```

## 4. Rodar o workflow

No GitHub:

`Actions > Build VS Hook Android AAB Release > Run workflow`

Preencha:

```txt
version_name: 1.0.0
version_code: 1
```

Na próxima atualização para Google Play, aumente o version_code:

```txt
version_name: 1.0.1
version_code: 2
```

## 5. Baixar o AAB

Depois que terminar:

`Actions > execução do workflow > Artifacts > VS-Hook-Android-release-aab`

Esse é o arquivo que deve ser enviado na Play Console.

## Importante

Não envie o arquivo `vshook-upload-key.jks` para o GitHub.
Guarde esse arquivo e as senhas em local seguro. Ele será necessário para futuras atualizações do app.
