#!/bin/bash
#Versione che commenta la direttiva 

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

print_section "CIS Control 8.3 - Verifica Rimozione Contenuti Predefiniti Apache"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    HTML_DIR="/var/www/html"
    HTTPD_DIR="/usr/share/httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    HTML_DIR="/var/www/html"
    HTTPD_DIR="/usr/share/apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Funzione per verificare la direttiva Include httpd-autoindex.conf
check_autoindex_include() {
    echo -e "\n${BLUE}Verifica direttiva Include httpd-autoindex.conf...${NC}"

    local conf_files=()

    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        conf_files+=("$APACHE_CONF" "/etc/httpd/conf.d/*.conf")
    else
        conf_files+=("$APACHE_CONF" "/etc/apache2/conf-enabled/*.conf")
    fi

    local found_autoindex=false

    for conf_pattern in "${conf_files[@]}"; do
        for conf_file in $conf_pattern; do
            if [ -f "$conf_file" ]; then
                if grep -q "^[[:space:]]*Include.*httpd-autoindex\.conf" "$conf_file"; then
                    found_autoindex=true
                    echo -e "${RED}✗ Trovata direttiva Include httpd-autoindex.conf in: $conf_file${NC}"
                    issues_found+=("found_autoindex_include")
                fi
            fi
        done
    done

    if [ "$found_autoindex" = false ]; then
        echo -e "${GREEN}✓ Nessuna direttiva Include httpd-autoindex.conf attiva trovata${NC}"
    fi

    return 0
}

print_section "Verifica Contenuti Predefiniti"


# Esegui le verifiche
check_autoindex_include

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Trovati problemi di configurazione.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_8.3
        backup_dir="/root/apache_content_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."

        # Backup dei file di configurazione
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            cp -r /etc/httpd "$backup_dir/"
        else
            cp -r /etc/apache2 "$backup_dir/"
        fi

        # Commenta la direttiva Include httpd-autoindex.conf
        if grep -l "^[[:space:]]*Include.*httpd-autoindex\.conf" "$APACHE_CONF" > /dev/null; then
            sed -i 's/^[[:space:]]*Include.*httpd-autoindex\.conf/#&/' "$APACHE_CONF"
            echo -e "${GREEN}✓ Commentata direttiva Include httpd-autoindex.conf${NC}"
        fi

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
                if check_default_content; then
                    echo -e "\n${GREEN}✓ Configurazione corretta${NC}"
                else
                    echo -e "\n${RED}✗ Alcuni problemi persistono${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun problema rilevato nella configurazione${NC}"
fi
