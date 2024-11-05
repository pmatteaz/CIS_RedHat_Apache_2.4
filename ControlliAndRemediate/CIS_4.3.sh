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

print_section "Verifica CIS 4.3: AllowOverride Disabilitato per Directory Root del Sistema"

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

print_section "Verifica Configurazione AllowOverride"

# Funzione per verificare la configurazione di AllowOverride nella directory root
check_root_override() {
    local config_file="$1"
    local found_root=false
    local correct_config=true
    local root_section=""
    
    echo "Controllo configurazione AllowOverride in $config_file..."
    
    # Cerca la sezione Directory root
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        if [[ "$line" =~ ^"<Directory /"[[:space:]]*">"$ ]]; then
            found_root=true
            root_section="$line"$'\n'
            
            # Leggi la sezione fino alla chiusura
            while IFS= read -r section_line || [[ -n "$section_line" ]]; do
                section_line=$(echo "$section_line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
                root_section+="$section_line"$'\n'
                
                if [[ "$section_line" == "</Directory>" ]]; then
                    break
                fi
            done
            
            # Verifica AllowOverride None
            if ! echo "$root_section" | grep -q "^[[:space:]]*AllowOverride[[:space:]]*None[[:space:]]*$"; then
                correct_config=false
            fi
            
            break
        fi
    done < "$config_file"
    
    if ! $found_root; then
        echo -e "${RED}✗ Sezione <Directory /> non trovata${NC}"
        issues_found+=("no_root_section")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ AllowOverride non è configurato correttamente come None${NC}"
        issues_found+=("incorrect_override")
        return 1
    else
        echo -e "${GREEN}✓ AllowOverride è configurato correttamente come None${NC}"
        return 0
    fi
}

# Verifica la configurazione
check_root_override "$MAIN_CONFIG"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione AllowOverride.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_override_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Prepara la configurazione corretta
        if grep -q "^<Directory />" "$MAIN_CONFIG"; then
            echo -e "\n${YELLOW}Aggiornamento configurazione esistente...${NC}"
            
            # Usa sed per modificare o aggiungere AllowOverride None
            if grep -q "AllowOverride" "$MAIN_CONFIG"; then
                # Modifica la direttiva esistente
                sed -i '/<Directory \/>/,/<\/Directory>/ s/AllowOverride.*/AllowOverride None/' "$MAIN_CONFIG"
            else
                # Aggiungi la direttiva se non esiste
                sed -i '/<Directory \/>/a\    AllowOverride None' "$MAIN_CONFIG"
            fi
        else
            echo -e "\n${YELLOW}Aggiunta nuova configurazione...${NC}"
            # Aggiungi la sezione completa
            echo -e "\n<Directory />\n    AllowOverride None\n    Require all denied\n</Directory>" >> "$MAIN_CONFIG"
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
                if check_root_override "$MAIN_CONFIG"; then
                    echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
                    
                    # Test pratico
                    echo -e "\n${YELLOW}Esecuzione test di configurazione...${NC}"
                    
                    # Crea un .htaccess di test nella root
                    test_htaccess="/.htaccess"
                    if [ -w "/" ]; then
                        echo "Require all granted" > "$test_htaccess"
                        if [ -f "$test_htaccess" ]; then
                            if curl -s http://localhost/ | grep -q "403"; then
                                echo -e "${GREEN}✓ Override correttamente disabilitato - Il file .htaccess viene ignorato${NC}"
                            else
                                echo -e "${RED}✗ Il file .htaccess potrebbe ancora influenzare la configurazione${NC}"
                            fi
                            rm -f "$test_htaccess"
                        else
                            echo -e "${YELLOW}! Impossibile creare file di test${NC}"
                        fi
                    else
                        echo -e "${YELLOW}! Impossibile eseguire il test pratico - permessi insufficienti${NC}"
                    fi
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
    echo -e "\n${GREEN}✓ La configurazione AllowOverride è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione di AllowOverride per la directory root garantisce che:${NC}"
echo -e "${BLUE}- Non sia possibile sovrascrivere le configurazioni di sicurezza tramite .htaccess${NC}"
echo -e "${BLUE}- La configurazione del server rimanga centralizzata e controllata${NC}"
echo -e "${BLUE}- Si riduca il rischio di modifiche non autorizzate alla configurazione${NC}"
echo -e "${BLUE}- Le prestazioni del server siano migliori (no controllo .htaccess)${NC}"
