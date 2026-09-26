# Hook Center — investigação de consumo

## Relay de sincronização sem uso (26/09/2026)

O agendador priorizava `transport.playState` antes de verificar se o relay
estava configurado. Assim, dar play no REAPER ativava polling de 20 ms até
com Timecode/Project Sync desativados. Isso ocorre nos dois sistemas, Windows
e macOS, e independe de TP, BigClock, janela principal ou app conectado.

A verificação agora ocorre antes da escolha da frequência. Sem licença,
modo válido ou código de pareamento, o relay fica em 500 ms. Com sincronização
configurada e playback/transferência ativos, continua em 20 ms. A recepção
HTTP/UDP e o funcionamento com janela fechada são preservados.

Medição isolada, servidor HTTP local simulando REAPER em playback e relay
desativado: 104 consultas em 2,209 s antes; 6 em 2,253 s depois. Redução de
94,2% das consultas nesse cenário. CPU do processo do teste: 66,489 ms antes,
31,774 ms depois; inclui inicialização e não representa o consumo total da
Hook Center nem uma medição em PC Windows fraco.

`npm run test:relay-performance` cobre relay desativado com playback, código
remanescente, pareamento, transmissão, recepção, transferência e licença.
Ainda é necessário comparar a aplicação empacotada com um projeto real no
PC que apresenta travamentos; não foi atribuída uma redução global de CPU.

## Build no Mac

Abra `build hook center.command` para validar, gerar a versão 1.0.0 e
acompanhar os instaladores Windows/macOS no GitHub. O lançador usa uma tag
única por build, sem apagar tags anteriores. Alterações do aplicativo devem
estar commitadas antes; o lançador inclui somente sua própria versão e
arquivos de pacote. `build hook keys desktop.command` é o lançador separado
do Bronze Keys, com a fonte nativa fixada pelo SHA do repositório apploja.

A verificação de integração do relay executa o módulo real contra um servidor
HTTP local por 2,2 segundos, sem janela aberta. Passou com cinco consultas
de estado; o limite do teste é oito (a versão anterior fazia cerca de cem).
