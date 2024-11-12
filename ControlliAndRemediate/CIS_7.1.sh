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

print_section "Verifica CIS 7.1: Installazione moduli SSL/NSS"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    APACHE_CONFIG_DIR="/etc/httpd"
    SSL_CONF_DIR="/etc/httpd/conf.d"
    SSL_PACKAGE="mod_ssl"
    NSS_PACKAGE="mod_nss"
    OPENSSL_PACKAGE="openssl"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONFIG_DIR="/etc/apache2"
    SSL_CONF_DIR="/etc/apache2/mods-enabled"
    SSL_PACKAGE="libapache2-mod-ssl"
    NSS_PACKAGE=""  # NSS non è tipicamente usato su Debian/Ubuntu
    OPENSSL_PACKAGE="openssl"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Moduli SSL/NSS"

# Funzione per verificare i moduli SSL/NSS
check_ssl_modules() {
    local found_ssl=false
    local found_nss=false
    local modules_output

    echo "Controllo moduli SSL/NSS..."

    # Ottieni lista moduli
    modules_output=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

    # Verifica SSL
    if echo "$modules_output" | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL trovato${NC}"
        found_ssl=true
    else
        echo -e "${RED}✗ Modulo SSL non trovato${NC}"
        issues_found+=("no_ssl_module")
    fi

    # Verifica NSS (solo per RedHat)
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        if echo "$modules_output" | grep -q "nss_module"; then
            echo -e "${GREEN}✓ Modulo NSS trovato${NC}"
            found_nss=true
        else
            echo -e "${YELLOW}! Modulo NSS non trovato (opzionale)${NC}"
        fi
    fi

    # Verifica OpenSSL
    if command_exists openssl; then
        echo -e "${GREEN}✓ OpenSSL installato${NC}"
    else
        echo -e "${RED}✗ OpenSSL non trovato${NC}"
        issues_found+=("no_openssl")
    fi

    # Verifica configurazione SSL
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        if [ ! -f "$SSL_CONF_DIR/ssl.conf" ]; then
            echo -e "${RED}✗ File di configurazione SSL non trovato${NC}"
            issues_found+=("no_ssl_config")
        fi
    else
        if [ ! -f "$SSL_CONF_DIR/ssl.conf" ] && [ ! -L "$SSL_CONF_DIR/ssl.load" ]; then
            echo -e "${RED}✗ Configurazione SSL non trovata${NC}"
            issues_found+=("no_ssl_config")
        fi
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_ssl_modules

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con i moduli SSL/NSS.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.1
        backup_dir="/root/apache_ssl_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"

        # Installa i pacchetti necessari
        echo -e "\n${YELLOW}Installazione moduli SSL...${NC}"

        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            # Per sistemi RedHat
            yum install -y $SSL_PACKAGE $OPENSSL_PACKAGE
            # Installa NSS se richiesto
            if [ ${#issues_found[@]} -gt 1 ]; then
                yum install -y $NSS_PACKAGE
            fi
        else
            # Per sistemi Debian/Ubuntu
            apt-get update
            apt-get install -y $SSL_PACKAGE $OPENSSL_PACKAGE
            a2enmod ssl
        fi
        # Configura SSL di base
        if [ "$SYSTEM_TYPE" = "redhat" ] && [ ! -f "$SSL_CONF_DIR/ssl.conf" ]; then
            echo -e "\n${YELLOW}Creazione configurazione SSL base...${NC}"
cat > "$SSL_CONF_DIR/ssl.conf" << EOL
LoadModule ssl_module modules/mod_ssl.so
EOL
        fi

        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_CMD -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"

            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart $APACHE_CMD; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"

            cp -r "$backup_dir"/* "$APACHE_CONFIG_DIR/"
            systemctl restart $APACHE_CMD
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ I moduli SSL/NSS sono configurati correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory configurazione SSL: $SSL_CONF_DIR"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

# Mostra versione OpenSSL
if command_exists openssl; then
    echo -e "\n${BLUE}Versione OpenSSL:${NC}"
    openssl version
fi
