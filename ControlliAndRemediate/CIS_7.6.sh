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

print_section "CIS Control 7.6 - Verifica SSL Renegotiation"

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
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/mods-enabled"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
    if [ ! -f "$SSL_CONF_FILE" ]; then
        SSL_CONF_FILE="/etc/apache2/mods-available/ssl.conf"
    fi
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione SSL Renegotiation"

# Funzione per verificare la configurazione della rinegoziazione SSL
check_ssl_renegotiation() {
    echo "Controllo configurazione SSL Renegotiation..."

    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi

    # Cerca direttiva SSLInsecureRenegotiation
    if egrep -q '(^[[:space:]]*SSLInsecureRenegotiation)' "$SSL_CONF_FILE"; then
        local renegotiation_setting=$(grep "^[[:space:]]*SSLInsecureRenegotiation" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale: ${NC}$renegotiation_setting"

        if echo "$renegotiation_setting" | grep -qi " on"; then
            echo -e "${RED}✗ SSLInsecureRenegotiation è abilitato${NC}"
            issues_found+=("insecure_renegotiation_enabled")
        else
            echo -e "${GREEN}✓ SSLInsecureRenegotiation è correttamente disabilitato${NC}"
        fi
    else
        echo -e "${YELLOW}! SSLInsecureRenegotiation non configurato esplicitamente${NC}"
        issues_found+=("no_renegotiation_config")
    fi

    # Verifica configurazione mod_ssl
    if $APACHE_CMD -M 2>/dev/null | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL caricato${NC}"
    else
        echo -e "${RED}✗ Modulo SSL non caricato${NC}"
        issues_found+=("no_ssl_module")
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_ssl_renegotiation

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione della rinegoziazione SSL.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.6
        backup_dir="/root/ssl_renegotiation_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"

        echo -e "\n${YELLOW}Configurazione SSLInsecureRenegotiation...${NC}"

        # Cerca e sostituisci/aggiungi SSLInsecureRenegotiation
        if grep -q "^[[:space:]]*SSLInsecureRenegotiation" "$SSL_CONF_FILE"; then
            sed -i 's/^[[:space:]]*SSLInsecureRenegotiation.*/SSLInsecureRenegotiation off/' "$SSL_CONF_FILE"
        else
            echo "SSLInsecureRenegotiation off" >> "$SSL_CONF_FILE"
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
                if check_ssl_renegotiation; then
                    echo -e "\n${GREEN}✓ SSL Renegotiation configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione della rinegoziazione SSL è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza della rinegoziazione SSL:${NC}"
echo -e "${BLUE}- La rinegoziazione SSL insicura può portare a attacchi Man-in-the-Middle${NC}"
echo -e "${BLUE}- SSLInsecureRenegotiation deve essere sempre disabilitato${NC}"
echo -e "${BLUE}- Questa impostazione protegge da vulnerabilità CVE-2009-3555${NC}"
echo -e "${BLUE}- Verificare la compatibilità con client legacy${NC}"

# Test SSL se possibile
if command_exists openssl && command_exists curl; then
    print_section "Test Connessione SSL"
    echo -e "${YELLOW}Tentativo di connessione SSL al server locale...${NC}"

    # Attendi che Apache sia completamente riavviato
    sleep 2

    if curl -k -v https://localhost/ 2>&1 | grep -q "SSL connection using"; then
        echo -e "${GREEN}✓ Connessione SSL stabilita${NC}"
        echo -e "\n${BLUE}Dettagli connessione:${NC}"
        curl -k -v https://localhost/ 2>&1 | grep "SSL connection using"
    else
        echo -e "${RED}✗ Impossibile stabilire una connessione SSL${NC}"
    fi
fi
