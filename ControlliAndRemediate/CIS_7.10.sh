#!/bin/bash
# Verificare se basta mettere conf in ssl.conf

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

print_section "CIS Control 7.10 - Verifica OCSP Stapling"

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
    CACHE_DIR="/var/run/httpd"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/mods-enabled"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
    if [ ! -f "$SSL_CONF_FILE" ]; then
        SSL_CONF_FILE="/etc/apache2/mods-available/ssl.conf"
    fi
    CACHE_DIR="/var/run/apache2"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione OCSP Stapling"

# Funzione per verificare la configurazione OCSP Stapling
check_ocsp_stapling() {
    echo "Controllo configurazione OCSP Stapling..."
    
    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Verifica modulo SSL
    if $APACHE_CMD -M 2>/dev/null | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL caricato${NC}"
    else
        echo -e "${RED}✗ Modulo SSL non caricato${NC}"
        issues_found+=("no_ssl_module")
    fi

    # Verifica SSLUseStapling
    if grep -q "^[[:space:]]*SSLUseStapling[[:space:]]*on" "$SSL_CONF_FILE"; then
        echo -e "${GREEN}✓ OCSP Stapling è abilitato${NC}"
    else
        echo -e "${RED}✗ OCSP Stapling non è abilitato${NC}"
        issues_found+=("stapling_disabled")
    fi

    # Verifica SSLStaplingCache
    if grep -q "^[[:space:]]*SSLStaplingCache" "$SSL_CONF_FILE"; then
        echo -e "${GREEN}✓ Cache OCSP Stapling configurata${NC}"
        
        # Verifica la directory della cache
        if [ ! -d "$CACHE_DIR" ]; then
            echo -e "${RED}✗ Directory cache OCSP non trovata${NC}"
            issues_found+=("no_cache_dir")
        else
            echo -e "${GREEN}✓ Directory cache OCSP esistente${NC}"
        fi
    else
        echo -e "${RED}✗ Cache OCSP Stapling non configurata${NC}"
        issues_found+=("no_stapling_cache")
    fi
    
    # Verifica permessi directory cache
    if [ -d "$CACHE_DIR" ]; then
        local cache_perms=$(stat -c "%a" "$CACHE_DIR")
        if [ "$cache_perms" != "755" ]; then
            echo -e "${RED}✗ Permessi directory cache non corretti${NC}"
            issues_found+=("wrong_cache_perms")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_ocsp_stapling

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione OCSP Stapling.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.10
        backup_dir="/root/ocsp_stapling_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"
        
        echo -e "\n${YELLOW}Configurazione OCSP Stapling...${NC}"
        
        # Crea directory cache se non esiste
        if [ ! -d "$CACHE_DIR" ]; then
            mkdir -p "$CACHE_DIR"
            chmod 755 "$CACHE_DIR"
            if [ "$SYSTEM_TYPE" = "redhat" ]; then
                chown root:apache "$CACHE_DIR"
            else
                chown root:www-data "$CACHE_DIR"
            fi
        else
        chmod 755 "$CACHE_DIR"
        fi
        
        # Configura OCSP Stapling
        if grep -q "^[[:space:]]*SSLUseStapling" "$SSL_CONF_FILE"; then
            sed -i 's/^[[:space:]]*SSLUseStapling.*/SSLUseStapling on/' "$SSL_CONF_FILE"
        else
            echo "SSLUseStapling on" >> "$SSL_CONF_FILE"
        fi
        
        # Configura cache OCSP
        if grep -q "^[[:space:]]*SSLStaplingCache" "$SSL_CONF_FILE"; then
            sed -i "s|^[[:space:]]*SSLStaplingCache.*|SSLStaplingCache \"shmcb:$CACHE_DIR/ocsp(128000)\"|" "$SSL_CONF_FILE"
        else
            echo "SSLStaplingCache \"shmcb:$CACHE_DIR/ocsp(128000)\"" >> "$SSL_CONF_FILE"
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
                if check_ocsp_stapling; then
                    echo -e "\n${GREEN}✓ OCSP Stapling configurato correttamente${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione OCSP Stapling è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
echo "2. Directory cache OCSP: $CACHE_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza OCSP Stapling:${NC}"
echo -e "${BLUE}- OCSP Stapling migliora le performance delle connessioni SSL${NC}"
echo -e "${BLUE}- Riduce il carico sui server OCSP delle CA${NC}"
echo -e "${BLUE}- Migliora la privacy degli utenti${NC}"
echo -e "${BLUE}- Verificare che il certificato SSL supporti OCSP${NC}"

# Test OCSP Stapling se possibile
if command_exists openssl; then
    print_section "Test OCSP Stapling"
    echo -e "${YELLOW}Verifica supporto OCSP Stapling...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    if openssl s_client -connect localhost:443 -status -servername localhost 2>/dev/null | grep -q "OCSP response:"; then
        echo -e "${GREEN}✓ OCSP Stapling funzionante${NC}"
        echo -e "\n${BLUE}Dettagli risposta OCSP:${NC}"
        openssl s_client -connect localhost:443 -status -servername localhost 2>/dev/null | grep -A 10 "OCSP response:"
    else
        echo -e "${YELLOW}! Impossibile verificare OCSP Stapling${NC}"
        echo -e "${YELLOW}Nota: Potrebbe essere necessario un certificato valido con supporto OCSP${NC}"
    fi
fi
