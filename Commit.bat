@echo off
cd /d "%~dp0"

echo.
set /p msg=Mensagem do commit: 

echo.
echo Adicionando arquivos...
git add .

echo.
echo Criando commit...
git commit -m "%msg%"

echo.
echo Enviando para GitHub...
git push

echo.
echo Finalizado.
pause