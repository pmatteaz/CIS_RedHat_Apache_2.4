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

print_section "CIS Control 10.1 - Verifica LimitRequestLine"

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


print_section "Verifica Configurazione LimitRequestLine"

# Funzione per verificare la configurazione di LimitRequestLine
check_limit_request_line() {
    echo "Controllo configurazione LimitRequestLine..."

    local limit_found=false
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
            if grep -q "^[[:space:]]*LimitRequestLine" "$conf_file"; then
                limit_found=true
                config_file="$conf_file"
                echo -e "${BLUE}LimitRequestLine trovato in: ${NC}$conf_file"

                local current_value=$(grep "^[[:space:]]*LimitRequestLine" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"

                if [ "$current_value" -le 512 ] 2>/dev/null; then
                    value_correct=true
                    echo -e "${GREEN}✓ LimitRequestLine è configurato correttamente (≤ 512)${NC}"
                else
                    echo -e "${RED}✗ LimitRequestLine è troppo alto (> 512)${NC}"
                    issues_found+=("high_request_line")
                fi
            fi
        fi
    done

    if ! $limit_found; then
        echo -e "${RED}✗ LimitRequestLine non configurato esplicitamente${NC}"
        echo -e "${YELLOW}! Verrà utilizzato il valore predefinito di 8190${NC}"
        issues_found+=("no_request_line_limit")
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_limit_request_line

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione LimitRequestLine.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_10.1
        backup_dir="/root/apache_limit_request_line_backup_$timestamp"
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

        echo -e "\n${YELLOW}Configurazione LimitRequestLine...${NC}"

        # Rimuovi eventuali configurazioni LimitRequestLine esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/# Set request line limit/d' "$conf_file"
                sed -i '/#[[:space:]]*LimitRequestLine/d' "$conf_file"
                sed -i '/^[[:space:]]*LimitRequestLine/d' "$conf_file"
            fi
        done

        # Aggiungi la nuova configurazione
        echo -e "\n# Set request line limit" >> "$CONF_TO_USE"
        echo "LimitRequestLine 512" >> "$CONF_TO_USE"

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
                # if check_limit_request_line; then
                #    echo -e "\n${GREEN}✓ LimitRequestLine configurato correttamente${NC}"
                #else
                #    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                #fi
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
    echo -e "\n${GREEN}✓ La configurazione LimitRequestLine è corretta${NC}"
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
