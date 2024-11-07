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

print_section "CIS Control 7.12 - Verifica Forward Secrecy Ciphers"

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

# Lista delle cipher suite per Forward Secrecy
FORWARD_SECRECY_CIPHERS="ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-DSS-AES128-GCM-SHA256:kEDH+AESGCM:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA384:ECDHE-RSA-AES256-SHA:ECDHE-ECDSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-DSS-AES128-SHA256:DHE-RSA-AES256-SHA256:DHE-DSS-AES256-SHA:DHE-RSA-AES256-SHA"

print_section "Verifica Configurazione Forward Secrecy"

# Funzione per verificare la configurazione delle cipher suite
check_forward_secrecy() {
    echo "Controllo configurazione Forward Secrecy..."
    
    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Verifica mod_ssl
    if $APACHE_CMD -M 2>/dev/null | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL caricato${NC}"
    else
        echo -e "${RED}✗ Modulo SSL non caricato${NC}"
        issues_found+=("no_ssl_module")
    fi
    
    # Cerca SSLCipherSuite
    if grep -q "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE"; then
        local cipher_line=$(grep "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale cipher suite: ${NC}$cipher_line"
        
        # Verifica presenza di cipher suite con Forward Secrecy
        local has_ecdhe=false
        local has_dhe=false
        
        if echo "$cipher_line" | grep -qE "ECDHE|DHE"; then
            echo -e "${GREEN}✓ Trovate cipher suite con Forward Secrecy${NC}"
            if echo "$cipher_line" | grep -q "ECDHE"; then
                echo -e "${GREEN}✓ ECDHE cipher suite abilitate${NC}"
                has_ecdhe=true
            fi
            if echo "$cipher_line" | grep -q "DHE"; then
                echo -e "${GREEN}✓ DHE cipher suite abilitate${NC}"
                has_dhe=true
            fi
        else
            echo -e "${RED}✗ Nessuna cipher suite con Forward Secrecy trovata${NC}"
            issues_found+=("no_forward_secrecy")
        fi
        
        if ! $has_ecdhe; then
            echo -e "${RED}✗ ECDHE cipher suite non abilitate${NC}"
            issues_found+=("no_ecdhe")
        fi
        if ! $has_dhe; then
            echo -e "${RED}✗ DHE cipher suite non abilitate${NC}"
            issues_found+=("no_dhe")
        fi
        
        # Verifica SSLHonorCipherOrder
        if grep -q "^[[:space:]]*SSLHonorCipherOrder[[:space:]]*on" "$SSL_CONF_FILE"; then
            echo -e "${GREEN}✓ SSLHonorCipherOrder è abilitato${NC}"
        else
            echo -e "${RED}✗ SSLHonorCipherOrder non è abilitato${NC}"
            issues_found+=("no_honor_cipher_order")
        fi
    else
        echo -e "${RED}✗ SSLCipherSuite non configurato${NC}"
        issues_found+=("no_cipher_suite")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_forward_secrecy

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione Forward Secrecy.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.12
        backup_dir="/root/forward_secrecy_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"
        
        echo -e "\n${YELLOW}Configurazione Forward Secrecy...${NC}"
        
        # Aggiorna/aggiungi SSLCipherSuite
        if grep -q "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE"; then
            sed -i "s|^[[:space:]]*SSLCipherSuite.*|SSLCipherSuite $FORWARD_SECRECY_CIPHERS|" "$SSL_CONF_FILE"
        else
            echo "SSLCipherSuite $FORWARD_SECRECY_CIPHERS" >> "$SSL_CONF_FILE"
        fi
        
        # Aggiorna/aggiungi SSLHonorCipherOrder
        if grep -q "^[[:space:]]*SSLHonorCipherOrder" "$SSL_CONF_FILE"; then
            sed -i 's/^[[:space:]]*SSLHonorCipherOrder.*/SSLHonorCipherOrder on/' "$SSL_CONF_FILE"
        else
            echo "SSLHonorCipherOrder on" >> "$SSL_CONF_FILE"
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
                if check_forward_secrecy; then
                    echo -e "\n${GREEN}✓ Forward Secrecy configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione Forward Secrecy è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza Forward Secrecy:${NC}"
echo -e "${BLUE}- Forward Secrecy protegge le comunicazioni passate${NC}"
echo -e "${BLUE}- ECDHE offre migliori performance rispetto a DHE${NC}"
echo -e "${BLUE}- SSLHonorCipherOrder assicura l'uso delle cipher suite più sicure${NC}"
echo -e "${BLUE}- Verificare la compatibilità con i client legacy${NC}"

# Test SSL se possibile
if command_exists openssl && command_exists curl; then
    print_section "Test Cipher Suites"
    echo -e "${YELLOW}Verifica cipher suite disponibili...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    echo -e "\n${BLUE}Test connessione SSL:${NC}"
    if curl -vk https://localhost 2>&1 | grep -i "SSL connection using"; then
        curl -vk https://localhost 2>&1 | grep -i "SSL connection using"
        echo -e "${GREEN}✓ Connessione SSL stabilita${NC}"
    else
        echo -e "${YELLOW}! Impossibile verificare la cipher suite in uso${NC}"
    fi
    
    echo -e "\n${BLUE}Cipher suite supportate dal server:${NC}"
    openssl ciphers -v 'EECDH:EDH' | sort | uniq
fi
