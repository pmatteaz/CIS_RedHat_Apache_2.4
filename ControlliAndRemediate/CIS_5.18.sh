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

print_section "Verifica CIS 5.18: Configurazione Permissions-Policy"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    SECURITY_CONFIG="$APACHE_CONFIG_DIR/conf.d/security.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    SECURITY_CONFIG="$APACHE_CONFIG_DIR/conf-available/security.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Policy richieste e loro valori predefiniti
declare -A REQUIRED_POLICIES=(
    ["geolocation"]="()"
    ["midi"]="()"
    ["sync-xhr"]="()"
    ["microphone"]="()"
    ["camera"]="()"
    ["magnetometer"]="()"
    ["gyroscope"]="()"
    ["fullscreen"]="(self)"
    ["payment"]="()"
)

# Configurazione necessaria
PERMISSIONS_CONFIG="Header always set Permissions-Policy \"geolocation=(), midi=(), sync-xhr=(), microphone=(), camera=(), magnetometer=(), gyroscope=(), fullscreen=(self), payment=()\""

print_section "Verifica Configurazione Permissions-Policy"

# Funzione per verificare la configurazione Permissions-Policy
check_permissions_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Verifica il modulo headers
    if ! httpd -M 2>/dev/null | grep -q "headers_module" && \
       ! apache2ctl -M 2>/dev/null | grep -q "headers_module"; then
        issues+="Modulo headers non caricato\n"
        issues_found+=("no_headers_module")
    fi
    
    # Cerca la direttiva Permissions-Policy
    if grep -q "Permissions-Policy" "$config_file"; then
        found_config=true
        
        # Verifica tutte le policy richieste
        for policy in "${!REQUIRED_POLICIES[@]}"; do
            if ! grep -q "Permissions-Policy.*$policy=${REQUIRED_POLICIES[$policy]}" "$config_file"; then
                correct_config=false
                issues+="Policy $policy non configurata correttamente\n"
            fi
        done
    else
        found_config=false
        issues+="Permissions-Policy non trovato\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione Permissions-Policy non trovata${NC}"
        issues_found+=("no_permissions_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione Permissions-Policy non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione Permissions-Policy corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
found_permissions_config=false
for config_file in "$MAIN_CONFIG" "$SECURITY_CONFIG"; do
    if [ -f "$config_file" ]; then
        if check_permissions_config "$config_file"; then
            found_permissions_config=true
            break
        fi
    fi
done

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_permissions_config; then
    issues_found+=("no_permissions_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione Permissions-Policy.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.18
        backup_dir="/root/apache_permissions_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for config_file in "$MAIN_CONFIG" "$SECURITY_CONFIG"; do
            if [ -f "$config_file" ]; then
                cp -p "$config_file" "$backup_dir/"
            fi
        done
        
        # Verifica/Abilita il modulo headers
        echo -e "\n${YELLOW}Verifica modulo headers...${NC}"
        if ! httpd -M 2>/dev/null | grep -q "headers_module" && \
           ! apache2ctl -M 2>/dev/null | grep -q "headers_module"; then
            echo "Abilitazione modulo headers..."
            if [ -f /etc/debian_version ]; then
                a2enmod headers
            else
                # Per sistemi RedHat
                echo "LoadModule headers_module modules/mod_headers.so" >> "$MAIN_CONFIG"
            fi
        fi
        
        # Determina il file di configurazione da utilizzare
        config_to_modify="$SECURITY_CONFIG"
        if [ ! -f "$SECURITY_CONFIG" ]; then
            mkdir -p "$(dirname "$SECURITY_CONFIG")"
            touch "$SECURITY_CONFIG"
            
            # Per Debian/Ubuntu, abilita il file di configurazione
            if [ -f /etc/debian_version ]; then
                a2enconf security
            fi
        fi
        
        # Aggiungi la configurazione Permissions-Policy
        echo -e "\n${YELLOW}Aggiunta configurazione Permissions-Policy...${NC}"
        if grep -q "Permissions-Policy" "$config_to_modify"; then
            # Sostituisci la configurazione esistente
            sed -i '/Permissions-Policy/c\'"$PERMISSIONS_CONFIG" "$config_to_modify"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$PERMISSIONS_CONFIG" >> "$config_to_modify"
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
                echo -e "\n${YELLOW}Esecuzione test dell'header Permissions-Policy...${NC}"
                
                if command_exists curl; then
                    response=$(curl -s -I http://localhost | grep -i "Permissions-Policy")
                    if [ -n "$response" ]; then
                        echo -e "${GREEN}✓ Header Permissions-Policy presente${NC}"
                        echo "Header attuale: $response"
                        
                        # Verifica tutte le policy richieste
                        for policy in "${!REQUIRED_POLICIES[@]}"; do
                            if echo "$response" | grep -q "$policy=${REQUIRED_POLICIES[$policy]}"; then
                                echo -e "${GREEN}✓ Policy $policy configurata correttamente${NC}"
                            else
                                echo -e "${RED}✗ Policy $policy non configurata correttamente${NC}"
                            fi
                        done
                        
                        # Test funzionale con JavaScript
                        echo -e "\n${YELLOW}Creazione pagina di test per verifica funzionale...${NC}"
                        test_page="/var/www/html/permissions-test.html"
                        cat > "$test_page" << EOF
                        <html>
                        <head><title>Permissions Policy Test</title></head>
                        <body>
                            <script>
                                // Test geolocation
                                navigator.permissions.query({name:'geolocation'})
                                    .then(result => console.log('Geolocation:', result.state));
                                
                                // Test camera
                                navigator.permissions.query({name:'camera'})
                                    .then(result => console.log('Camera:', result.state));
                            </script>
                        </body>
                        </html>
EOF
                        
                        echo -e "${YELLOW}È stata creata una pagina di test in $test_page${NC}"
                        echo -e "${YELLOW}Aprire la pagina in un browser e controllare la console per verificare${NC}"
                        echo -e "${YELLOW}che le policy siano effettivamente applicate${NC}"
                        
                    else
                        echo -e "${RED}✗ Header Permissions-Policy non trovato${NC}"
                    fi
                else
                    echo -e "${YELLOW}! curl non installato, impossibile eseguire il test pratico${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            for config_file in "$MAIN_CONFIG" "$SECURITY_CONFIG"; do
                if [ -f "$backup_dir/$(basename "$config_file")" ]; then
                    cp -p "$backup_dir/$(basename "$config_file")" "$config_file"
                fi
            done
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione Permissions-Policy è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione controllati:"
[ -f "$MAIN_CONFIG" ] && echo "   - $MAIN_CONFIG"
[ -f "$SECURITY_CONFIG" ] && echo "   - $SECURITY_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione di Permissions-Policy garantisce che:${NC}"
echo -e "${BLUE}- Le funzionalità del browser siano controllate in modo granulare${NC}"
echo -e "${BLUE}- Si limitino le funzionalità potenzialmente pericolose${NC}"
echo -e "${BLUE}- Si migliori la privacy degli utenti${NC}"
echo -e "${BLUE}- Si rispettino le best practice di sicurezza moderne${NC}"

# Pulizia file di test alla fine
rm -f "/var/www/html/permissions-test.html" 2>/dev/null
