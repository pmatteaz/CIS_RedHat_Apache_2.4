#!/bin/bash
# Da verificare perchè non va la fix 
# Da rivedere i controlli 

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

print_section "CIS Control 10.4 - Verifica LimitRequestBody"

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

print_section "Verifica Configurazione LimitRequestBody"

# Funzione per verificare la configurazione di LimitRequestBody
check_limit_request_body() {
    echo "Controllo configurazione LimitRequestBody..."
    
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
            if grep -q "^[[:space:]]*LimitRequestBody[[:space:]]" "$conf_file"; then
                limit_found=true
                config_file="$conf_file"
                echo -e "${BLUE}LimitRequestBody trovato in: ${NC}$conf_file"
                
                local current_value=$(grep "^[[:space:]]*LimitRequestBody[[:space:]]" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value bytes"
                
                if [ "$current_value" -le 102400 ] 2>/dev/null; then
                    value_correct=true
                    echo -e "${GREEN}✓ LimitRequestBody è configurato correttamente (≤ 102400 bytes)${NC}"
                else
                    echo -e "${RED}✗ LimitRequestBody è troppo alto (> 102400 bytes)${NC}"
                    issues_found+=("high_body_limit")
                fi
            fi
        fi
    done
    
    if ! $limit_found; then
        echo -e "${RED}✗ LimitRequestBody non configurato esplicitamente${NC}"
        echo -e "${YELLOW}! Verrà utilizzato il valore predefinito illimitato${NC}"
        issues_found+=("no_body_limit")
    fi
    
    # Test pratico con POST di grandi dimensioni
    if command_exists curl; then
        echo -e "\n${BLUE}Test valore effettivo con POST grande:${NC}"
        # Crea un file temporaneo più grande del limite
        local temp_file=$(mktemp)
        dd if=/dev/zero of="$temp_file" bs=1024 count=110 2>/dev/null
        
        if ! curl -s -o /dev/null -F "file=@$temp_file" http://localhost/; then
            echo -e "${GREEN}✓ Il server rifiuta correttamente POST troppo grandi${NC}"
        else
            echo -e "${YELLOW}! Il server accetta POST più grandi di 102400 bytes${NC}"
            issues_found+=("accepts_large_posts")
        fi
        
        rm -f "$temp_file"
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_limit_request_body

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione LimitRequestBody.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_10.4
        backup_dir="/root/limit_body_backup_$timestamp"
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
        
        echo -e "\n${YELLOW}Configurazione LimitRequestBody...${NC}"
        
        # Rimuovi eventuali configurazioni LimitRequestBody esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/# Set request body size limit/d' "$conf_file"
                sed -i '/#[[:space:]]*LimitRequestBody[[:space:]]/d' "$conf_file"
                sed -i '/^[[:space:]]*LimitRequestBody[[:space:]]/d' "$conf_file"
            fi
        done
        
        # Aggiungi la nuova configurazione
        echo -e "\n# Set request body size limit" >> "$CONF_TO_USE"
        echo "LimitRequestBody 102400" >> "$CONF_TO_USE"
        
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
                if check_limit_request_body; then
                    echo -e "\n${GREEN}✓ LimitRequestBody configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione LimitRequestBody è corretta${NC}"
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
