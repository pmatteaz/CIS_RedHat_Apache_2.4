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

print_section "CIS Control 9.3 - Verifica MaxKeepAliveRequests"

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

print_section "Verifica Configurazione MaxKeepAliveRequests"

# Funzione per verificare la configurazione di MaxKeepAliveRequests
check_max_keepalive() {
    echo "Controllo configurazione MaxKeepAliveRequests..."
    
    local max_keepalive_found=false
    local config_file=""
    local value_correct=false

    
    # Aggiungi file da conf.d
    if [ -d "$APACHE_CONF_D" ]; then
        while IFS= read -r -d '' file; do
            config_files+=("$file")
        done < <(find "$APACHE_CONF_D" -type f -name "*.conf" -print0)
    fi
    
    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*MaxKeepAliveRequests" "$conf_file"; then
                max_keepalive_found=true
                config_file="$conf_file"
                echo -e "${BLUE}MaxKeepAliveRequests trovato in: ${NC}$conf_file"
                
                local current_value=$(grep "^[[:space:]]*MaxKeepAliveRequests" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"
                
                if [ "$current_value" -ge 100 ] 2>/dev/null; then
                    value_correct=true
                    echo -e "${GREEN}✓ MaxKeepAliveRequests è configurato correttamente (≥ 100)${NC}"
                else
                    echo -e "${RED}✗ MaxKeepAliveRequests è troppo basso (< 100)${NC}"
                    issues_found+=("low_max_keepalive")
                fi
            fi
        fi
    done
    
    if ! $max_keepalive_found; then
        echo -e "${RED}✗ MaxKeepAliveRequests non configurato${NC}"
        issues_found+=("no_max_keepalive_config")
    fi
    
    # Verifica anche che KeepAlive sia attivo
    if ! grep -q "^[[:space:]]*KeepAlive[[:space:]]\+On" "$APACHE_CONF"; then
        echo -e "${YELLOW}! KeepAlive non è abilitato, MaxKeepAliveRequests non avrà effetto${NC}"
        issues_found+=("keepalive_disabled")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_max_keepalive

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione MaxKeepAliveRequests.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_9.3
        backup_dir="/root/max_keepalive_backup_$timestamp"
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
        
        echo -e "\n${YELLOW}Configurazione MaxKeepAliveRequests...${NC}"
        
        # Rimuovi eventuali configurazioni MaxKeepAliveRequests esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*MaxKeepAliveRequests/d' "$conf_file"
            fi
        done
        
        # Assicurati che KeepAlive sia attivo
        if ! grep -q "^[[:space:]]*KeepAlive" "$CONF_TO_USE"; then
            echo -e "\n# Enable KeepAlive" >> "$CONF_TO_USE"
            echo "KeepAlive On" >> "$CONF_TO_USE"
        else
            sed -i 's/^[[:space:]]*KeepAlive.*/KeepAlive On/' "$CONF_TO_USE"
        fi
        
        # Aggiungi la nuova configurazione
        echo -e "\n# Set MaxKeepAliveRequests" >> "$CONF_TO_USE"
        echo "MaxKeepAliveRequests 100" >> "$CONF_TO_USE"
        
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
                if check_max_keepalive; then
                    echo -e "\n${GREEN}✓ MaxKeepAliveRequests configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione MaxKeepAliveRequests è corretta${NC}"
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

echo -e "\n${BLUE}Note sulla sicurezza MaxKeepAliveRequests:${NC}"
echo -e "${BLUE}- Limita il numero di richieste per connessione persistente${NC}"
echo -e "${BLUE}- Aiuta a prevenire il DoS da connessioni persistenti${NC}"
echo -e "${BLUE}- Bilancia performance e sicurezza${NC}"
echo -e "${BLUE}- Funziona solo se KeepAlive è attivo${NC}"

# Test delle connessioni persistenti se possibile
if command_exists curl; then
    print_section "Test Connessioni Persistenti"
    echo -e "${YELLOW}Verifica supporto keep-alive...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    echo -e "\n${BLUE}Headers di risposta:${NC}"
    curl -I http://localhost 2>/dev/null | grep -i "keep-alive"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Keep-Alive supportato e attivo${NC}"
    else
        echo -e "${YELLOW}! Keep-Alive non rilevato nelle risposte${NC}"
    fi
fi
