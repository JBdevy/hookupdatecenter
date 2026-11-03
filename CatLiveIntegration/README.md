# CatLive Integration 1.26

Aplicativo receptor para Windows 10/11 (x64) e macOS 12 ou posterior (Intel e Apple Silicon). Recebe o transporte do CatLive 1.26 por rede local e envia OSC para o Resolume Arena e MIDI Time Code de 30 FPS para o grandMA2. Não abre dispositivos de áudio. Instalação independente, gratuita, sem conta, licença ou ativação.

## Usar em dois computadores

1. Ligue os computadores por Ethernet, diretamente ou pelo mesmo switch. Os endereços IPv4 precisam pertencer à mesma rede. Acesso à internet não é necessário.
2. No computador que roda o Resolume/grandMA2, abra **CatLive Integration**, escolha o adaptador RJ45 e clique **Iniciar conexão**. Permita acesso à rede local se o sistema solicitar. A janela mostra o IP e a porta TCP 48726.
3. No computador principal, abra **Resolume** no CatLive, marque **CatLive Integration**, informe esse IP e clique **Conectar / atualizar MIDI**. Selecione as funções e aplique. As configurações pertencem ao projeto.
4. Para Resolume, habilite **OSC Input** na porta 7000 e **Webserver** na porta 8080 nas preferências do Arena. Essas portas podem ser ajustadas no CatLive. Marque **Acompanhar o transporte**.
5. Para grandMA2, marque **Enviar MTC para grandMA2** e escolha uma saída MIDI do **computador receptor**. No Windows, crie uma porta virtual chamada `CatLive Integration` no loopMIDI, ou escolha uma interface MIDI existente; selecione essa entrada nas opções MIDI do grandMA2 onPC e habilite o slot MTC do seu show. O Mac cria uma fonte CoreMIDI virtual automaticamente ou usa uma saída física escolhida. O grandMA2 onPC continua dependendo do sistema compatível com esse programa; o Integration para Mac também pode enviar MIDI a uma mesa/interface externa.

O mapa/show do grandMA2 precisa estar importado e configurado como na integração existente. Este aplicativo transmite MTC; não substitui a importação do show ou as exigências de hardware/licença da MA Lighting.

## Criar os macros grandMA2 a partir do Mac

No CatLive para Mac, abra **grandMA2** na barra de transporte. Informe o IP do Integration, selecione a saída MIDI do receptor e as músicas. A configuração avançada permite escolher os números iniciais de Sequence, página, executor, timecode e slot MTC.

Com o transporte parado, clique **Criar macros grandMA2**. O Integration gera uma nova pasta dentro de `Documentos/CatLive Integration/grandMA2/`, no computador receptor. Ela contém `macros`, `import`, o mapa CSV e as instruções. Copie os arquivos para os diretórios correspondentes do grandMA2, importe o macro **Importar tudo** e execute-o uma vez. A geração não depende de ter o grandMA2 instalado; a importação e a execução acontecem nele depois.

O mapa e a conexão ficam no projeto CatLive. Os números já atribuídos permanecem estáveis quando outras músicas são adicionadas. A exportação parcial mantém os eventos de desligamento nas entradas das demais músicas.

## Criar a composição do Resolume no receptor

Com o transporte parado, salve o trabalho no Resolume e abra uma composição nova e vazia. No CatLive, crie/atualize o mapa e clique **Criar projeto Resolume**. O Integration usa a API local do Arena 7.22+ para criar um deck por música e as colunas dos marcadores. O arquivo `.avc` fica em:

`Documentos/CatLive Integration/Resolume/`

A confirmação no CatLive informa o caminho no receptor. Coloque os vídeos nas colunas geradas. O sistema recusa uma composição com mídia, e não transfere os vídeos do computador principal.

## Conexão e limites

- Um CatLive por receptor. Outro remetente recebe aviso de conexão ocupada.
- Uma sessão usa um token aleatório e fica vinculada ao IP do remetente. A rede deve ser privada/confiável: este protocolo LAN usa HTTP, não TLS.
- As mensagens são numeradas; estados antigos são ignorados. A falta de atualização por 500 ms pausa o OSC e interrompe o MTC contínuo. O CatLive tenta reconectar após falhas.
- O envio roda fora do callback de áudio. OSC, MTC e criação do projeto usam workers separados no receptor.
- A criação usa apenas o Resolume local (`127.0.0.1`) e um diretório controlado pelo receptor. Não há execução remota de comandos nem caminhos arbitrários enviados pelo CatLive.
- A interface respeita DPI do Windows e não usa JUCE. O CatLive principal conserva sua interface atual.

## Compilar e verificar

```sh
cmake -S CatLiveIntegration -B integration-build -DCMAKE_BUILD_TYPE=Release
cmake --build integration-build --config Release
ctest --test-dir integration-build -C Release --output-on-failure
cd integration-build
cpack -C Release
```

No Mac, acrescente `-DCMAKE_OSX_ARCHITECTURES='arm64;x86_64'` para gerar Universal. No Windows, use Visual Studio 2022 com C++ e `-A x64` na configuração. O workflow gera instaladores separados: `.exe` no Windows e `.pkg` assinado/notarizado no Mac. O instalador Windows não usa Authenticode. Os ZIPs adicionais servem para validação técnica.

Os testes exercitam HTTP real, sessão única, reconexão, rejeição de estados antigos, timeout, OSC real por UDP, criação local usando uma API Arena simulada e proteção de composições existentes. No Mac também capturam MIDI real através de uma porta CoreMIDI de teste. A validação final com Arena e grandMA2 físicos deve ser feita no ambiente de palco.
