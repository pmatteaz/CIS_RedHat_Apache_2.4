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

print_section "Verifica CIS 5.2: Options per Directory Web Root"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    DEFAULT_WEB_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    DEFAULT_WEB_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Ottieni il DocumentRoot effettivo dal file di configurazione
CUSTOM_ROOT=$(grep -i "^DocumentRoot" "$MAIN_CONFIG" 2>/dev/null | awk '{print $2}' | tr -d '"' | head -1)
WEB_ROOT=${CUSTOM_ROOT:-$DEFAULT_WEB_ROOT}

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione Options per Web Root"

# Lista delle options pericolose da controllare
declare -a DANGEROUS_OPTIONS=(
    "All"
    "ExecCGI"
    "FollowSymLinks"
    "Includes"
    "MultiViews"
    "Indexes"
)

# Funzione per verificare la configurazione delle Options nel web root
check_webroot_options() {
    local config_file="$1"
    local web_root="$2"
    local found_webroot=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione Options per $web_root in $config_file..."
    
    # Cerca la sezione Directory per web root
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [[ "$line" =~ ^"<Directory \"?$web_root\"?>?"$ ]]; then
            found_webroot=true
            local section=""
            
            # Leggi la sezione fino alla chiusura
            while IFS= read -r section_line || [[ -n "$section_line" ]]; do
                section_line=$(echo "$section_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                section+="$section_line"$'\n'
                
                if [[ "$section_line" == "</Directory>" ]]; then
                    break
                fi
            done
            
            # Verifica Options None
            if ! echo "$section" | grep -q "^[[:space:]]*Options[[:space:]]*None[[:space:]]*$"; then
                correct_config=false
                
                # Verifica se ci sono options pericolose
                for option in "${DANGEROUS_OPTIONS[@]}"; do
                    if echo "$section" | grep -qi "Options.*$option"; then
                        issues+="Trovata option pericolosa: $option\n"
                    fi
                done
            fi
            
            break
        fi
    done < "$config_file"
    
    if ! $found_webroot; then
        echo -e "${RED}✗ Sezione <Directory \"$web_root\"> non trovata${NC}"
        issues_found+=("no_webroot_section")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Options non è configurato correttamente${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_options")
        return 1
    else
        echo -e "${GREEN}✓ Options è configurato correttamente come None${NC}"
        return 0
    fi
}

# Verifica la configurazione
check_webroot_options "$MAIN_CONFIG" "$WEB_ROOT"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione delle Options per il web root.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_webroot_options_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Prepara la configurazione corretta
        if grep -q "^<Directory \"*$WEB_ROOT\"*>" "$MAIN_CONFIG"; then
            echo -e "\n${YELLOW}Aggiornamento configurazione esistente...${NC}"
            
            # Usa sed per modificare o aggiungere Options None
            if grep -q "Options" "$MAIN_CONFIG"; then
                # Modifica la direttiva esistente nella sezione web root
                sed -i "/<Directory \"*$WEB_ROOT\"*>/,/<\/Directory>/ s/Options.*/Options None/" "$MAIN_CONFIG"
            else
                # Aggiungi la direttiva se non esiste
                sed -i "/<Directory \"*$WEB_ROOT\"*>/a\    Options None" "$MAIN_CONFIG"
            fi
        else
            echo -e "\n${YELLOW}Aggiunta nuova configurazione...${NC}"
            # Aggiungi la sezione completa
            echo -e "\n<Directory \"$WEB_ROOT\">\n    Options None\n    AllowOverride None\n    Require all granted\n</Directory>" >> "$MAIN_CONFIG"
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
                if check_webroot_options "$MAIN_CONFIG" "$WEB_ROOT"; then
                    echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
                    
                    # Test pratici
                    echo -e "\n${YELLOW}Esecuzione test di configurazione...${NC}"
                    
                    # Crea directory e file di test
                    mkdir -p "$WEB_ROOT/test_dir"
                    echo "Test file" > "$WEB_ROOT/test_dir/test.html"
                    
                    # Test per Indexes
                    if curl -s "http://localhost/test_dir/" | grep -qi "Index of"; then
                        echo -e "${RED}✗ Directory listing ancora attivo${NC}"
                    else
                        echo -e "${GREEN}✓ Directory listing disabilitato${NC}"
                    fi
                    
                    # Test per FollowSymLinks
                    ln -s /etc/passwd "$WEB_ROOT/test_dir/test_symlink" 2>/dev/null
                    if curl -s "http://localhost/test_dir/test_symlink" | grep -q "root:"; then
                        echo -e "${RED}✗ FollowSymLinks ancora attivo${NC}"
                    else
                        echo -e "${GREEN}✓ FollowSymLinks disabilitato${NC}"
                    fi
                    
                    # Test per SSI (Server Side Includes)
                    echo "<!--#exec cmd=\"ls\" -->" > "$WEB_ROOT/test_dir/test.shtml"
                    if curl -s "http://localhost/test_dir/test.shtml" | grep -q "bin"; then
                        echo -e "${RED}✗ Server Side Includes ancora attivi${NC}"
                    else
                        echo -e "${GREEN}✓ Server Side Includes disabilitati${NC}"
                    fi
                    
                    # Pulizia file di test
                    rm -rf "$WEB_ROOT/test_dir"
                    
                else
                    echo -e "\n${RED}✗ La configurazione non è stata applicata correttamente${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$MAIN_CONFIG")" "$MAIN_CONFIG"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione delle Options per il web root è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Web Root: $WEB_ROOT"
echo "2. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione delle Options per il web root garantisce che:${NC}"
echo -e "${BLUE}- Nessuna funzionalità pericolosa sia abilitata${NC}"
echo -e "${BLUE}- Directory listing sia disabilitato${NC}"
echo -e "${BLUE}- Link simbolici non possano essere seguiti${NC}"
echo -e "${BLUE}- Server Side Includes siano disabilitati${NC}"
echo -e "${BLUE}- La sicurezza del contenuto web sia massimizzata${NC}"
