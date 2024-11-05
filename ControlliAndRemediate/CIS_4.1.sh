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

print_section "Verifica CIS 4.1: Accesso alla Directory Root del Sistema Operativo"

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

print_section "Verifica Configurazione Directory Root"

# Funzione per verificare la configurazione della directory root
check_root_directory_config() {
    local config_file="$1"
    local found_root=false
    local correct_config=true
    local issues=""
    
    # Cerca la sezione Directory per root
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Se troviamo l'inizio della sezione Directory root
        if [[ "$line" =~ ^"<Directory /"[[:space:]]*">"$ ]]; then
            found_root=true
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
            
            if ! echo "$section" | grep -q "Require all denied"; then
                correct_config=false
                issues+="Require all denied non presente\n"
            fi
            
            break
        fi
    done < "$config_file"
    
    if ! $found_root; then
        echo -e "${RED}✗ Sezione <Directory /> non trovata${NC}"
        issues_found+=("no_root_section")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione directory root non corretta:${NC}"
        echo -e "${RED}$(echo -e "$issues")${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione directory root corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione
echo "Controllo configurazione in $MAIN_CONFIG..."
check_root_directory_config "$MAIN_CONFIG"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione della directory root.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_root_access_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Prepara la nuova configurazione
        ROOT_CONFIG="<Directory />\n    Options None\n    AllowOverride None\n    Require all denied\n</Directory>"
        
        # Modifica il file di configurazione
        if grep -q "^<Directory />" "$MAIN_CONFIG"; then
            # Sostituisci la sezione esistente
            echo -e "\n${YELLOW}Aggiornamento configurazione esistente...${NC}"
            sed -i '/<Directory \/>/,/<\/Directory>/c\'"$ROOT_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova sezione
            echo -e "\n${YELLOW}Aggiunta nuova configurazione...${NC}"
            echo -e "\n$ROOT_CONFIG" >> "$MAIN_CONFIG"
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
                if check_root_directory_config "$MAIN_CONFIG"; then
                    echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
                else
                    echo -e "\n${RED}✗ La configurazione non è stata applicata correttamente${NC}"
                fi
                
                # Test pratico
                echo -e "\n${YELLOW}Esecuzione test di accesso...${NC}"
                if command_exists curl; then
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ L'accesso alla directory root è correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ L'accesso alla directory root potrebbe non essere completamente bloccato${NC}"
                    fi
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
    echo -e "\n${GREEN}✓ La configurazione della directory root è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione della directory root garantisce che:${NC}"
echo -e "${BLUE}- L'accesso al filesystem del sistema operativo sia negato per default${NC}"
echo -e "${BLUE}- Non sia possibile eseguire override delle configurazioni${NC}"
echo -e "${BLUE}- Nessuna opzione speciale sia abilitata${NC}"
echo -e "${BLUE}- La sicurezza del server sia rafforzata contro accessi non autorizzati${NC}"
