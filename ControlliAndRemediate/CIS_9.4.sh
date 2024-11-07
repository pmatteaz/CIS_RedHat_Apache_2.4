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

print_section "CIS Control 9.4 - Verifica KeepAliveTimeout"

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

print_section "Verifica Configurazione KeepAliveTimeout"

# Funzione per verificare la configurazione di KeepAliveTimeout
check_keepalive_timeout() {
    echo "Controllo configurazione KeepAliveTimeout..."
    
    local keepalive_timeout_found=false
    local config_file=""
    local value_correct=false
    
    # Array dei file da controllare
    declare -a config_files=("$APACHE_CONF")
    
    # Aggiungi file da conf.d
    if [ -d "$APACHE_CONF_D" ]; then
        while IFS= read -r -d '' file; do
            config_files+=("$file")
        done < <(find "$APACHE_CONF_D" -type f -name "*.conf" -print0)
    fi
    
    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*KeepAliveTimeout" "$conf_file"; then
                keepalive_timeout_found=true
                config_file="$conf_file"
                echo -e "${BLUE}KeepAliveTimeout trovato in: ${NC}$conf_file"
                
                local current_value=$(grep "^[[:space:]]*KeepAliveTimeout" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value secondi"
                
                if [ "$current_value" -le 15 ] 2>/dev/null; then
                    value_correct=true
                    echo -e "${GREEN}✓ KeepAliveTimeout è configurato correttamente (≤ 15 secondi)${NC}"
                else
                    echo -e "${RED}✗ KeepAliveTimeout è troppo alto (> 15 secondi)${NC}"
                    issues_found+=("high_keepalive_timeout")
                fi
            fi
        fi
    done
    
    if ! $keepalive_timeout_found; then
        echo -e "${RED}✗ KeepAliveTimeout non configurato${NC}"
        echo -e "${YELLOW}! Verrà utilizzato il valore predefinito di 5 secondi${NC}"
        issues_found+=("no_keepalive_timeout_config")
    fi
    
    # Verifica che KeepAlive sia attivo
    local keepalive_enabled=false
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ] && grep -q "^[[:space:]]*KeepAlive[[:space:]]\+On" "$conf_file"; then
            keepalive_enabled=true
            echo -e "${GREEN}✓ KeepAlive è abilitato${NC}"
            break
        fi
    done
    
    if ! $keepalive_enabled; then
        echo -e "${YELLOW}! KeepAlive non è abilitato, KeepAliveTimeout non avrà effetto${NC}"
        issues_found+=("keepalive_disabled")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_keepalive_timeout

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione KeepAliveTimeout.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_9.4
        backup_dir="/root/keepalive_timeout_backup_$timestamp"
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
        
        echo -e "\n${YELLOW}Configurazione KeepAliveTimeout e KeepAlive...${NC}"
        
        # Rimuovi eventuali configurazioni KeepAliveTimeout e KeepAlive esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*KeepAliveTimeout/d' "$conf_file"
                sed -i '/^[[:space:]]*KeepAlive[[:space:]]/d' "$conf_file"
            fi
        done
        
        # Aggiungi le nuove configurazioni
        echo -e "\n# Enable KeepAlive and set timeout" >> "$CONF_TO_USE"
        echo "KeepAlive On" >> "$CONF_TO_USE"
        echo "KeepAliveTimeout 15" >> "$CONF_TO_USE"
        
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
                if check_keepalive_timeout; then
                    echo -e "\n${GREEN}✓ KeepAliveTimeout configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione KeepAliveTimeout è corretta${NC}"
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

echo -e "\n${BLUE}Note sulla sicurezza KeepAliveTimeout:${NC}"
echo -e "${BLUE}- Un timeout basso riduce il rischio di esaurimento delle risorse${NC}"
echo -e "${BLUE}- Protegge da attacchi DoS basati su connessioni persistenti${NC}"
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
        echo -e "Timeout configurato: $(curl -I http://localhost 2>/dev/null | grep -i "keep-alive" | awk -F'timeout=' '{print $2}' | awk '{print $1}') secondi"
    else
        echo -e "${YELLOW}! Keep-Alive non rilevato nelle risposte${NC}"
    fi
fi
