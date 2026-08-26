#!/bin/bash
#####################################################################################
#            AUTO-ENROLLMENT PATCHMON PARA CONTAINERS LXC DO PROXMOX                #
# Se você utiliza Proxmox e possui containers LXC Linux nele, esse script é para    #
# você. Ele vai descobrir automaticamente (através da cron) os containers em        #
# execução, coletar informações como hostname, IP, sistema operacional, arquitetura #
# e Machine ID e realizar o cadastro automático dos containers no PatchMon.         #
#                                                                                   #
# O script ignora containers parados e verifica se o PatchMon Agent já está         #
# instalado e executando. Caso o Agent esteja funcionando e comunicando com o       #
# PatchMon, nenhuma alteração será realizada.                                       #
#                                                                                   #
# Caso o Agent não esteja instalado, o script verifica e instala automaticamente    #
# as dependências necessárias, realiza o auto-enrollment do container no PatchMon   #
# utilizando a API de Auto-Enrollment e instala o PatchMon Agent dentro do LXC.     #
#                                                                                   #
# O script suporta diferentes sistemas de inicialização dentro dos containers,      #
# incluindo systemd, OpenRC e Supervisor. Quando não existe um sistema de           #
# inicialização compatível, o Agent pode ser iniciado diretamente pelo Proxmox      #
# como root.                                                                        #
#                                                                                   #
# Para containers que utilizam Supervisor ou não possuem um sistema de inicialização#
# compatível, o script pode criar um wrapper de manutenção em                       #
# /usr/local/sbin/patchmon-agent-wrapper, permitindo iniciar o Agent diretamente    #
# pelo Proxmox sem depender do Supervisor ou de outro serviço interno.              #
#                                                                                   #
# Dependências no Proxmox:                                                          #
#   - pct                                                                           #
#   - curl                                                                          #
#   - jq                                                                            #
#                                                                                   #
# Dependências verificadas nos containers:                                          #
#   - curl                                                                          #
#   - cron                                                                          #
#   - procps                                                                        #
#                                                                                   #
# Informações coletadas dos containers:                                             #
#   - CTID                                                                          #
#   - Hostname                                                                      #
#   - Endereço IP                                                                   #
#   - Sistema operacional                                                           #
#   - Arquitetura                                                                   #
#   - Machine ID                                                                    #
#   - Nó Proxmox                                                                    #
#                                                                                   #
# O script utiliza o Machine ID como identificador da máquina e envia informações   #
# adicionais do container como metadata para o PatchMon.                            #
#                                                                                   #
# O Friendly Name criado no PatchMon utiliza o formato:                             #
#   CT-ID-HOSTNAME                                                                  #
#                                                                                   #
# Exemplo:                                                                          #
#   CT-214-servidor-web                                                             #
#                                                                                   #
# Após o enrollment, o script verifica o Agent, inicia o serviço conforme o sistema #
# de inicialização detectado e valida se o processo está ativo.                     #
#                                                                                   #
# O script também trata containers que já estejam cadastrados no PatchMon, evitando #
# realizar um novo enrollment e criar hosts duplicados.                             #
#                                                                                   #
# Autor: Diego Costa (@diegocostaroot) / Projeto Root (youtube.com/projetoroot)     #
# Versão: 1.0                                                                       #
# 2026                                                                              #
#####################################################################################

set -u
set -o pipefail

PATCHMON_URL="IP:PORTA"
AUTO_ENROLLMENT_KEY="SUA-KEY-API"
AUTO_ENROLLMENT_SECRET="SUA-SECRET-KEY"

LOG_FILE="/var/log/patchmon-proxmox-lxc.log"

CURL_FLAGS="-s"
SKIP_STOPPED=true

exec >> "$LOG_FILE" 2>&1

echo
echo "=============================================================="
echo " PatchMon Proxmox LXC Auto-Enrollment"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="

info() {
    echo "[INFO] $*"
}

warn() {
    echo "[WARN] $*"
}

error() {
    echo "[ERROR] $*"
}

# ------------------------------------------------------------
# Verificações
# ------------------------------------------------------------

if ! command -v pct >/dev/null 2>&1; then
    error "pct não encontrado. Este script precisa rodar no Proxmox."
    exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
    error "curl não encontrado."
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    error "jq não encontrado."
    exit 1
fi

# ------------------------------------------------------------
# Funções
# ------------------------------------------------------------

container_exec() {
    local vmid="$1"
    shift

    pct exec "$vmid" -- "$@"
}

container_has_agent() {
    local vmid="$1"

    pct exec "$vmid" -- test -x /usr/local/bin/patchmon-agent \
        >/dev/null 2>&1
}

container_agent_running() {
    local vmid="$1"

    pct exec "$vmid" -- sh -c \
        'pgrep -x patchmon-agent >/dev/null 2>&1'
}

container_init() {
    local vmid="$1"

    pct exec "$vmid" -- sh -c '
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
            echo systemd
            exit
        fi

        if command -v rc-service >/dev/null 2>&1; then
            echo openrc
            exit
        fi

        if command -v supervisorctl >/dev/null 2>&1; then
            echo supervisor
            exit
        fi

        if command -v supervisord >/dev/null 2>&1; then
            echo supervisor
            exit
        fi

        echo none
    ' 2>/dev/null || echo unknown
}

install_cron_if_needed() {
    local vmid="$1"

    if pct exec "$vmid" -- sh -c \
        'command -v crond >/dev/null 2>&1 || command -v cron >/dev/null 2>&1 || command -v crontab >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando cron no CT $vmid..."

    pct exec "$vmid" -- sh -c '
        export DEBIAN_FRONTEND=noninteractive

        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq &&
            apt-get install -y -qq cron
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache dcron
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y cronie
        elif command -v yum >/dev/null 2>&1; then
            yum install -y cronie
        else
            exit 1
        fi
    ' >/dev/null 2>&1

    return $?
}

install_curl_if_needed() {
    local vmid="$1"

    if pct exec "$vmid" -- sh -c \
        'command -v curl >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando curl no CT $vmid..."

    pct exec "$vmid" -- sh -c '
        export DEBIAN_FRONTEND=noninteractive

        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq &&
            apt-get install -y -qq curl
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache curl
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y curl
        elif command -v yum >/dev/null 2>&1; then
            yum install -y curl
        else
            exit 1
        fi
    ' >/dev/null 2>&1

    return $?
}

install_procps_if_needed() {
    local vmid="$1"

    if pct exec "$vmid" -- sh -c \
        'command -v pgrep >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando procps no CT $vmid..."

    pct exec "$vmid" -- sh -c '
        export DEBIAN_FRONTEND=noninteractive

        if command -v apt-get >/dev/null 2>&1; then
            apt-get update -qq &&
            apt-get install -y -qq procps
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache procps
        elif command -v dnf >/dev/null 2>&1; then
            dnf install -y procps-ng
        elif command -v yum >/dev/null 2>&1; then
            yum install -y procps-ng
        else
            exit 1
        fi
    ' >/dev/null 2>&1

    return $?
}

configure_proxmox_wrapper() {
    local vmid="$1"

    info "  Configurando wrapper de manutenção..."

    pct exec "$vmid" -- sh -c '
        cat > /usr/local/sbin/patchmon-agent-wrapper <<'"'"'WRAPPER'"'"'
#!/bin/sh

AGENT="/usr/local/bin/patchmon-agent"
LOG="/var/log/patchmon-agent-wrapper.log"

if [ ! -x "$AGENT" ]; then
    exit 1
fi

if pgrep -x patchmon-agent >/dev/null 2>&1; then
    exit 0
fi

echo "$(date "+%Y-%m-%d %H:%M:%S") Starting PatchMon Agent" >> "$LOG"

nohup "$AGENT" serve >> /var/log/patchmon-agent.log 2>&1 &

exit 0
WRAPPER

        chmod 700 /usr/local/sbin/patchmon-agent-wrapper
    '

    return $?
}

start_agent_from_proxmox() {
    local vmid="$1"

    info "  Iniciando PatchMon Agent como root..."

    pct exec "$vmid" -- sh -c '
        if pgrep -x patchmon-agent >/dev/null 2>&1; then
            exit 0
        fi

        nohup /usr/local/bin/patchmon-agent serve \
            >> /var/log/patchmon-agent.log 2>&1 &
    '

    sleep 2

    if container_agent_running "$vmid"; then
        info "  ✓ PatchMon Agent está executando"
        return 0
    fi

    warn "  ✗ PatchMon Agent não iniciou"
    return 1
}

install_agent() {
    local vmid="$1"
    local api_id="$2"
    local api_key="$3"
    local architecture="$4"

    local install_url
    local result
    local rc

    install_url="$PATCHMON_URL/api/v1/hosts/install?arch=$architecture"

    info "  Instalando PatchMon Agent..."

    result=$(timeout 180 pct exec "$vmid" -- sh -c "
        cd /tmp || exit 1

        curl -s \
            -H 'X-API-ID: $api_id' \
            -H 'X-API-KEY: $api_key' \
            -o patchmon-install.sh \
            '$install_url' || exit 1

        chmod +x patchmon-install.sh

        sh patchmon-install.sh

        rc=\$?

        rm -f patchmon-install.sh

        exit \$rc
    " 2>&1)

    rc=$?

    echo "$result"

    if [ "$rc" -eq 0 ]; then
        info "  ✓ Instalação concluída"
        return 0
    fi

    # --------------------------------------------------------
    # O instalador pode falhar somente ao configurar systemd.
    # Verificamos se o Agent foi realmente instalado.
    # --------------------------------------------------------

    if pct exec "$vmid" -- test -x /usr/local/bin/patchmon-agent \
        >/dev/null 2>&1; then

        info "  ✓ PatchMon Agent foi instalado."
        info "  ⚠ Instalação do serviço systemd falhou, mas o binário está disponível."
        info "  Continuando para inicialização manual do Agent..."

        return 0
    fi

    warn "  ✗ Falha na instalação. Código: $rc"
    return 1
}

enroll_container() {
    local vmid="$1"
    local hostname="$2"
    local ip="$3"
    local os="$4"
    local architecture="$5"
    local machine_id="$6"

    local friendly_name
    local response
    local body
    local http_code
    local api_id
    local api_key

    # Friendly Name no PatchMon
    # Exemplo: CT-214-hhh
    friendly_name="CT-${vmid}-${hostname}"

    info "  Fazendo enrollment no PatchMon..."
    info "  Friendly Name: $friendly_name"

    response=$(curl $CURL_FLAGS \
        -X POST \
        -H "X-Auto-Enrollment-Key: $AUTO_ENROLLMENT_KEY" \
        -H "X-Auto-Enrollment-Secret: $AUTO_ENROLLMENT_SECRET" \
        -H "Content-Type: application/json" \
        -d "{
            \"friendly_name\": \"$friendly_name\",
            \"machine_id\": \"$machine_id\",
            \"metadata\": {
                \"vmid\": \"$vmid\",
                \"proxmox_node\": \"$(hostname)\",
                \"ip_address\": \"$ip\",
                \"os_info\": \"$os\"
            }
        }" \
        "$PATCHMON_URL/api/v1/auto-enrollment/enroll" \
        -w "\n%{http_code}" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | sed '$d')

    case "$http_code" in

        201)
            api_id=$(echo "$body" | jq -r '.host.api_id // empty')
            api_key=$(echo "$body" | jq -r '.host.api_key // empty')

            if [ -z "$api_id" ] || [ -z "$api_key" ]; then
                warn "  Enrollment retornou credenciais inválidas."
                return 1
            fi

            info "  ✓ Host criado no PatchMon: $api_id"
            info "  ✓ Friendly Name: $friendly_name"

            install_agent "$vmid" "$api_id" "$api_key" "$architecture"
            return $?

            ;;

        409)
            info "  Host já está cadastrado no PatchMon."
            return 2
            ;;

        *)
            warn "  Enrollment falhou. HTTP $http_code"
            echo "$body"
            return 1
            ;;
    esac
}


# ------------------------------------------------------------
# Descoberta dos containers
# ------------------------------------------------------------

info "Descobrindo LXC..."

lxc_list=$(pct list | tail -n +2)

if [ -z "$lxc_list" ]; then
    info "Nenhum LXC encontrado."
    exit 0
fi

while IFS= read -r line; do

    [ -z "$line" ] && continue

    vmid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    name=$(echo "$line" | awk '{print $3}')

    echo
    info "=========================================================="
    info "CT $vmid - $name - $status"
    info "=========================================================="

    if [ "$status" != "running" ]; then
        info "Container parado. Ignorando."
        continue
    fi

    # --------------------------------------------------------
    # Informações do container
    # --------------------------------------------------------

    hostname=$(pct exec "$vmid" -- hostname 2>/dev/null || echo "$name")

    ip_address=$(pct exec "$vmid" -- hostname -I 2>/dev/null |
        awk '{print $1}' || echo "unknown")

    os_info=$(pct exec "$vmid" -- sh -c \
        'grep "^PRETTY_NAME=" /etc/os-release 2>/dev/null |
        cut -d"\"" -f2' 2>/dev/null || echo "unknown")

    arch_raw=$(pct exec "$vmid" -- uname -m 2>/dev/null || echo "unknown")

    case "$arch_raw" in
        x86_64)
            architecture="amd64"
            ;;
        aarch64|arm64)
            architecture="arm64"
            ;;
        armv7l|armv6l)
            architecture="arm"
            ;;
        i386|i686)
            architecture="386"
            ;;
        *)
            architecture="amd64"
            ;;
    esac

    machine_id=$(pct exec "$vmid" -- sh -c '
        if [ -f /etc/machine-id ]; then
            cat /etc/machine-id
        elif [ -f /var/lib/dbus/machine-id ]; then
            cat /var/lib/dbus/machine-id
        else
            echo "proxmox-lxc-'"$vmid"'"
        fi
    ' 2>/dev/null)

    info "Hostname: $hostname"
    info "IP: $ip_address"
    info "OS: $os_info"
    info "Arquitetura: $architecture"
    info "Machine ID: ${machine_id:0:16}..."

    # --------------------------------------------------------
    # Agent já instalado?
    # --------------------------------------------------------

    if container_has_agent "$vmid"; then

        info "PatchMon Agent já está instalado."

        if container_agent_running "$vmid"; then
            info "✓ Agent está ativo."

            # Teste de comunicação
            if pct exec "$vmid" -- \
                /usr/local/bin/patchmon-agent ping >/dev/null 2>&1; then
                info "✓ Agent comunicando com PatchMon."
                continue
            else
                warn "Agent existe, mas ping falhou."
            fi

        else
            warn "Agent instalado, mas não está executando."

            init_type=$(container_init "$vmid")

            info "Sistema de inicialização detectado: $init_type"

            case "$init_type" in

                systemd)
                    pct exec "$vmid" -- \
                        systemctl restart patchmon-agent 2>/dev/null || true
                    ;;

                openrc)
                    pct exec "$vmid" -- \
                        rc-service patchmon-agent restart 2>/dev/null || true
                    ;;

                supervisor)
                    # Não tentamos iniciar como www-data.
                    # O Proxmox executa o agente diretamente como root.
                    start_agent_from_proxmox "$vmid"
                    ;;

                none|unknown)
                    start_agent_from_proxmox "$vmid"
                    ;;

            esac

            sleep 2

            if container_agent_running "$vmid"; then
                info "✓ Agent iniciado."
            else
                warn "✗ Não foi possível iniciar o Agent."
            fi

        fi

        continue
    fi

    # --------------------------------------------------------
    # Agent não instalado
    # --------------------------------------------------------

    info "PatchMon Agent não encontrado."

    # --------------------------------------------------------
    # Dependências do container
    # --------------------------------------------------------

    info "Verificando dependências do CT $vmid..."

    if ! install_curl_if_needed "$vmid"; then
        warn "✗ Não foi possível instalar curl no CT $vmid. Ignorando."
        continue
    fi

    if ! install_cron_if_needed "$vmid"; then
        warn "✗ Não foi possível instalar cron no CT $vmid. Ignorando."
        continue
    fi

    if ! install_procps_if_needed "$vmid"; then
         warn "✗ Não foi possível instalar procps no CT $vmid. Ignorando."
         continue
    fi

    # --------------------------------------------------------
    # Enrollment
    # --------------------------------------------------------

    enroll_container \
        "$vmid" \
        "$hostname" \
        "$ip_address" \
        "$os_info" \
        "$architecture" \
        "$machine_id"

    enroll_rc=$?

    if [ "$enroll_rc" -eq 0 ]; then

        sleep 2

        # ----------------------------------------------------
        # Iniciar agente
        # ----------------------------------------------------

        init_type=$(container_init "$vmid")

        info "Sistema de inicialização detectado: $init_type"

        case "$init_type" in

            systemd)

                info "Iniciando Agent via systemd..."

                pct exec "$vmid" -- \
                    systemctl enable --now patchmon-agent \
                    2>/dev/null || true

                ;;

            openrc)

                info "Iniciando Agent via OpenRC..."

                pct exec "$vmid" -- \
                    rc-update add patchmon-agent default \
                    2>/dev/null || true

                pct exec "$vmid" -- \
                    rc-service patchmon-agent start \
                    2>/dev/null || true

                ;;

            supervisor)

                info "Supervisor detectado."

                configure_proxmox_wrapper "$vmid"
                start_agent_from_proxmox "$vmid"

                ;;

            none|unknown)

                info "Nenhum sistema de inicialização compatível."

                configure_proxmox_wrapper "$vmid"
                start_agent_from_proxmox "$vmid"

                ;;

        esac

        sleep 2

        if container_agent_running "$vmid"; then
            info "✓ CT $vmid está ativo no PatchMon."
        else
            warn "✗ CT $vmid foi cadastrado, mas Agent não está ativo."
        fi

    elif [ "$enroll_rc" -eq 2 ]; then

        info "Host já existente. Verificando Agent..."

        if container_has_agent "$vmid"; then
            start_agent_from_proxmox "$vmid" || true
        fi

    fi

done <<< "$lxc_list"

echo
info "Execução concluída."
