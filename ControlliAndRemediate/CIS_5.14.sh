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

print_section "Verifica CIS 5.14: Blocco Richieste basate su IP"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione RewriteEngine"

# Funzione per ottenere il server name configurato
get_server_name() {
    local server_name
    server_name=$(grep -i "^ServerName" "$MAIN_CONFIG" | awk '{print $2}' | head -1)
    if [ -z "$server_name" ]; then
        # Se non trovato in main config, cerca nei file inclusi
        server_name=$(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -exec grep -i "^ServerName" {} \; | head -1 | awk '{print $2}')
    fi
    echo "$server_name"
}

# Configurazione di base per il rewrite
SERVER_NAME=$(get_server_name)
if [ -z "$SERVER_NAME" ]; then
    echo -e "${YELLOW}ServerName non trovato, usando esempio.com come default${NC}"
    SERVER_NAME="esempio.com"
fi

REWRITE_CONFIG="RewriteEngine On
RewriteCond %{HTTP_HOST} !^www\.${SERVER_NAME} [NC]
RewriteCond %{REQUEST_URI} !^/error [NC]
RewriteRule ^.(.*) - [L,F]"

# Funzione per verificare la configurazione rewrite
check_rewrite_config() {
    local config_file="$1"
    local found_rewrite=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Verifica RewriteEngine On
    if ! grep -q "^RewriteEngine On" "$config_file"; then
        correct_config=false
        issues+="RewriteEngine On non trovato\n"
    else
        found_rewrite=true
    fi
    
    # Verifica RewriteCond per HTTP_HOST
    if ! grep -q "RewriteCond.*HTTP_HOST" "$config_file"; then
        correct_config=false
        issues+="RewriteCond per HTTP_HOST non trovato\n"
    fi
    
    # Verifica RewriteRule per bloccare le richieste
    if ! grep -q "RewriteRule.*\[.*F.*\]" "$config_file"; then
        correct_config=false
        issues+="RewriteRule con flag [F] non trovato\n"
    fi
    
    if ! $found_rewrite; then
        echo -e "${RED}✗ Configurazione RewriteEngine non trovata${NC}"
        issues_found+=("no_rewrite_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione rewrite non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione rewrite corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
found_rewrite_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "RewriteEngine\|RewriteCond.*HTTP_HOST" "$config_file"; then
        if check_rewrite_config "$config_file"; then
            found_rewrite_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_rewrite_config; then
    issues_found+=("no_rewrite_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione del blocco richieste IP.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_iprequest_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Verifica se mod_rewrite è abilitato
        echo -e "\n${YELLOW}Verifica modulo rewrite...${NC}"
        if ! $APACHE_CMD -M 2>/dev/null | grep -q "rewrite_module" && \
           ! apache2ctl -M 2>/dev/null | grep -q "rewrite_module"; then
            echo "Abilitazione modulo rewrite..."
            if [ -f /etc/debian_version ]; then
                a2enmod rewrite
            else
                # Per sistemi RedHat, il modulo dovrebbe essere già disponibile
                echo "LoadModule rewrite_module modules/mod_rewrite.so" >> "$MAIN_CONFIG"
            fi
        fi
        
        # Aggiungi la configurazione rewrite
        echo -e "\n${YELLOW}Aggiunta configurazione rewrite...${NC}"
        
        # Cerca configurazione esistente
        if grep -q "RewriteEngine On" "$MAIN_CONFIG"; then
            # Sostituisci la configurazione esistente
            sed -i '/RewriteEngine On/,/RewriteRule.*\[.*F.*\]/c\'"$REWRITE_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$REWRITE_CONFIG" >> "$MAIN_CONFIG"
        fi
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                # Test pratico
                echo -e "\n${YELLOW}Esecuzione test di accesso...${NC}"
                
                if command_exists curl; then
                    # Test con host header corretto
                    echo -e "Test con host header corretto..."
                    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: www.$SERVER_NAME" http://localhost/)
                    if [ "$response" = "200" ]; then
                        echo -e "${GREEN}✓ Accesso corretto consentito${NC}"
                    else
                        echo -e "${RED}✗ Accesso corretto bloccato (HTTP $response)${NC}"
                    fi
                    
                    # Test con IP diretto
                    echo -e "Test con IP diretto..."
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso IP diretto correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso IP diretto non bloccato (HTTP $response)${NC}"
                    fi
                    
                    # Test con host header non valido
                    echo -e "Test con host header non valido..."
                    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: invalid.com" http://localhost/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso con host non valido correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso con host non valido non bloccato (HTTP $response)${NC}"
                    fi
                else
                    echo -e "${YELLOW}! curl non installato, impossibile eseguire i test pratici${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            cp -r "$backup_dir"/* "$APACHE_CONFIG_DIR/"
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione del blocco richieste IP è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. ServerName configurato: $SERVER_NAME"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Il blocco delle richieste basate su IP garantisce che:${NC}"
echo -e "${BLUE}- Gli accessi siano effettuati solo tramite nome host valido${NC}"
echo -e "${BLUE}- Si prevenga l'accesso diretto tramite IP${NC}"
echo -e "${BLUE}- Si migliorino le misure di sicurezza del server${NC}"
echo -e "${BLUE}- Si controlli meglio l'accesso al contenuto web${NC}"
