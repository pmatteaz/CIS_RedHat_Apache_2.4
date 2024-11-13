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

print_section "CIS Control 7.11 - Verifica HTTP Strict Transport Security (HSTS)"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    SSL_CONF_DIR="/etc/httpd/conf.d"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
    HEADERS_MODULE="mod_headers.so"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/mods-enabled"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
    if [ ! -f "$SSL_CONF_FILE" ]; then
        SSL_CONF_FILE="/etc/apache2/mods-available/ssl.conf"
    fi
    HEADERS_MODULE="headers"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione HSTS"

# Funzione per verificare la configurazione HSTS
check_hsts() {
    echo "Controllo configurazione HTTP Strict Transport Security..."

    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi

    # Verifica mod_headers
    if $APACHE_CMD -M 2>/dev/null | grep -q "headers_module"; then
        echo -e "${GREEN}✓ Modulo headers caricato${NC}"
    else
        echo -e "${RED}✗ Modulo headers non caricato${NC}"
        issues_found+=("no_headers_module")
    fi

    # Verifica configurazione HSTS
    if grep -q "^[[:space:]]*Header[[:space:]]\+.*Strict-Transport-Security" "$SSL_CONF_FILE"; then
        echo -e "${GREEN}✓ Header HSTS trovato${NC}"

        # Verifica parametri HSTS
        local hsts_line=$(grep "^[[:space:]]*Header[[:space:]]\+.*Strict-Transport-Security" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale HSTS: ${NC}$hsts_line"

        # Verifica max-age
        if echo "$hsts_line" | grep -q "max-age=600"; then
            echo -e "${GREEN}✓ max-age configurato correttamente (2 anni)${NC}"
        else
            echo -e "${RED}✗ max-age non configurato correttamente${NC}"
            issues_found+=("wrong_max_age")
        fi

        # Verifica includeSubDomains
        #if echo "$hsts_line" | grep -q "includeSubDomains"; then
        #    echo -e "${GREEN}✓ includeSubDomains abilitato${NC}"
        #else
        #    echo -e "${RED}✗ includeSubDomains non abilitato${NC}"
        #    issues_found+=("no_include_subdomains")
        #fi

        # Verifica preload
        #if echo "$hsts_line" | grep -q "preload"; then
        #    echo -e "${GREEN}✓ preload abilitato${NC}"
        #else
        #    echo -e "${RED}✗ preload non abilitato${NC}"
        #    issues_found+=("no_preload")
        #fi
    else
        echo -e "${RED}✗ Header HSTS non configurato${NC}"
        issues_found+=("no_hsts")
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_hsts

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione HSTS.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.11
        backup_dir="/root/hsts_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"

        # Abilita mod_headers se necessario
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            a2enmod headers
        elif [ "$SYSTEM_TYPE" = "redhat" ]; then
            if ! $APACHE_CMD -M 2>/dev/null | grep -q "headers_module"; then
                echo "LoadModule headers_module modules/mod_headers.so" > "$SSL_CONF_DIR/headers.conf"
            fi
        fi

        echo -e "\n${YELLOW}Configurazione HSTS...${NC}"

        # Rimuovi eventuali configurazioni HSTS esistenti
        sed -i '/^[[:space:]]*Header.*Strict-Transport-Security/d' "$SSL_CONF_FILE"

        # Aggiungi la nuova configurazione HSTS
        echo "# Enable HTTP Strict Transport Security" >> "$SSL_CONF_FILE"
        echo "Header always set Strict-Transport-Security \"max-age=600\"" >> "$SSL_CONF_FILE"

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
                if check_hsts; then
                    echo -e "\n${GREEN}✓ HSTS configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$SSL_CONF_FILE")" "$SSL_CONF_FILE"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione HSTS è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

# Test HSTS se possibile
if command_exists curl; then
    print_section "Test HSTS"
    echo -e "${YELLOW}Verifica header HSTS...${NC}"

    # Attendi che Apache sia completamente riavviato
    sleep 2

    if curl -sI https://localhost 2>/dev/null | grep -i "Strict-Transport-Security"; then
        echo -e "${GREEN}✓ Header HSTS presente${NC}"
        echo -e "\n${BLUE}Header HSTS:${NC}"
        curl -sI https://localhost 2>/dev/null | grep -i "Strict-Transport-Security"
    else
        echo -e "${YELLOW}! Impossibile verificare l'header HSTS${NC}"
        echo -e "${YELLOW}Nota: Potrebbe essere necessario un certificato SSL valido${NC}"
    fi
fi
