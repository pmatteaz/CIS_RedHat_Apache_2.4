#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Verifica CIS 1.2: Assicurarsi che il Server Non Sia Multi-Uso ===${NC}"

# Lista dei servizi essenziali che non dovrebbero essere disabilitati
ESSENTIAL_SERVICES=(
    "sshd"
    "httpd"
    "crond"
    "systemd-journald"
    "systemd-logind"
    "NetworkManager"
    "rsyslog"
    "syslog"
)

# Lista dei servizi comunemente non necessari per un web server
UNNECESSARY_SERVICES=(
    "sendmail"
    "postfix"
    "named"
    "bind"
    "cups"
    "nfs"
    "rpcbind"
    "vsftpd"
    "ftp"
    "telnet"
    "rsh"
    "rlogin"
    "tftp"
    "talk"
    "samba"
    "nfs-server"
    "squid"
)

# Funzione per verificare se un servizio è nella lista dei servizi essenziali
is_essential() {
    local service=$1
    for essential in "${ESSENTIAL_SERVICES[@]}"; do
        if [[ "$service" == "$essential" ]]; then
            return 0
        fi
    done
    return 1
}

echo -e "\n${BLUE}=== Verifica dei servizi attivi ===${NC}"

# Array per memorizzare i servizi non necessari trovati
declare -a found_unnecessary=()

# Verifica con systemctl
if command -v systemctl >/dev/null 2>&1; then
    echo -e "\n${YELLOW}Controllo servizi abilitati (systemd)...${NC}"
    while read -r service_line; do
        service=$(echo "$service_line" | awk '{print $1}' | sed 's/\.service//')
        
        # Verifica se il servizio è nella lista dei non necessari
        for unnecessary in "${UNNECESSARY_SERVICES[@]}"; do
            if [[ "$service" == *"$unnecessary"* ]] && ! is_essential "$service"; then
                found_unnecessary+=("$service")
                echo -e "${RED}✗ Trovato servizio non necessario: $service${NC}"
            fi
        done
    done < <(systemctl list-unit-files --state=enabled --type=service)
fi

# Verifica con chkconfig se disponibile (per sistemi legacy)
if command -v chkconfig >/dev/null 2>&1; then
    echo -e "\n${YELLOW}Controllo servizi abilitati (chkconfig)...${NC}"
    while read -r service_line; do
        service=$(echo "$service_line" | awk '{print $1}')
        
        # Verifica se il servizio è nella lista dei non necessari
        for unnecessary in "${UNNECESSARY_SERVICES[@]}"; do
            if [[ "$service" == *"$unnecessary"* ]] && ! is_essential "$service"; then
                # Aggiungi solo se non è già stato trovato
                if [[ ! " ${found_unnecessary[@]} " =~ " ${service} " ]]; then
                    found_unnecessary+=("$service")
                    echo -e "${RED}✗ Trovato servizio non necessario: $service${NC}"
                fi
            fi
        done
    done < <(chkconfig --list | grep ':on')
fi

# Se non sono stati trovati servizi non necessari
if [ ${#found_unnecessary[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ Non sono stati trovati servizi non necessari attivi${NC}"
    exit 0
fi

# Chiedi conferma per la remediation
echo -e "\n${YELLOW}Sono stati trovati ${#found_unnecessary[@]} servizi non necessari.${NC}"
echo "Vuoi procedere con la disabilitazione di questi servizi? (s/n)"
read -r risposta

if [[ "$risposta" =~ ^[Ss]$ ]]; then
    echo -e "\n${BLUE}=== Inizio remediation ===${NC}"
    
    for service in "${found_unnecessary[@]}"; do
        echo -e "\n${YELLOW}Disabilitazione di $service...${NC}"
        
        # Prova prima con systemctl
        if command -v systemctl >/dev/null 2>&1; then
            if systemctl stop "$service" 2>/dev/null && systemctl disable "$service" 2>/dev/null; then
                echo -e "${GREEN}✓ Servizio $service fermato e disabilitato con successo${NC}"
                continue
            fi
        fi
        
        # Se systemctl fallisce o non è disponibile, prova con chkconfig
        if command -v chkconfig >/dev/null 2>&1; then
            if service "$service" stop 2>/dev/null && chkconfig "$service" off 2>/dev/null; then
                echo -e "${GREEN}✓ Servizio $service fermato e disabilitato con successo${NC}"
                continue
            fi
        fi
        
        echo -e "${RED}✗ Non è stato possibile disabilitare il servizio $service${NC}"
    done
    
    echo -e "\n${GREEN}=== Remediation completata ===${NC}"
else
    echo -e "\n${YELLOW}Operazione annullata dall'utente${NC}"
fi

# Verifica finale
echo -e "\n${BLUE}=== Verifica finale dei servizi ===${NC}"
if command -v systemctl >/dev/null 2>&1; then
    echo "Servizi ancora abilitati:"
    systemctl list-unit-files --state=enabled --type=service | grep -vE "^($(IFS=\|; echo "${ESSENTIAL_SERVICES[*]}"))"
fi
