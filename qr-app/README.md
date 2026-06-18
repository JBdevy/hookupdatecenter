# Botão Sair na engrenagem

Correção aplicada:
- Diretor: botão `SAIR` dentro da engrenagem volta para a tela de seleção de projeto.
- Músicos: botão `SAIR` dentro da engrenagem volta para a tela de seleção de projeto.

Tag sugerida:

```bash
git add .
git commit -m "Adiciona botao sair na engrenagem"
git push

git tag -a android-v1.0.19 -m "Botao sair na engrenagem"
git push origin android-v1.0.19
```


---

# Correção do ícone Android

Esta versão substitui o ícone padrão do Capacitor/Android pelo ícone neon do VS Hook.

Tag sugerida:

```bash
git add .
git commit -m "Corrige icone Android do VS Hook"
git push

git tag -a android-v1.0.18 -m "Corrige icone Android"
git push origin android-v1.0.18
```


---

# VS Hook Android

Atualizações:
- Busca automática de projetos VS Hook na rede Wi-Fi.
- Botão Procurar caso o projeto não esteja aberto.
- Ícone do app atualizado.
- Tela de seleção de projeto usando o novo ícone.
- Modo Diretor e Modo Músico separados.
- Botão Sair injetado nas telas de configuração/engrenagem para voltar à seleção de projeto.

Tag sugerida:

```bash
git add .
git commit -m "Ajusta busca automatica icone e sair"
git push

git tag -a android-v1.0.17 -m "Busca automatica icone e sair"
git push origin android-v1.0.17
```
