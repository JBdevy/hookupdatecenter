# Auditoria de áudio do CatLive 2.00

22 de novembro de 2026. Validação local no MacBook Air M1 com 8 GB. O foco foi investigar pistas que ocasionalmente ficam mudas enquanto o transporte continua andando, além das pausas percebidas em Play, seek e Stop.

## Falhas reproduzidas e corrigidas

| Caso | Reprodução | Resultado após a correção |
| --- | --- | --- |
| Muitas mídias visitadas no mesmo projeto | Com limite de 256 arquivos abertos, navegar por uma sequência de WAVs válidos de uma única pista fez o Core Audio recusar o arquivo 252. O motor mantinha os leitores de arquivos já visitados. | O cache retém até 32 leitores recentes. As pistas em uso continuam com seus próprios leitores. O teste visitou 300 caminhos e voltou ao primeiro com pico de 0,125 em 44,1 e 48 kHz. O processo usou 36 descritores na medição. |
| SubPlay durante troca de projeto | Uma leitura falhava depois que seu projeto já tinha sido fechado. Quando o projeto seguinte usava o mesmo caminho relativo, sua pista ficava em silêncio. | O motor verifica a qual projeto e preparação o resultado pertence. O arquivo saudável do segundo projeto voltou a produzir o pico esperado de 0,125 nas duas taxas. |
| Falta parcial de dados na saída | Ao receber um bloco incompleto do sistema de áudio, o motor podia descartar também amostras válidas das outras pistas. | O Mac e o Nativo preservam as amostras entregues e preenchem o restante de cada canal com silêncio. A saída do Mac passou por 4.000 chamadas com tamanhos variados, incluindo dez interrupções induzidas e recuperação. |
| Troca de dispositivo | Desconectar a saída enquanto o grafo do Mac estava sendo conectado podia encerrar o processo por uma exceção do AVFoundation. | O motor desfaz a conexão incompleta, devolve o erro e permite outra tentativa. O teste injeta a falha na conexão. No Nativo, a saída também verifica se a função de renderização está instalada antes de iniciar. |
| Troca repetida de fontes com ajuste de pitch ou tempo | Com outra pista mantendo um grupo de processamento vivo, substituir ou destruir fontes deixava reservas de memória acumuladas no grupo. | Doze ciclos de substituição e fechamento liberaram as reservas, com os sanitizadores de memória e de comportamento indefinido ativos. |
| Seek com 24 arquivos durante a reprodução | Cada salto fazia 48 leituras de áudio na fila principal. Com 3 ms extras por leitura, a interface ficava bloqueada entre 236 e 335 ms. | O pedido de salto retornou em 0,10 a 0,15 ms. As leituras foram executadas fora da fila principal e a troca do destino já preparado levou de 3,7 a 6,9 ms. A região anterior continua tocando enquanto o destino é preparado. |

Os testes de regressão estão em [PlaybackMediaCacheTests](Apple/PlaybackMediaCacheTests.swift), [SubplayMediaPreparationTests](Apple/SubplayMediaPreparationTests.swift), [LiveSeekPreparationTests](Apple/LiveSeekPreparationTests.swift), [BufferedAudioOutputTests](Apple/BufferedAudioOutputTests.mm), [MobileAudioDriverTests](Apple/MobileAudioDriverTests.mm) e [PreparedMemoryBudgetTests](Apple/PreparedMemoryBudgetTests.mm).

## Sessão real e testes de carga

- O diagnóstico da sessão anterior contém 833 amostras periódicas. Havia 16 com o transporte em reprodução e até 24 fontes simultâneas. Os contadores registraram zero faltas de dados e zero erros de renderização. O maior tempo de renderização registrado foi 12,97 ms para um bloco de produção de 2.048 amostras a 44,1 kHz. O dispositivo consumia blocos de 512 amostras. Os contadores agregados não identificam se uma pista individual foi programada.
- O teste abriu um projeto real de 58 pistas e 607 itens e capturou a saída do motor em memória. Foram seis passagens por quatro posições da mesma região, com reposicionamento e Stop. O Main teve sinal em todas. O PAD teve sinal nas quatro passagens por trechos audíveis e ficou em zero nas duas passagens pelo trecho silencioso do arquivo de origem.
- Um ensaio separado reproduziu 24 arquivos independentes, com atraso artificial de 150 ms nas leituras. Foram 400 leituras em 12 segundos, sem falta de dados. O maior erro absoluto em relação ao áudio de referência foi 4,47 × 10⁻⁸.
- Na captura de entrada, a leitura dos ponteiros e do tamanho do bloco passou a ser feita uma vez por chamada. Para 32 canais e blocos de 512 amostras, a mediana caiu de 268 para 36 µs e o percentil 95 de 371 para 47 µs. O ensaio verificou as amostras gravadas e os picos dos canais. A suíte de gravação validou 32 arquivos mono, monitoramento, mudança de pistas armadas, PCM e MP3.
- A suíte Swift registrou 1.069 testes, 12 pulados e nenhuma falha. Também passaram os testes de transporte, seek, Stop, relógio de apresentação, fila MIDI e metrônomo. Os testes portáveis do código C++ de entrada e saída rodaram no Mac com sanitizadores.
- No Nativo, o driver entregou o PCM esperado a 44,1 e 48 kHz com 2, 6, 18 e 32 canais simulados. Ao reaproveitar um grafo, ele agora verifica tipo das amostras, disposição dos canais, tamanho de bloco e modo de renderização.
- A compilação Release 2.00 do Mac gerou um executável universal para Apple Silicon e Intel. A inspeção dos binários confirmou compatibilidade declarada com macOS 12. O Nativo compilou para ARM64 com versão mínima iPadOS 16. O Android Remote compilou e passou nos 165 testes locais. A suíte do protocolo Apple Remote também passou.

## Limites da evidência

O sintoma intermitente relatado na sessão original não reapareceu no ensaio do projeto. O esgotamento de arquivos abertos pode deixar uma pista válida muda e foi demonstrado isoladamente. O registro disponível não permite atribuir o silêncio daquela sessão a uma única causa.

O salto quantizado conserva a próxima batida definida pelo transporte. Quando a preparação perde esse prazo, o agendamento ainda pode preparar a fonte na fila principal. O tempo medido para pedir um seek representa a resposta da interface. Para ouvir o novo trecho também é preciso aguardar a leitura da mídia.

O teste de saída parcial e a falha de conexão foram induzidos em processo isolado. Permanecem sem medição física nesta rodada o uso simultâneo com OBS, o desligamento do monitor USB durante um show, o Mac Intel, a saída ASIO/WASAPI do Windows e a interface de áudio do iPad.
