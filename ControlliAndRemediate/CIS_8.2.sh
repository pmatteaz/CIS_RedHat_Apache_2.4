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

print_section "CIS Control 8.2 - Verifica ServerSignature"

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
    ERROR_PAGES_DIR="/var/www/error"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    SECURITY_CONF="/etc/apache2/conf-available/security.conf"
    ERROR_PAGES_DIR="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Array dei file da controllare
declare -a config_files=("$APACHE_CONF" "$SECURITY_CONF")


print_section "Verifica Configurazione ServerSignature"

# Funzione per verificare la configurazione ServerSignature
check_server_signature() {
    echo "Controllo configurazione ServerSignature..."

    local server_signature_found=false
    local correct_value=false
    local config_file=""

    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*ServerSignature" "$conf_file"; then
                server_signature_found=true
                config_file="$conf_file"
                echo -e "${BLUE}ServerSignature trovato in: ${NC}$conf_file"

                local current_value=$(grep "^[[:space:]]*ServerSignature" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value"

                if [[ "${current_value,,}" == "off" ]]; then
                    correct_value=true
                    echo -e "${GREEN}✓ ServerSignature è correttamente disabilitato${NC}"
                else
                    echo -e "${RED}✗ ServerSignature non è disabilitato${NC}"
                    issues_found+=("wrong_value")
                fi
            fi
        fi
    done

    if ! $server_signature_found; then
        echo -e "${RED}✗ ServerSignature non configurato${NC}"
        issues_found+=("no_server_signature")
    fi

    # Verifica pagine di errore per firme del server
    echo -e "\n${BLUE}Verifica pagine di errore...${NC}"
    if [ -d "$ERROR_PAGES_DIR" ]; then
        if find "$ERROR_PAGES_DIR" -type f -name "*error*.html" -exec grep -l "Server" {} \; | grep -q .; then
            echo -e "${RED}✗ Trovate firme del server nelle pagine di errore${NC}"
            issues_found+=("error_pages_signature")
        else
            echo -e "${GREEN}✓ Nessuna firma del server trovata nelle pagine di errore${NC}"
        fi
    fi

    # Test di una richiesta 404 per verificare la firma del server
    if command_exists curl; then
        echo -e "\n${BLUE}Test risposta 404...${NC}"
        local error_page=$(curl -k https://localhost/nonexistent 2>/dev/null)
        if echo "$error_page" | grep -qi "apache" || echo "$error_page" | grep -qi "server at"; then
            echo -e "${RED}✗ Firma del server presente nelle risposte di errore${NC}"
            issues_found+=("error_response_signature")
        else
            echo -e "${GREEN}✓ Nessuna firma del server nelle risposte di errore${NC}"
        fi
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_server_signature

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione ServerSignature.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_8.2
        backup_dir="/root/server_signature_backup_$timestamp"
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

        echo -e "\n${YELLOW}Configurazione ServerSignature...${NC}"

        # Rimuovi eventuali configurazioni ServerSignature esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*ServerSignature/d' "$conf_file"
            fi
        done

        # Aggiungi la nuova configurazione
        echo -e "\n# Disable server signature" >> "$CONF_TO_USE"
        echo "ServerSignature Off" >> "$CONF_TO_USE"

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
                if check_server_signature; then
                    echo -e "\n${GREEN}✓ ServerSignature configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione ServerSignature è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione: $CONF_TO_USE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

# Test finale delle pagine di errore
if command_exists curl; then
    print_section "Test Pagina di Errore"
    echo -e "${YELLOW}Verifica firma del server nella pagina 404...${NC}"

    # Attendi che Apache sia completamente riavviato
    sleep 2

    if curl -k https://localhost/nonexistent 2>/dev/null | grep -qi "apache" || \
       curl -k https://localhost/nonexistent 2>/dev/null | grep -qi "server at"; then
        echo -e "${RED}✗ La firma del server è ancora visibile nelle pagine di errore${NC}"
    else
        echo -e "${GREEN}✓ Nessuna firma del server visibile nelle pagine di errore${NC}"
    fi
fi
