# Funções comuns aos wrappers de npm/pnpm/docker (sourced, não executável).
# Injetam GITHUB_TOKEN (token só de leitura do GitHub Packages, secret
# gh_packages_token) apenas nos comandos que baixam pacotes ou fazem build.

TOKEN_FILE=/run/secrets/gh_packages_token

export_pkg_token() {
    if [ -z "${GITHUB_TOKEN:-}" ] && [ -s "$TOKEN_FILE" ]; then
        GITHUB_TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
        export GITHUB_TOKEN
    fi
}

# Imprime os $1 primeiros argumentos posicionais (os subcomandos), separados
# por espaço. Pula flags e o valor das flags listadas em $VALUE_FLAGS, para
# reconhecer o subcomando também depois de flags (ex.: `pnpm -C dir install`).
subcommands() {
    max=$1
    shift
    out=""
    n=0
    skip=0
    for a in "$@"; do
        if [ "$skip" = 1 ]; then
            skip=0
            continue
        fi
        case "$a" in
            --) break ;;
            --*=*) continue ;;
            -*)
                case " $VALUE_FLAGS " in *" $a "*) skip=1 ;; esac
                continue
                ;;
        esac
        out="$out $a"
        n=$((n + 1))
        [ "$n" -ge "$max" ] && break
    done
    printf '%s\n' "${out# }"
}
