Esta pasta é a fonte única do App QR servido pelo Hook Center.

Uso local:
- rode npm start na pasta Hook center;
- edite os arquivos dentro de qr-app/;
- o QR/local server vai ler esta pasta diretamente.

Build estático:
- rode npm run build nesta pasta para regenerar dist/;
- o build do Hook Center inclui qr-app/ no pacote.

No cliente instalado:
- o QR Code usa o qr-app embutido no Hook Center instalado;
- o App QR não é mais baixado ou atualizado pelo backend.
