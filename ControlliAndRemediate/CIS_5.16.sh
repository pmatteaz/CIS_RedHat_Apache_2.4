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

print_section "Verifica CIS 5.16: Configurazione X-Frame-Options"

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

print_section "Verifica Configurazione X-Frame-Options"

# Configurazione necessaria
XFRAME_CONFIG='Header always set X-Frame-Options "SAMEORIGIN"'

# Funzione per verificare la configurazione X-Frame-Options
check_xframe_config() {
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
    
    # Cerca la direttiva X-Frame-Options
    if grep -q "X-Frame-Options" "$config_file"; then
        found_config=true
        
        # Verifica che sia configurato correttamente
        if ! grep -q 'Header.*always.*set.*X-Frame-Options.*"SAMEORIGIN"' "$config_file"; then
            correct_config=false
            issues+="X-Frame-Options non configurato correttamente\n"
        fi
    else
        found_config=false
        issues+="X-Frame-Options non trovato\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione X-Frame-Options non trovata${NC}"
        issues_found+=("no_xframe_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione X-Frame-Options non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione X-Frame-Options corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
found_xframe_config=false
for config_file in "$MAIN_CONFIG" "$SECURITY_CONFIG"; do
    if [ -f "$config_file" ]; then
        if check_xframe_config "$config_file"; then
            found_xframe_config=true
            break
        fi
    fi
done

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_xframe_config; then
    issues_found+=("no_xframe_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione X-Frame-Options.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_xframe_backup_$timestamp"
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
        
        # Aggiungi la configurazione X-Frame-Options
        echo -e "\n${YELLOW}Aggiunta configurazione X-Frame-Options...${NC}"
        if grep -q "X-Frame-Options" "$config_to_modify"; then
            # Sostituisci la configurazione esistente
            sed -i '/X-Frame-Options/c\'"$XFRAME_CONFIG" "$config_to_modify"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$XFRAME_CONFIG" >> "$config_to_modify"
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
                echo -e "\n${YELLOW}Esecuzione test dell'header X-Frame-Options...${NC}"
                
                if command_exists curl; then
                    response=$(curl -s -I http://localhost | grep -i "X-Frame-Options")
                    if echo "$response" | grep -qi "SAMEORIGIN"; then
                        echo -e "${GREEN}✓ Header X-Frame-Options configurato correttamente${NC}"
                        echo "Header attuale: $response"
                    else
                        echo -e "${RED}✗ Header X-Frame-Options non trovato o non corretto${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione X-Frame-Options è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione controllati:"
[ -f "$MAIN_CONFIG" ] && echo "   - $MAIN_CONFIG"
[ -f "$SECURITY_CONFIG" ] && echo "   - $SECURITY_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione di X-Frame-Options garantisce che:${NC}"
echo -e "${BLUE}- Il sito sia protetto contro attacchi di clickjacking${NC}"
echo -e "${BLUE}- Le pagine possano essere visualizzate in frame solo dallo stesso dominio${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva dell'applicazione web${NC}"
echo -e "${BLUE}- Si rispettino le best practice di sicurezza moderne${NC}"
