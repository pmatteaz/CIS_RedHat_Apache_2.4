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

print_section "CIS Control 7.7 - Verifica Compressione SSL"

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

print_section "Verifica Configurazione Compressione SSL"

# Funzione per verificare la configurazione della compressione SSL
check_ssl_compression() {
    echo "Controllo configurazione compressione SSL..."
    
    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Cerca direttiva SSLCompression
    if grep -q "^[[:space:]]*SSLCompression" "$SSL_CONF_FILE"; then
        local compression_setting=$(grep "^[[:space:]]*SSLCompression" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale: ${NC}$compression_setting"
        
        if echo "$compression_setting" | grep -qi "on"; then
            echo -e "${RED}✗ SSLCompression è abilitato${NC}"
            issues_found+=("compression_enabled")
        else
            echo -e "${GREEN}✓ SSLCompression è correttamente disabilitato${NC}"
        fi
    else
        echo -e "${YELLOW}! SSLCompression non configurato esplicitamente${NC}"
        issues_found+=("no_compression_config")
    fi
    
    # Verifica configurazione mod_ssl
    if $APACHE_CMD -M 2>/dev/null | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL caricato${NC}"
        
        # Verifica versione OpenSSL
        if command_exists openssl; then
            local openssl_version=$(openssl version)
            echo -e "${BLUE}Versione OpenSSL: ${NC}$openssl_version"
            
            # Verifica se OpenSSL supporta la compressione
            if openssl s_client -help 2>&1 | grep -q "compression"; then
                echo -e "${YELLOW}! OpenSSL supporta la compressione - importante disabilitarla a livello Apache${NC}"
            fi
        fi
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
check_ssl_compression

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione della compressione SSL.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/ssl_compression_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"
        
        echo -e "\n${YELLOW}Configurazione SSLCompression...${NC}"
        
        # Cerca e sostituisci/aggiungi SSLCompression
        if grep -q "^[[:space:]]*SSLCompression" "$SSL_CONF_FILE"; then
            sed -i 's/^[[:space:]]*SSLCompression.*/SSLCompression off/' "$SSL_CONF_FILE"
        else
            echo "SSLCompression off" >> "$SSL_CONF_FILE"
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
                if check_ssl_compression; then
                    echo -e "\n${GREEN}✓ Compressione SSL configurata correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione della compressione SSL è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza della compressione SSL:${NC}"
echo -e "${BLUE}- La compressione SSL può rendere il server vulnerabile all'attacco CRIME${NC}"
echo -e "${BLUE}- SSLCompression deve essere sempre disabilitato${NC}"
echo -e "${BLUE}- La disabilitazione potrebbe impattare leggermente sulle performance${NC}"
echo -e "${BLUE}- Non influisce sulla compressione a livello HTTP (gzip)${NC}"

# Test SSL se possibile
if command_exists openssl && command_exists curl; then
    print_section "Test Connessione SSL"
    echo -e "${YELLOW}Tentativo di connessione SSL al server locale...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    echo -e "\n${BLUE}Test della compressione SSL:${NC}"
    if openssl s_client -connect localhost:443 -compress 2>&1 | grep -q "Compression: NONE"; then
        echo -e "${GREEN}✓ Compressione SSL disabilitata correttamente${NC}"
    else
        echo -e "${YELLOW}! Impossibile verificare lo stato della compressione${NC}"
    fi
fi
