# Kontakt Add Libray 1.00

Aplicativo independente para macOS 12 ou posterior, Intel e Apple Silicon. Interface em SwiftUI/AppKit, sem dependências externas.

## Uso

Clique em **Add**, escolha uma pasta e confirme. O aplicativo procura `.nicnt` e `*_info.nkx` nas subpastas, mostra cada biblioteca encontrada e solicita uma única autorização do macOS para registrar o lote. Uma biblioteca inválida não interrompe as demais. **Cancelar** encerra o lote depois de concluir a gravação da biblioteca atual.

Os arquivos de áudio e os metadados originais permanecem na pasta escolhida. A importação grava o XML do Service Center e o plist da Native Instruments em `/Library`, com o `ContentDir` apontando para essa pasta. Por isso, ela precisa permanecer disponível depois da importação.

A leitura da pasta e dos metadados acontece no app, com o acesso concedido pela seleção de pasta. O helper autorizado recebe esses dados, valida o XML novamente e grava somente os registros em `/Library`; ele não precisa reabrir os arquivos originais em Documentos ou outras pastas protegidas.

Se ambos os arquivos existirem na mesma pasta, `.nicnt` tem preferência sobre `*_info.nkx`. Os registros existentes são copiados antes da atualização para `/Library/Application Support/Kontakt Add Libray/Backups/`. Campos extras do plist são preservados; falhas de gravação restauram os registros anteriores. Registros duplicados no mesmo lote são informados e ignorados depois da primeira ocorrência.

A leitura e a complementação dos campos de `ProductHints` seguem o script fornecido, incluindo os valores HU/JDX quando ambos estão ausentes. O aplicativo não modifica os arquivos `.nicnt` ou `.nkx` originais.

## Desenvolvimento

Na raiz do repositório:

```sh
swift test --package-path KontaktAddLibray --jobs 2
bash KontaktAddLibray/scripts/build-mac.sh
open 'KontaktAddLibray/build/Kontakt Add Libray.app'
```

Os testes usam somente arquivos artificiais em pastas temporárias. A build local gera um `.app` universal com assinatura ad hoc; não gera instalador nem altera bibliotecas instaladas. O helper só é executado com autorização do macOS após selecionar uma pasta com bibliotecas válidas.

## Build assinada no GitHub

O workflow **Kontakt Add Libray - signed Mac installer** é independente e iniciado manualmente, com versão padrão `1.00`. Usa os mesmos secrets de Developer ID Application, Developer ID Installer e notarização já configurados no Hook Center. Assina primeiro o helper e depois o app com hardened runtime, cria o instalador `.pkg`, envia à Apple para notarização, anexa o ticket e disponibiliza o pacote e SHA-256 como artefatos da execução.

Tags `kontakt-add-libray-vX.XX` também iniciam esse workflow. Após a assinatura e notarização, o instalador e seu SHA-256 são publicados em uma release própria, sem substituir a release mais recente do CatLive ou disparar builds de outros produtos. Uma release já existente não é sobrescrita. Os certificados são importados em um chaveiro temporário e removidos ao final.
