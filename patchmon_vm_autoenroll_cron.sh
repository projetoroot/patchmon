#!/bin/bash

set -u
set -o pipefail

PATCHMON_URL="IP:PORTA"
AUTO_ENROLLMENT_KEY="SUA-KEY-API"
AUTO_ENROLLMENT_SECRET="SUA-SECRET-KEY"

LOG_FILE="/var/log/patchmon-proxmox-vm.log"

CURL_FLAGS="-s"
SKIP_STOPPED=true

exec >> "$LOG_FILE" 2>&1

echo
echo "=============================================================="
echo " PatchMon Proxmox VM Auto-Enrollment"
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

if ! command -v qm >/dev/null 2>&1; then
    error "qm não encontrado. Este script precisa rodar no Proxmox."
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
# Execução dentro da VM
# ------------------------------------------------------------

vm_exec() {
    local vmid="$1"
    shift

    local json
    local rc
    local exitcode
    local output

    json=$(qm guest exec "$vmid" -- "$@" 2>/dev/null)
    rc=$?

    if [ "$rc" -ne 0 ]; then
        return "$rc"
    fi

    exitcode=$(echo "$json" | jq -r '.exitcode // 1' 2>/dev/null || echo 1)
    output=$(echo "$json" | jq -r '.["out-data"] // ""' 2>/dev/null || true)

    printf '%s' "$output"

    if [[ "$exitcode" =~ ^[0-9]+$ ]]; then
        return "$exitcode"
    fi

    return 1
}

# ------------------------------------------------------------
# Verificar QEMU Guest Agent
# ------------------------------------------------------------

vm_guest_agent_available() {
    local vmid="$1"

    qm agent "$vmid" ping >/dev/null 2>&1
}

# ------------------------------------------------------------
# Detectar sistema operacional da VM
#
# Retorno:
#   linux
#   windows
#   unknown
# ------------------------------------------------------------

detect_vm_os() {
    local vmid="$1"

    # --------------------------------------------------------
    # Linux
    #
    # O arquivo /etc/os-release é padrão nas distribuições
    # Linux modernas.
    # --------------------------------------------------------

    if vm_exec "$vmid" sh -c \
        'test -f /etc/os-release' \
        >/dev/null 2>&1
    then
        echo "linux"
        return 0
    fi

    # --------------------------------------------------------
    # Windows
    #
    # cmd.exe /c ver existe em Windows.
    # --------------------------------------------------------

    if vm_exec "$vmid" cmd.exe /c ver \
        >/dev/null 2>&1
    then
        echo "windows"
        return 0
    fi

    echo "unknown"
    return 0
}

# ------------------------------------------------------------
# Verificar Agent
# ------------------------------------------------------------

vm_has_agent() {
    local vmid="$1"

    vm_exec "$vmid" test -x /usr/local/bin/patchmon-agent \
        >/dev/null 2>&1
}

vm_agent_running() {
    local vmid="$1"

    vm_exec "$vmid" sh -c \
        'pgrep -x patchmon-agent >/dev/null 2>&1' \
        >/dev/null 2>&1
}

# ------------------------------------------------------------
# Instalar curl
# ------------------------------------------------------------

install_curl_if_needed() {
    local vmid="$1"

    if vm_exec "$vmid" sh -c \
        'command -v curl >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando curl na VM $vmid..."

    vm_exec "$vmid" sh -c '
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

# ------------------------------------------------------------
# Instalar cron
# ------------------------------------------------------------

install_cron_if_needed() {
    local vmid="$1"

    if vm_exec "$vmid" sh -c \
        'command -v crond >/dev/null 2>&1 ||
         command -v cron >/dev/null 2>&1 ||
         command -v crontab >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando cron na VM $vmid..."

    vm_exec "$vmid" sh -c '
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

# ------------------------------------------------------------
# Instalar procps
# ------------------------------------------------------------

install_procps_if_needed() {
    local vmid="$1"

    if vm_exec "$vmid" sh -c \
        'command -v pgrep >/dev/null 2>&1'
    then
        return 0
    fi

    info "  Instalando procps na VM $vmid..."

    vm_exec "$vmid" sh -c '
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

# ------------------------------------------------------------
# Iniciar Agent
# ------------------------------------------------------------

start_agent() {
    local vmid="$1"

    info "  Iniciando PatchMon Agent..."

    vm_exec "$vmid" systemctl enable --now patchmon-agent \
        >/dev/null 2>&1 || true

    sleep 2

    if vm_agent_running "$vmid"; then
        info "  ✓ PatchMon Agent está executando"
        return 0
    fi

    warn "  ✗ PatchMon Agent não iniciou via systemd."
    info "  Tentando iniciar Agent manualmente..."

    vm_exec "$vmid" sh -c '
        if pgrep -x patchmon-agent >/dev/null 2>&1; then
            exit 0
        fi

        nohup /usr/local/bin/patchmon-agent serve \
            >> /var/log/patchmon-agent.log 2>&1 &
    ' >/dev/null 2>&1 || true

    sleep 2

    if vm_agent_running "$vmid"; then
        info "  ✓ PatchMon Agent iniciado manualmente"
        return 0
    fi

    warn "  ✗ PatchMon Agent não iniciou"
    return 1
}

# ------------------------------------------------------------
# Instalar Agent
# ------------------------------------------------------------

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

    result=$(vm_exec "$vmid" sh -c "
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
    # O instalador pode ter instalado o binário e falhado
    # somente na configuração do serviço.
    # --------------------------------------------------------

    if vm_has_agent "$vmid"; then

        info "  ✓ PatchMon Agent foi instalado."
        info "  ⚠ O instalador retornou código $rc."
        info "  Verificando serviço manualmente..."

        return 0
    fi

    warn "  ✗ Falha na instalação. Código: $rc"
    return 1
}

# ------------------------------------------------------------
# Enrollment
# ------------------------------------------------------------

enroll_vm() {
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

    friendly_name="VM-${vmid}-${hostname}"

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
# Informações da VM
# ------------------------------------------------------------

get_vm_hostname() {
    local vmid="$1"

    vm_exec "$vmid" hostname
}

get_vm_ip() {
    local vmid="$1"
    local ips

    ips=$(vm_exec "$vmid" hostname -I 2>/dev/null || true)

    echo "$ips" |
        awk '{
            for (i=1; i<=NF; i++) {
                if ($i !~ /:/) {
                    print $i
                    exit
                }
            }
        }'
}

get_vm_os() {
    local vmid="$1"

    vm_exec "$vmid" sh -c '
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "${PRETTY_NAME:-$NAME}"
        else
            echo "unknown"
        fi
    '
}

get_vm_machine_id() {
    local vmid="$1"

    vm_exec "$vmid" sh -c '
        if [ -f /etc/machine-id ]; then
            cat /etc/machine-id

        elif [ -f /var/lib/dbus/machine-id ]; then
            cat /var/lib/dbus/machine-id

        else
            exit 1
        fi
    '
}

# ------------------------------------------------------------
# Arquitetura
# ------------------------------------------------------------

get_vm_architecture() {
    local vmid="$1"
    local arch_raw

    arch_raw=$(vm_exec "$vmid" uname -m 2>/dev/null || echo "unknown")

    case "$arch_raw" in

        x86_64)
            echo "amd64"
            ;;

        aarch64|arm64)
            echo "arm64"
            ;;

        armv7l|armv6l)
            echo "arm"
            ;;

        i386|i686)
            echo "386"
            ;;

        *)
            echo "amd64"
            ;;

    esac
}

# ------------------------------------------------------------
# Descoberta das VMs
# ------------------------------------------------------------

info "Descobrindo VMs..."

vm_list=$(qm list | tail -n +2)

if [ -z "$vm_list" ]; then
    info "Nenhuma VM encontrada."
    exit 0
fi

while IFS= read -r line; do

    [ -z "$line" ] && continue

    vmid=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $3}')
    name=$(echo "$line" | cut -d' ' -f4-)

    echo

    info "=========================================================="
    info "VM $vmid - $name - $status"
    info "=========================================================="

    # --------------------------------------------------------
    # VM parada
    # --------------------------------------------------------

    if [ "$status" != "running" ]; then

        info "VM parada. Ignorando."

        continue
    fi

    # --------------------------------------------------------
    # QEMU Guest Agent
    # --------------------------------------------------------

    if ! vm_guest_agent_available "$vmid"; then

        warn "QEMU Guest Agent não está disponível na VM $vmid."
        warn "Verifique se o agente está instalado e habilitado."

        continue
    fi

    info "✓ QEMU Guest Agent está disponível."

    # --------------------------------------------------------
    # DETECÇÃO DO SISTEMA OPERACIONAL
    #
    # IMPORTANTE:
    # A detecção acontece antes de qualquer função Linux.
    #
    # Isso impede que Windows seja submetido a:
    #
    #   sh
    #   /etc/os-release
    #   /etc/machine-id
    #   uname
    #   apt-get
    #   apk
    #   dnf
    #   yum
    #   cron
    #   procps
    #   systemctl
    #
    # --------------------------------------------------------

    guest_os=$(detect_vm_os "$vmid")

    case "$guest_os" in

        windows)

            info "✓ Windows detectado na VM $vmid."
            info "Windows não será processado pelo Auto-Enrollment Linux."
            info "VM $vmid ignorada."

            continue
            ;;

        linux)

            info "✓ Linux detectado na VM $vmid."

            ;;

        *)

            warn "Não foi possível identificar o sistema operacional da VM $vmid."
            warn "VM $vmid será ignorada."

            continue
            ;;

    esac

    # --------------------------------------------------------
    # Informações da VM
    # --------------------------------------------------------

    hostname=$(get_vm_hostname "$vmid" 2>/dev/null ||
        echo "$name")

    ip_address=$(get_vm_ip "$vmid" 2>/dev/null ||
        echo "unknown")

    os_info=$(get_vm_os "$vmid" 2>/dev/null ||
        echo "unknown")

    architecture=$(get_vm_architecture "$vmid")

    machine_id=$(get_vm_machine_id "$vmid" 2>/dev/null ||
        echo "proxmox-vm-$vmid")

    hostname=$(echo "$hostname" | tr -d '\r\n')
    ip_address=$(echo "$ip_address" | tr -d '\r\n')
    os_info=$(echo "$os_info" | tr -d '\r\n')
    machine_id=$(echo "$machine_id" | tr -d '\r\n')

    info "Hostname: $hostname"
    info "IP: $ip_address"
    info "OS: $os_info"
    info "Arquitetura: $architecture"
    info "Machine ID: ${machine_id:0:16}..."

    # --------------------------------------------------------
    # Agent já instalado?
    # --------------------------------------------------------

    if vm_has_agent "$vmid"; then

        info "PatchMon Agent já está instalado."

        # ----------------------------------------------------
        # Agent está executando
        # ----------------------------------------------------

        if vm_agent_running "$vmid"; then

            info "✓ Agent está ativo."

            # ------------------------------------------------
            # Teste de comunicação
            # ------------------------------------------------

            if vm_exec "$vmid" \
                /usr/local/bin/patchmon-agent ping \
                >/dev/null 2>&1
            then

                info "✓ Agent comunicando com PatchMon."

                continue

            else

                warn "Agent existe, mas ping falhou."
                warn "Não será realizado novo enrollment."
                warn "Tentando reiniciar o Agent..."

                start_agent "$vmid" || true

                sleep 2

                if vm_exec "$vmid" \
                    /usr/local/bin/patchmon-agent ping \
                    >/dev/null 2>&1
                then

                    info "✓ Agent voltou a comunicar com PatchMon."

                else

                    warn "✗ Agent continua sem comunicação."

                fi

                continue

            fi

        fi

        # ----------------------------------------------------
        # Agent instalado, mas parado
        # ----------------------------------------------------

        warn "Agent instalado, mas não está executando."

        start_agent "$vmid" || true

        sleep 2

        if vm_agent_running "$vmid"; then

            info "✓ Agent iniciado."

            if vm_exec "$vmid" \
                /usr/local/bin/patchmon-agent ping \
                >/dev/null 2>&1
            then

                info "✓ Agent comunicando com PatchMon."

            else

                warn "Agent iniciou, mas ping falhou."

            fi

        else

            warn "✗ Não foi possível iniciar o Agent."

        fi

        # ----------------------------------------------------
        # IMPORTANTE:
        # Não faz novo enrollment.
        # ----------------------------------------------------

        continue

    fi

    # --------------------------------------------------------
    # Agent não instalado
    # --------------------------------------------------------

    info "PatchMon Agent não encontrado."

    # --------------------------------------------------------
    # Dependências da VM
    # --------------------------------------------------------

    info "Verificando dependências da VM $vmid..."

    if ! install_curl_if_needed "$vmid"; then

        warn "✗ Não foi possível instalar curl na VM $vmid."
        warn "Ignorando VM."

        continue

    fi

    if ! install_cron_if_needed "$vmid"; then

        warn "✗ Não foi possível instalar cron na VM $vmid."
        warn "Ignorando VM."

        continue

    fi

    if ! install_procps_if_needed "$vmid"; then

        warn "✗ Não foi possível instalar procps na VM $vmid."
        warn "Ignorando VM."

        continue

    fi

    # --------------------------------------------------------
    # Enrollment
    # --------------------------------------------------------

    enroll_vm \
        "$vmid" \
        "$hostname" \
        "$ip_address" \
        "$os_info" \
        "$architecture" \
        "$machine_id"

    enroll_rc=$?

    # --------------------------------------------------------
    # Enrollment + instalação OK
    # --------------------------------------------------------

    if [ "$enroll_rc" -eq 0 ]; then

        sleep 2

        # ----------------------------------------------------
        # Verificar Agent
        # ----------------------------------------------------

        if vm_has_agent "$vmid"; then

            info "✓ Binário do Agent encontrado."

            start_agent "$vmid" || true

            sleep 2

            if vm_agent_running "$vmid"; then

                info "✓ VM $vmid está com Agent ativo."

                if vm_exec "$vmid" \
                    /usr/local/bin/patchmon-agent ping \
                    >/dev/null 2>&1
                then

                    info "✓ VM $vmid está comunicando com PatchMon."

                else

                    warn "✗ Agent está ativo, mas ping falhou."

                fi

            else

                warn "✗ VM $vmid foi cadastrada, mas Agent não está ativo."

            fi

        else

            warn "✗ Agent não foi encontrado após instalação."

        fi

    # --------------------------------------------------------
    # Host já cadastrado
    # --------------------------------------------------------

    elif [ "$enroll_rc" -eq 2 ]; then

        info "Host já existente no PatchMon."

        # ----------------------------------------------------
        # Não fazemos novo enrollment.
        # Apenas verificamos novamente o Agent.
        # ----------------------------------------------------

        if vm_has_agent "$vmid"; then

            info "Agent existente encontrado."

            start_agent "$vmid" || true

        else

            warn "Host existe no PatchMon, mas Agent não está instalado."
            warn "Não será criado outro host."

        fi

    fi

done <<< "$vm_list"

echo
info "Execução concluída."
