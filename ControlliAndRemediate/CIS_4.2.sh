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

print_section "Verifica CIS 4.2: Accesso Appropriato al Contenuto Web"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    DEFAULT_DOC_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    DEFAULT_DOC_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione DocumentRoot"

# Funzione per ottenere il DocumentRoot configurato
get_document_root() {
    local doc_root
    doc_root=$(grep -i "^DocumentRoot" "$MAIN_CONFIG" | awk '{print $2}' | tr -d '"' | head -1)
    if [ -z "$doc_root" ]; then
        echo "$DEFAULT_DOC_ROOT"
    else
        echo "$doc_root"
    fi
}

DOCUMENT_ROOT=$(get_document_root)

# Funzione per verificare la configurazione del DocumentRoot
check_docroot_config() {
    local config_file="$1"
    local doc_root="$2"
    local found_docroot=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione per DocumentRoot: $doc_root"
    
    # Cerca la sezione Directory per DocumentRoot
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Se troviamo l'inizio della sezione Directory per DocumentRoot
        if [[ "$line" =~ ^"<Directory \"?$doc_root\"?>"$ ]]; then
            found_docroot=true
            local section=""
            
            # Leggi la sezione fino alla chiusura
            while IFS= read -r section_line || [[ -n "$section_line" ]]; do
                section_line=$(echo "$section_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                section+="$section_line"$'\n'
                
                if [[ "$section_line" == "</Directory>" ]]; then
                    break
                fi
            done
            
            # Verifica le direttive corrette
            if ! echo "$section" | grep -q "Options None"; then
                correct_config=false
                issues+="Options non impostato a None\n"
            fi
            
            if ! echo "$section" | grep -q "AllowOverride None"; then
                correct_config=false
                issues+="AllowOverride non impostato a None\n"
            fi
            
            if ! echo "$section" | grep -q "Require all granted"; then
                correct_config=false
                issues+="Require all granted non presente\n"
            fi
            
            break
        fi
    done < "$config_file"
    
    if ! $found_docroot; then
        echo -e "${RED}✗ Sezione <Directory \"$doc_root\"> non trovata${NC}"
        issues_found+=("no_docroot_section")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione DocumentRoot non corretta:${NC}"
        echo -e "${RED}$(echo -e "$issues")${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione DocumentRoot corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione
check_docroot_config "$MAIN_CONFIG" "$DOCUMENT_ROOT"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione del DocumentRoot.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_docroot_access_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Prepara la nuova configurazione
        DOCROOT_CONFIG="<Directory \"$DOCUMENT_ROOT\">\n    Options None\n    AllowOverride None\n    Require all granted\n</Directory>"
        
        # Modifica il file di configurazione
        if grep -q "^<Directory \"*$DOCUMENT_ROOT\"*>" "$MAIN_CONFIG"; then
            # Sostituisci la sezione esistente
            echo -e "\n${YELLOW}Aggiornamento configurazione esistente...${NC}"
            sed -i '/<Directory "'"$DOCUMENT_ROOT"'">/,/<\/Directory>/c\'"$DOCROOT_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova sezione
            echo -e "\n${YELLOW}Aggiunta nuova configurazione...${NC}"
            echo -e "\n$DOCROOT_CONFIG" >> "$MAIN_CONFIG"
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
                if check_docroot_config "$MAIN_CONFIG" "$DOCUMENT_ROOT"; then
                    echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
                else
                    echo -e "\n${RED}✗ La configurazione non è stata applicata correttamente${NC}"
                fi
                
                # Test pratico
                echo -e "\n${YELLOW}Esecuzione test di accesso...${NC}"
                if command_exists curl; then
                    # Crea un file di test
                    test_file="$DOCUMENT_ROOT/test.html"
                    echo "Test file" > "$test_file"
                    
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test.html)
                    if [ "$response" = "200" ]; then
                        echo -e "${GREEN}✓ L'accesso al contenuto web è correttamente consentito${NC}"
                    else
                        echo -e "${RED}✗ L'accesso al contenuto web potrebbe essere bloccato${NC}"
                    fi
                    
                    # Rimuovi il file di test
                    rm -f "$test_file"
                else
                    echo -e "${YELLOW}! curl non installato, impossibile eseguire il test di accesso${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione del DocumentRoot è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. DocumentRoot: $DOCUMENT_ROOT"
echo "2. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione del DocumentRoot garantisce che:${NC}"
echo -e "${BLUE}- L'accesso al contenuto web sia appropriatamente consentito${NC}"
echo -e "${BLUE}- Non siano abilitate opzioni potenzialmente pericolose${NC}"
echo -e "${BLUE}- Non sia possibile sovrascrivere le configurazioni di sicurezza${NC}"
echo -e "${BLUE}- Solo il contenuto web intenzionale sia accessibile${NC}"
