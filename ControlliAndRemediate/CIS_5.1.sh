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

# Funzione per cercare una direttiva in una sezione specifica
# Parametri:
# $1 = file di configurazione
# $2 = nome della sezione (es. "<VirtualHost *:80>")
# $3 = direttiva da cercare (es. "DocumentRoot")
# Return:
# 0 se trovata, 1 se non trovata
# Output:
# Stampa il valore della direttiva se trovata

find_directive_in_section() {
    local config_file="$1"
    local section_name="$2"
    local directive="$3"
    local in_section=0
    local section_depth=0
    local result=""

    # Verifica che il file esista
    if [ ! -f "$config_file" ]; then
        echo "Errore: File $config_file non trovato" >&2
        return 1
    fi
    # Legge il file riga per riga
    while IFS= read -r line || [ -n "$line" ]; do
        # Rimuove spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

        # Salta linee vuote e commenti
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Controlla inizio sezione
        if [[ "$line" =~ (^<[^/]) ]]; then
            # Se è la sezione che cerchiamo
            if [[ "$line" == "$section_name"* ]]; then
                in_section=1
            fi
            ((section_depth++))
        fi

        # Controlla fine sezione
        if [[ "$line" =~ (^</[^>]+>) ]]; then
            ((section_depth--))
            if [ $section_depth -lt 0 ]; then
                section_depth=0
            fi
            # Se usciamo dalla sezione che ci interessa
            if [ $in_section -eq 1 ] && [ $section_depth -eq 0 ]; then
                in_section=0
            fi
        fi

        # Se siamo nella sezione corretta, cerca la direttiva
        if [ $in_section -eq 1 ]; then
            # Controlla se la riga inizia con la direttiva
            if [[ "$line" =~ ^${directive}[[:space:]] ]]; then
                # Estrae il valore della direttiva
                result=$(echo "$line" | sed "s/^${directive}[[:space:]]*//")
                echo "$result"
                return 0
            fi
        fi
    done < "$config_file"

    # Se non trova nulla
    return 1
}

print_section "Verifica CIS 5.1: Options per Directory Root del Sistema"

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

print_section "Verifica Configurazione Options"

# Lista delle options pericolose da controllare
declare -a DANGEROUS_OPTIONS=(
    "All"
    "ExecCGI"
    "FollowSymLinks"
    "Includes"
    "MultiViews"
    "Indexes"
)

# Funzione per verificare la configurazione delle Options nella directory root
check_root_options() {
    local config_file="$1"
    local found_root=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione Options in $config_file..."
    
    # Cerca la sezione Directory root
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
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
    
    if ! $found_root; then
        echo -e "${RED}✗ Sezione <Directory /> non trovata${NC}"
        issues_found+=("no_root_section")
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
check_root_options "$MAIN_CONFIG"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione delle Options.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_options_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Prepara la configurazione corretta
        if grep -q "^<Directory />" "$MAIN_CONFIG"; then
            echo -e "\n${YELLOW}Aggiornamento configurazione esistente...${NC}"
            
            # Usa sed per modificare o aggiungere Options None
            if grep -q "Options" "$MAIN_CONFIG"; then
                # Modifica la direttiva esistente
                sed -i '/<Directory \/>/,/<\/Directory>/ s/Options.*/Options None/' "$MAIN_CONFIG"
            else
                # Aggiungi la direttiva se non esiste
                sed -i '/<Directory \/>/a\    Options None' "$MAIN_CONFIG"
            fi
        else
            echo -e "\n${YELLOW}Aggiunta nuova configurazione...${NC}"
            # Aggiungi la sezione completa
            echo -e "\n<Directory />\n    Options None\n    AllowOverride None\n    Require all denied\n</Directory>" >> "$MAIN_CONFIG"
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
                if check_root_options "$MAIN_CONFIG"; then
                    echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
                    
                    # Test pratici
                    echo -e "\n${YELLOW}Esecuzione test di configurazione...${NC}"
                    
                    # Test per Indexes
                    if curl -s "http://localhost/" | grep -qi "Index of"; then
                        echo -e "${RED}✗ Directory listing ancora attivo${NC}"
                    else
                        echo -e "${GREEN}✓ Directory listing disabilitato${NC}"
                    fi
                    
                    # Test per FollowSymLinks
                    if [ -d "/var/www/html" ]; then
                        ln -s /etc/passwd /var/www/html/test_symlink 2>/dev/null
                        if curl -s "http://localhost/test_symlink" | grep -q "root:"; then
                            echo -e "${RED}✗ FollowSymLinks ancora attivo${NC}"
                        else
                            echo -e "${GREEN}✓ FollowSymLinks disabilitato${NC}"
                        fi
                        rm -f /var/www/html/test_symlink
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
    echo -e "\n${GREEN}✓ La configurazione delle Options è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione delle Options per la directory root garantisce che:${NC}"
echo -e "${BLUE}- Nessuna funzionalità pericolosa sia abilitata per default${NC}"
echo -e "${BLUE}- Directory listing sia disabilitato${NC}"
echo -e "${BLUE}- Link simbolici non possano essere seguiti${NC}"
echo -e "${BLUE}- Server Side Includes siano disabilitati${NC}"
echo -e "${BLUE}- CGI scripts non possano essere eseguiti al di fuori delle directory designate${NC}"
