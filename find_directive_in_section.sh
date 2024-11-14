#!/bin/bash

# Funzione per cercare una direttiva in una sezione specifica
# Parametri:
# $1 = file di configurazione
# $2 = nome della sezione (es. "<VirtualHost *:80>")
# $3 = direttiva da cercare (es. "DocumentRoot")
# Return:
# 0 se trovata, 1 se non trovata
# Output:
# Stampa il valore della direttiva se trovata

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

find_directive_in_section() {
    local config_file="$1"
    local section_name="$2"
    local directive="$3"
    local in_section=0
    local section_depth=0
    local result=""

    # Verifica che il file esista
    if [ ! -f "$config_file" ]; then
        echo "${RED}Errore: File $config_file non trovato${NC}" >&2
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

# Funzione per test con output colorato
test_find_directive() {
    local config_file="$1"
    local section="$2"
    local directive="$3"
    
    echo -e "\n${BLUE}Cerco '$directive' nella sezione '$section' del file '$config_file'${NC}"
    
    local result
    if result=$(find_directive_in_section "$config_file" "$section" "$directive"); then
        echo -e "${GREEN}Trovato:$NC $result"
        return 0
    else
        echo -e "${RED}Non trovato$NC"
        return 1
    fi
}

# Esempio di file di configurazione per test
create_test_config() {
    local test_file="/tmp/test_config.conf"
    cat > "$test_file" << 'EOL'
# Configurazione di test
ServerRoot "/etc/httpd"

<VirtualHost *:80>
    ServerAdmin webmaster@example.com
    DocumentRoot /var/www/html
    ServerName example.com
    ErrorLog logs/error_log
    CustomLog logs/access_log combined
</VirtualHost>

<VirtualHost *:443>
    ServerAdmin admin@example.com
    DocumentRoot /var/www/secure
    ServerName secure.example.com
    SSLEngine on
</VirtualHost>

<Directory "/var/www/html">
    Options Indexes FollowSymLinks
    AllowOverride None
    Require all granted
</Directory>
EOL
    echo "$test_file"
}

# Funzione principale per eseguire i test
main() {
    # Crea file di test
    local test_file=$(create_test_config)
    
    # Esegue alcuni test
    test_find_directive "$test_file" "<VirtualHost *:80>" "DocumentRoot"
    test_find_directive "$test_file" "<VirtualHost *:443>" "DocumentRoot"
    test_find_directive "$test_file" "<VirtualHost *:80>" "ServerAdmin"
    test_find_directive "$test_file" "<Directory \"/var/www/html\">" "Options"
    test_find_directive "$test_file" "<VirtualHost *:80>" "NonExistent"
    
    # Pulisce il file di test
    rm -f "$test_file"
}

# Se lo script viene eseguito direttamente (non sourced), esegue i test
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main
fi
