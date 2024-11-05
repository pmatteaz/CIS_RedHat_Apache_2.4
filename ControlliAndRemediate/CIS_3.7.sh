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

print_section "Verifica CIS 3.7: Sicurezza della Directory Core Dump"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_GROUP="apache"
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_CONF_FILE="$APACHE_CONFIG_DIR/conf/httpd.conf"
    CORE_DUMP_DIR="/var/log/httpd/cores"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_CONF_FILE="$APACHE_CONFIG_DIR/apache2.conf"
    CORE_DUMP_DIR="/var/log/apache2/cores"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_coredump_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        cp "$APACHE_CONF_FILE" "$backup_dir/"
        
print_section "Verifica Configurazione Core Dump e remediatation"
        
# Aggiorna la configurazione Apache
        if grep -q "^CoreDumpDirectory" "$APACHE_CONF_FILE"; then
            echo -e "\n${YELLOW}Commento la configurazione CoreDumpDirectory...${NC}"
            sed -i 's/^CoreDumpDirectory/#CoreDumpDirectory/' "$APACHE_CONF_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Configurazione rimossa con successo${NC}"
            else
                echo -e "${RED}✗ Errore nella rimozione della configurazione${NC}"
            fi
        else
            echo -e "\n${GREEN}Aggiornamento configurazione CoreDumpDirectory non esistente...${NC}"
        fi
        
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Remediation eseguita"
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_CONFIG_DIR/bin/httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$APACHE_CONF_FILE")" "$APACHE_CONF_FILE"
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        
        echo "Controllo configurazione finale..."
        if grep -q "^CoreDumpDirectory $CORE_DUMP_DIR" "$APACHE_CONF_FILE"; then
            echo -e "${GREEN}✓ CoreDumpDirectory correttamente configurata${NC}"
        else
            echo -e "${RED}✗ CoreDumpDirectory non configurata correttamente${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $APACHE_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup della configurazione: $backup_dir"
fi

