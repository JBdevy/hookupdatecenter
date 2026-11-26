#!/bin/bash
set -eu
umask 077
collector_dir="$(cd "$(dirname "$0")" && pwd)"
collector="$collector_dir/audio-device-snapshot"
if [[ ! -x "$collector" ]]; then
    printf 'Falta o arquivo audio-device-snapshot. Extraia a pasta completa antes de abrir.\n'
    read -r -p 'Pressione Enter para fechar...' || true
    exit 1
fi
printf 'CATLIVE — DIAGNÓSTICO DE ÁUDIO\n\n'
printf 'Mantenha o CatLive tocando o mesmo projeto, com a SSL selecionada no app.\n'
printf 'A coleta lê buffer, taxa, memória, uso dos processos e avisos do Core Audio.\n'
printf 'Cada etapa dura 30 segundos. As configurações são alteradas manualmente por você.\n\n'
report_dir="$(mktemp -d "$HOME/Downloads/CatLive-audio-$(date +%Y%m%d-%H%M%S).XXXXXX")"
children=()
cleanup() {
    # macOS ships Bash 3.2: empty arrays need this form with nounset enabled.
    for pid in ${children[@]+"${children[@]}"}; do kill "$pid" 2>/dev/null || true; done
    for pid in ${children[@]+"${children[@]}"}; do wait "$pid" 2>/dev/null || true; done
    children=()
}
trap cleanup EXIT
trap 'exit 130' INT TERM
{
    /usr/bin/sw_vers
    /usr/sbin/sysctl hw.model hw.physicalcpu hw.logicalcpu hw.memsize
    /usr/bin/uname -m
    for bundle in /Applications/CatLive.app "$HOME/Applications/CatLive.app"; do
        if [[ -f "$bundle/Contents/Info.plist" ]]; then
            printf '\nCatLive instalado:\n'
            /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist"
            /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist"
        fi
    done
} > "$report_dir/sistema.txt" 2>&1 || true

collect_stage() {
    local label="$1"
    printf '\nColetando por 30 segundos: %s\n' "$label"
    "$collector" 30 > "$report_dir/$label-dispositivo.jsonl" 2> "$report_dir/$label-dispositivo-erros.txt" &
    children+=("$!")
    /usr/bin/log stream --style compact --level info --timeout 30 \
        --predicate 'process == "coreaudiod" AND (eventMessage CONTAINS[c] "overload" OR eventMessage CONTAINS[c] "underrun" OR eventMessage CONTAINS[c] "buffer" OR eventMessage CONTAINS[c] "sample rate" OR eventMessage CONTAINS[c] "skipping cycle")' \
        > "$report_dir/$label-coreaudio.txt" 2>&1 &
    children+=("$!")
    for ((sample=0; sample<15; sample++)); do
        {
            /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
            /bin/ps -axo pid=,pcpu=,rss=,comm= | /usr/bin/awk \
                '/CatLive|Safari|WebKit|coreaudiod|WindowServer/ { n=split($0,path,"/"); print $1, $2, $3, path[n] }'
            /usr/bin/vm_stat
            /usr/sbin/sysctl vm.swapusage
        } >> "$report_dir/$label-recursos.txt" 2>&1 || true
        /bin/sleep 2
    done
    wait "${children[0]}" || printf 'A leitura do dispositivo falhou; o erro ficou registrado.\n'
    children=("${children[1]}")
    cleanup
    read -r -p 'O áudio picotou nesta etapa? (sim/nao): ' answer || answer='sem resposta'
    printf '%s: %s\n' "$label" "$answer" >> "$report_dir/observacoes.txt"
}

printf 'ETAPA 1: Em Som → Saída do macOS, selecione a SSL. Feche o Safari com Cmd+Q.\n'
read -r -p 'Com o CatLive tocando, pressione Enter...' || exit 130
collect_stage '1-ssl-safari-fechado'
printf '\nETAPA 2: Abra o Safari no site de letras usado quando acontece o problema.\n'
read -r -p 'Deixe o CatLive tocando e pressione Enter...' || exit 130
collect_stage '2-ssl-safari-aberto'
printf '\nETAPA 3: Mantenha o Safari aberto e selecione Alto-falantes internos na saída do macOS.\n'
printf 'Mantenha a SSL selecionada no CatLive.\n'
read -r -p 'Pressione Enter para a última etapa...' || exit 130
collect_stage '3-interno-safari-aberto'
report_zip="$report_dir.zip"
/usr/bin/ditto -c -k --keepParent "$report_dir" "$report_zip"
printf '\nConcluído. Envie este ZIP para análise:\n%s\n\n' "$report_zip"
/usr/bin/open -R "$report_zip" || true
read -r -p 'Pressione Enter para fechar...' || true
