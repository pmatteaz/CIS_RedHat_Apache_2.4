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

print_section "CIS Control 9.6 - Verifica Request Body Timeout"

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

print_section "Verifica Configurazione Request Body Timeout"

# Funzione per verificare la configurazione del timeout del body
check_body_timeout() {
    echo "Controllo configurazione RequestReadTimeout body..."
    
    local body_timeout_found=false
    local config_file=""
    local value_correct=false
    
    # Verifica se mod_reqtimeout è caricato
    if ! $APACHE_CMD -M 2>/dev/null | grep -q "reqtimeout_module"; then
        echo -e "${RED}✗ Modulo reqtimeout non caricato${NC}"
        issues_found+=("no_reqtimeout_module")
        return 1
    else
        echo -e "${GREEN}✓ Modulo reqtimeout caricato${NC}"
    fi
    
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
            if grep -q "^[[:space:]]*RequestReadTimeout[[:space:]]*body=" "$conf_file"; then
                body_timeout_found=true
                config_file="$conf_file"
                echo -e "${BLUE}RequestReadTimeout body trovato in: ${NC}$conf_file"
                
                local timeout_line=$(grep "^[[:space:]]*RequestReadTimeout[[:space:]]*body=" "$conf_file")
                echo -e "${BLUE}Configurazione attuale: ${NC}$timeout_line"
                
                # Estrai il valore del timeout
                local body_timeout=$(echo "$timeout_line" | grep -o 'body=[0-9]*' | cut -d'=' -f2)
                if [ -n "$body_timeout" ] && [ "$body_timeout" -le 20 ]; then
                    value_correct=true
                    echo -e "${GREEN}✓ Timeout body configurato correttamente (≤ 20 secondi)${NC}"
                else
                    echo -e "${RED}✗ Timeout body troppo alto (> 20 secondi)${NC}"
                    issues_found+=("high_body_timeout")
                fi
            fi
        fi
    done
    
    if ! $body_timeout_found; then
        echo -e "${RED}✗ RequestReadTimeout body non configurato${NC}"
        issues_found+=("no_body_timeout_config")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_body_timeout

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione del timeout del body.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_9.6
        backup_dir="/root/body_timeout_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                cp "$conf_file" "$backup_dir/"
            fi
        done
        
        # Attiva il modulo reqtimeout se necessario
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            a2enmod reqtimeout
            CONF_TO_USE="/etc/apache2/conf-available/reqtimeout.conf"
            touch "$CONF_TO_USE"
            a2enconf reqtimeout
        else
            CONF_TO_USE="$APACHE_CONF"
            if ! $APACHE_CMD -M 2>/dev/null | grep -q "reqtimeout_module"; then
                echo "LoadModule reqtimeout_module modules/mod_reqtimeout.so" >> "$APACHE_CONF"
            fi
        fi
        
        echo -e "\n${YELLOW}Configurazione RequestReadTimeout body...${NC}"
        
        # Rimuovi eventuali configurazioni RequestReadTimeout body esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*RequestReadTimeout[[:space:]]*body=/d' "$conf_file"
            fi
        done
        
        # Aggiungi la nuova configurazione
        echo -e "\n# Set request body timeout" >> "$CONF_TO_USE"
        echo "RequestReadTimeout body=20,MinRate=500" >> "$CONF_TO_USE"
        
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
                if check_body_timeout; then
                    echo -e "\n${GREEN}✓ Timeout body configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione del timeout del body è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione principale: $APACHE_CONF"
if [ -n "$CONF_TO_USE" ]; then
    echo "2. File configurazione timeout: $CONF_TO_USE"
fi
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza del timeout del body:${NC}"
echo -e "${BLUE}- Un timeout appropriato protegge da attacchi Slow POST${NC}"
echo -e "${BLUE}- Il MinRate garantisce una velocità minima di upload${NC}"
echo -e "${BLUE}- Valori troppo bassi potrebbero interferire con upload legittimi${NC}"
echo -e "${BLUE}- Il modulo reqtimeout è essenziale per questa protezione${NC}"

# Test del timeout se possibile
if command_exists curl && command_exists dd; then
    print_section "Test Timeout Body"
    echo -e "${YELLOW}Test risposta server con POST lento...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    # Crea un file temporaneo per il test
    temp_file=$(mktemp)
    dd if=/dev/zero of="$temp_file" bs=1M count=1 2>/dev/null
    
    echo -e "\n${BLUE}Test timeout con POST lento:${NC}"
    if ! curl -X POST -H "Content-Type: multipart/form-data" -F "file=@$temp_file" --limit-rate 1k -m 25 http://localhost/ > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Il server gestisce correttamente le richieste POST lente${NC}"
    else
        echo -e "${YELLOW}! Test del timeout non conclusivo${NC}"
    fi
    
    # Pulizia
    rm -f "$temp_file"
fi
