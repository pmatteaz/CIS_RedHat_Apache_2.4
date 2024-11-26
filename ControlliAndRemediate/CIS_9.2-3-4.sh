#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per stampare intestazioni delle sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_section "CIS Control 9.2 - Verifica KeepAlive"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    APACHE_CONF_D="/etc/httpd/conf.d"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    APACHE_CONF_D="/etc/apache2/conf-available"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Array dei file da controllare
declare -a config_files=("$APACHE_CONF")


print_section "Verifica Configurazione KeepAlive"

# Funzione per verificare la configurazione di KeepAlive
check_keepalive_configuration() {
    echo "Controllo configurazione KeepAlive..."
    
    local keepalive_found=false
    local config_file=""
    local keepalive_correct=false
    
    # Aggiungi file da conf.d
    if [ -d "$APACHE_CONF_D" ]; then
        while IFS= read -r -d '' file; do
            config_files+=("$file")
        done < <(find "$APACHE_CONF_D" -type f -name "*.conf" -print0)
    fi
    
    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*KeepAlive[[:space:]]" "$conf_file"; then
                keepalive_found=true
                config_file="$conf_file"
                echo -e "${BLUE}KeepAlive trovato in: ${NC}$conf_file"
                
                local current_value=$(grep "^[[:space:]]*KeepAlive[[:space:]]" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"
                
                if [[ "${current_value,,}" == "on" ]]; then
                    keepalive_correct=true
                    echo -e "${GREEN}✓ KeepAlive è correttamente abilitato${NC}"
                else
                    echo -e "${RED}✗ KeepAlive non è abilitato${NC}"
                    issues_found+=("keepalive_disabled")
                fi
                
                # Verifica anche KeepAliveTimeout
                if grep -q "^[[:space:]]*KeepAliveTimeout" "$conf_file"; then
                    local timeout_value=$(grep "^[[:space:]]*KeepAliveTimeout" "$conf_file" | awk '{print $2}')
                    echo -e "${BLUE}KeepAliveTimeout: ${NC}$timeout_value secondi"
                fi
                
                # Verifica MaxKeepAliveRequests
                if grep -q "^[[:space:]]*MaxKeepAliveRequests" "$conf_file"; then
                    local max_requests=$(grep "^[[:space:]]*MaxKeepAliveRequests" "$conf_file" | awk '{print $2}')
                    echo -e "${BLUE}MaxKeepAliveRequests: ${NC}$max_requests"
                fi
            fi
        fi
    done
    
    if ! $keepalive_found; then
        echo -e "${RED}✗ KeepAlive non configurato esplicitamente${NC}"
        issues_found+=("no_keepalive_config")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_keepalive_configuration

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione KeepAlive.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_9.2
        backup_dir="/root/keepalive_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                cp "$conf_file" "$backup_dir/"
            fi
        done
        
        # Determina il file di configurazione da modificare
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            CONF_TO_USE="/etc/apache2/conf-available/keepalive.conf"
            touch "$CONF_TO_USE"
            a2enconf keepalive
        else
            CONF_TO_USE="$APACHE_CONF"
        fi
        
        echo -e "\n${YELLOW}Configurazione KeepAlive...${NC}"
        
        # Rimuovi eventuali configurazioni KeepAlive esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*KeepAlive[[:space:]]/d' "$conf_file"
            fi
        done
        
        # Aggiungi le nuove configurazioni
        cat >> "$CONF_TO_USE" << 'EOL'

# Enable KeepAlive with recommended settings
KeepAlive On
KeepAliveTimeout 5
MaxKeepAliveRequests 100
EOL
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_CMD -t; then
            echo -e "${GREEN}✓ Configurazione Apache valida${NC}"
            
            # Riavvia Apache
            echo -e "\n${YELLOW}Riavvio Apache...${NC}"
            systemctl restart $APACHE_CMD
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                if check_keepalive_configuration; then
                    echo -e "\n${GREEN}✓ KeepAlive configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina i file originali
            for conf_file in "${config_files[@]}"; do
                if [ -f "$backup_dir/$(basename "$conf_file")" ]; then
                    cp "$backup_dir/$(basename "$conf_file")" "$conf_file"
                fi
            done
            
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione KeepAlive è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione principale: $APACHE_CONF"
if [ -n "$CONF_TO_USE" ]; then
    echo "2. File configurazione KeepAlive: $CONF_TO_USE"
fi
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla configurazione KeepAlive:${NC}"
echo -e "${BLUE}- KeepAlive On migliora le performance con connessioni persistenti${NC}"
echo -e "${BLUE}- KeepAliveTimeout controlla il tempo di attesa tra le richieste${NC}"
echo -e "${BLUE}- MaxKeepAliveRequests limita il numero di richieste per connessione${NC}"
echo -e "${BLUE}- Bilanciare tra performance e utilizzo delle risorse${NC}"

# Test KeepAlive se possibile
if command_exists curl; then
    print_section "Test Connessione"
    echo -e "${YELLOW}Verifica connessione persistente...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    echo -e "\n${BLUE}Test risposta server:${NC}"
    if curl -v -s http://localhost/ 2>&1 | grep -i "keep-alive"; then
        echo -e "${GREEN}✓ Il server supporta connessioni keep-alive${NC}"
    else
        echo -e "${YELLOW}! Impossibile verificare il supporto keep-alive${NC}"
    fi
fi

