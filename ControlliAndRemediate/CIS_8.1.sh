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

print_section "CIS Control 8.1 - Verifica ServerTokens"

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
    SECURITY_CONF="/etc/httpd/conf.d/security.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    SECURITY_CONF="/etc/apache2/conf-available/security.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Array dei file da controllare
declare -a config_files=()
config_files+=("$APACHE_CONF")
config_files+=("$SECURITY_CONF")


print_section "Verifica Configurazione ServerTokens"

# Funzione per verificare la configurazione ServerTokens
check_server_tokens() {
    echo "Controllo configurazione ServerTokens..."

    local server_tokens_found=false
    local correct_value=false
    local config_file=""

    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*ServerTokens" "$conf_file"; then
                server_tokens_found=true
                config_file="$conf_file"
                echo -e "${BLUE}ServerTokens trovato in: ${NC}$conf_file"

                local current_value=$(grep "^[[:space:]]*ServerTokens" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"

                if [[ "${current_value,,}" == "prod" ]]; then
                    correct_value=true
                    echo -e "${GREEN}✓ ServerTokens è impostato correttamente a 'Prod'${NC}"
                else
                    echo -e "${RED}✗ ServerTokens non è impostato a 'Prod'${NC}"
                    issues_found+=("wrong_value")
                fi
            fi
        fi
    done

    if ! $server_tokens_found; then
        echo -e "${RED}✗ ServerTokens non configurato${NC}"
        issues_found+=("no_server_tokens")
    fi

    # Verifica header server tramite curl se possibile
    #if command_exists curl; then
    #    echo -e "\n${BLUE}Verifica header Server...${NC}"
    #    local server_header=$(curl -sI http://localhost 2>/dev/null | grep -i "^Server:")
    #    if [ -n "$server_header" ]; then
    #        echo -e "Header Server attuale: $server_header"
    #        if echo "$server_header" | grep -qiE "apache.*\/.*|apache.*win|apache.*\(.*\)"; then
    #            echo -e "${RED}✗ L'header Server rivela troppe informazioni${NC}"
    #            issues_found+=("verbose_header")
    #        fi
    #    fi
    #fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_server_tokens

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione ServerTokens.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_8.1
        backup_dir="/root/server_tokens_backup_$timestamp"
        mkdir -p "$backup_dir"

        # Determina il file di configurazione da utilizzare
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            CONF_TO_USE="$SECURITY_CONF"
            # Assicurati che security.conf sia abilitato
            if [ ! -f "/etc/apache2/conf-enabled/security.conf" ]; then
                a2enconf security
            fi
        else
            CONF_TO_USE="$APACHE_CONF"
        fi

        echo "Creazione backup in $backup_dir..."
        cp "$CONF_TO_USE" "$backup_dir/"

        echo -e "\n${YELLOW}Configurazione ServerTokens...${NC}"
        # Rimuovi eventuali configurazioni ServerTokens esistenti
        for file in "${config_files[@]}"; do
            echo " $file -- remove "
            if [ -f "$file" ]; then
                echo " $file -- remove "
                sed -i '/#*ServerTokens.*/d' "$file"
                sed -i '/^[[:space:]]*ServerTokens.*/d' "$file"
            fi
        done

        # Aggiungi la nuova configurazione
        echo -e "\n# Set ServerTokens to Prod" >> "$CONF_TO_USE"
        echo "ServerTokens Prod" >> "$CONF_TO_USE"

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
                if check_server_tokens; then
                    echo -e "\n${GREEN}✓ ServerTokens configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$CONF_TO_USE")" "$CONF_TO_USE"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione ServerTokens è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione: $CONF_TO_USE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

# Test finale dell'header Server
#if command_exists curl; then
#    print_section "Test Header Server"
#    echo -e "${YELLOW}Verifica header Server dopo la configurazione...${NC}"
#
#    # Attendi che Apache sia completamente riavviato
#    sleep 2
#
#    echo -e "\n${BLUE}Header Server attuale:${NC}"
#    curl -sI http://localhost 2>/dev/null | grep -i "^Server:"
#fi
