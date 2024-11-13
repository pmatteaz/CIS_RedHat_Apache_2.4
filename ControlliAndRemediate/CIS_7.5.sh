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

print_section "CIS Control 7.5 - Verifica Disabilitazione Cipher Suite Deboli"

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

# Array di cipher suite deboli da cercare
declare -a weak_ciphers=(
    "NULL" "aNULL" "eNULL" 
    "DES" "3DES" "RC4" "RC2"
    "MD5" "EXP" "EXPORT" "ADH" 
    "LOW" "MEDIUM" "SHA1" "PSK"
    "DSS" "SEED" "IDEA" "CAMELLIA"
)

print_section "Verifica Cipher Suites"

# Funzione per verificare la configurazione delle cipher suite
check_ssl_ciphers() {
    local has_cipher_suite=false
    local has_honor_cipher_order=false
    local ciphers_secure=true
    
    echo "Controllo configurazione cipher suites SSL/TLS..."
    
    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Cerca direttiva SSLCipherSuite
    if grep -q "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE"; then
        has_cipher_suite=true
        echo -e "${GREEN}✓ Direttiva SSLCipherSuite trovata${NC}"
        
        # Verifica contenuto SSLCipherSuite
        local cipher_line=$(grep "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale cipher suite: ${NC}$cipher_line"
        
        # Verifica presenza di cipher suite deboli
        for weak_cipher in "${weak_ciphers[@]}"; do
            if echo "$cipher_line" | grep -qi "$weak_cipher"; then
                echo -e "${RED}✗ Trovata cipher suite debole: $weak_cipher${NC}"
                issues_found+=("weak_cipher_$weak_cipher")
                ciphers_secure=false
            fi
        done
        
        # Verifica se la configurazione include cipher suite forti
        if ! echo "$cipher_line" | grep -qE "EECDH|AESGCM|EDH"; then
            echo -e "${RED}✗ Nessuna cipher suite forte trovata${NC}"
            issues_found+=("no_strong_ciphers")
            ciphers_secure=false
        fi
    else
        echo -e "${RED}✗ Direttiva SSLCipherSuite non trovata${NC}"
        issues_found+=("no_cipher_suite")
        ciphers_secure=false
    fi
    
    # Verifica SSLHonorCipherOrder
    if grep -q "^[[:space:]]*SSLHonorCipherOrder[[:space:]]*on" "$SSL_CONF_FILE"; then
        has_honor_cipher_order=true
        echo -e "${GREEN}✓ SSLHonorCipherOrder è abilitato${NC}"
    else
        echo -e "${RED}✗ SSLHonorCipherOrder non è configurato correttamente${NC}"
        issues_found+=("no_honor_cipher_order")
    fi
    
    # Verifica supporto ECDHE e AEAD con OpenSSL
    if command_exists openssl; then
        echo -e "\n${BLUE}Verifica supporto cipher suite con OpenSSL:${NC}"
        if openssl ciphers -v 'EECDH+AESGCM' 2>/dev/null | grep -q "ECDHE"; then
            echo -e "${GREEN}✓ OpenSSL supporta ECDHE e AESGCM${NC}"
        else
            echo -e "${RED}✗ OpenSSL potrebbe non supportare alcune cipher suite moderne${NC}"
            issues_found+=("openssl_limited_support")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_ssl_ciphers

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione delle cipher suite SSL/TLS.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/ssl_cipher_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"
        
        echo -e "\n${YELLOW}Aggiornamento configurazione cipher suite...${NC}"
        
        # Prepara le nuove configurazioni
        SECURE_CIPHERS="ALL:!EXP:!NULL:!LOW:!SSLv2:!RC4:!aNULL"
        
        # Cerca e sostituisci/aggiungi SSLCipherSuite
        if grep -q "^[[:space:]]*SSLCipherSuite" "$SSL_CONF_FILE"; then
            sed -i "s/^[[:space:]]*SSLCipherSuite.*/SSLCipherSuite $SECURE_CIPHERS/" "$SSL_CONF_FILE"
        else
            echo "SSLCipherSuite $SECURE_CIPHERS" >> "$SSL_CONF_FILE"
        fi
        
        # Cerca e sostituisci/aggiungi SSLHonorCipherOrder
        if grep -q "^[[:space:]]*SSLHonorCipherOrder" "$SSL_CONF_FILE"; then
            sed -i "s/^[[:space:]]*SSLHonorCipherOrder.*/SSLHonorCipherOrder on/" "$SSL_CONF_FILE"
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
                if check_ssl_ciphers; then
                    echo -e "\n${GREEN}✓ Cipher suite configurate correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale delle cipher suite${NC}"
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
    echo -e "\n${GREEN}✓ Le cipher suite SSL/TLS sono configurate correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza delle cipher suite:${NC}"
echo -e "${BLUE}- Utilizzare solo cipher suite forti (EECDH+AESGCM, EDH+AESGCM)${NC}"
echo -e "${BLUE}- Abilitare SSLHonorCipherOrder per preferire cipher suite lato server${NC}"
echo -e "${BLUE}- Evitare cipher suite obsolete o non sicure${NC}"
echo -e "${BLUE}- Verificare periodicamente la sicurezza delle cipher suite${NC}"

# Test della configurazione SSL se possibile
if command_exists openssl && command_exists curl; then
    print_section "Test Connessione SSL"
    echo -e "${YELLOW}Tentativo di connessione SSL al server locale...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    if curl -k -v https://localhost/ 2>&1 | grep -q "SSL connection using"; then
        echo -e "${GREEN}✓ Connessione SSL stabilita${NC}"
        echo -e "\n${BLUE}Cipher suite in uso:${NC}"
        curl -k -v https://localhost/ 2>&1 | grep "SSL connection using"
    else
        echo -e "${RED}✗ Impossibile stabilire una connessione SSL${NC}"
    fi
fi

# Mostra cipher suite disponibili
if command_exists openssl; then
    print_section "Cipher Suite Disponibili"
    echo -e "${BLUE}Cipher suite supportate dal sistema:${NC}"
    openssl ciphers -v 'EECDH+AESGCM:EDH+AESGCM' | sed 's/:/ /g'
fi
