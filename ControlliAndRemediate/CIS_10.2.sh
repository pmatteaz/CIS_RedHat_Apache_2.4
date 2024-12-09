#!/bin/bash
# Da verificare perchè non va la fix 

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

print_section "CIS Control 10.2 - Verifica LimitRequestFields"

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

print_section "Verifica Configurazione LimitRequestFields"

# Funzione per verificare la configurazione di LimitRequestFields
check_limit_request_fields() {
    echo "Controllo configurazione LimitRequestFields..."
    
    local limit_found=false
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
            if grep -q "^[[:space:]]*LimitRequestFields[[:space:]][0-9]" "$conf_file"; then
                limit_found=true
                config_file="$conf_file"
                echo -e "${BLUE}LimitRequestFields trovato in: ${NC}$conf_file"
                
                local current_value=$(grep "^[[:space:]]*LimitRequestFields[[:space:]][0-9]" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"
                
                if [ "$current_value" -le 100 ] 2>/dev/null; then
                    value_correct=true
                    echo -e "${GREEN}✓ LimitRequestFields è configurato correttamente (≤ 100)${NC}"
                else
                    echo -e "${RED}✗ LimitRequestFields è troppo alto (> 100)${NC}"
                    issues_found+=("high_request_fields")
                fi
            fi
        fi
    done
    
    if ! $limit_found; then
        echo -e "${RED}✗ LimitRequestFields non configurato esplicitamente${NC}"
        echo -e "${YELLOW}! Verrà utilizzato il valore predefinito di 100${NC}"
        issues_found+=("no_request_fields_limit")
    fi
    
    # Test aggiuntivo per verificare il valore effettivo tramite richiesta HTTP
    if command_exists curl; then
        echo -e "\n${BLUE}Test valore effettivo tramite richiesta HTTP:${NC}"
        local test_header=""
        for i in {1..101}; do
            test_header="$test_header -H \"X-Test-$i: value\""
        done
        result=$(eval curl -k -v -s -o -w "%{http_code}" /dev/null https://localhost "$test_header" 2>&1 1>/dev/null)
        if ; then
            echo -e "${GREEN}✓ Il server rifiuta correttamente richieste con troppi headers${NC}"
        else
            echo -e "${YELLOW}! Il server accetta richieste con più di 100 headers${NC}"
            issues_found+=("accepts_too_many_headers")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_limit_request_fields

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione LimitRequestFields.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_10.2
        backup_dir="/root/limit_request_fields_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                cp "$conf_file" "$backup_dir/"
            fi
        done
        
        # Determina il file di configurazione da modificare
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            CONF_TO_USE="/etc/apache2/conf-available/security.conf"
            touch "$CONF_TO_USE"
            a2enconf security
        else
            CONF_TO_USE="$APACHE_CONF"
        fi
        
        echo -e "\n${YELLOW}Configurazione LimitRequestFields...${NC}"
        
        # Rimuovi eventuali configurazioni LimitRequestFields esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/# Set request fields limit/d' "$conf_file"
                sed -i '/#[[:space:]]*LimitRequestFields[[:space:]][0-9]/d' "$conf_file"
                sed -i '/^[[:space:]]*LimitRequestFields[[:space:]][0-9]/d' "$conf_file"
            fi
        done
        
        # Aggiungi la nuova configurazione
        echo -e "\n# Set request fields limit" >> "$CONF_TO_USE"
        echo "LimitRequestFields 100" >> "$CONF_TO_USE"
        
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
                # print_section "Verifica Finale"
                # if check_limit_request_fields; then
                #    echo -e "\n${GREEN}✓ LimitRequestFields configurato correttamente${NC}"
                # else
                #    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                # fi
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
    echo -e "\n${GREEN}✓ La configurazione LimitRequestFields è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione principale: $APACHE_CONF"
if [ -n "$CONF_TO_USE" ]; then
    echo "2. File configurazione sicurezza: $CONF_TO_USE"
fi
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi
