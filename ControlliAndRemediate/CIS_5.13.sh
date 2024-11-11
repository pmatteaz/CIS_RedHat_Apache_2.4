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

print_section "Verifica CIS 5.13: Configurazione Restrittiva Accesso File"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    DOCUMENT_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    DOCUMENT_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array delle estensioni permesse
ALLOWED_EXTENSIONS=(
    "html"
    "htm"
    "css"
    "js"
    "jpg"
    "jpeg"
    "png"
    "gif"
    "svg"
    "ico"
    "pdf"
    "xml"
    "txt"
    "webp"
)

# Configurazione necessaria
EXTENSIONS_REGEX=$(IFS="|"; echo "${ALLOWED_EXTENSIONS[*]}")
FILESMATCH_CONFIG="# Blocca tutti i file per default
<Files \"*\">
    Require all denied
</Files>

# Permetti solo le estensioni specificate
<FilesMatch \"^.*\.(${EXTENSIONS_REGEX})\$\">
    Require all granted
</FilesMatch>

# Blocca esplicitamente l'accesso ai file che iniziano con punto
<FilesMatch \"^\.\">
    Require all denied
</FilesMatch>

# Blocca l'accesso ai file di backup e temporanei
<FilesMatch \"(~|\#|\%|\$)$\">
    Require all denied
</FilesMatch>"

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione FilesMatch"

# Funzione per verificare la configurazione delle estensioni
check_extensions_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""

    echo "Controllo configurazione in $config_file..."

    # Cerca la configurazione di base che blocca tutti i file
    if ! grep -q '<Files "\*">' "$config_file" || ! grep -q 'Require all denied' "$config_file"; then
        correct_config=false
        issues+="Manca configurazione base di blocco\n"
    fi

    # Cerca la direttiva FilesMatch per le estensioni permesse
    if egrep -q '(<FilesMatch.*\\\.\(.*\)\\$)' "$config_file"; then
        found_config=true

        # Verifica che includa tutte le estensioni necessarie
        for ext in "${ALLOWED_EXTENSIONS[@]}"; do
            if ! grep -q "$ext" "$config_file"; then
                correct_config=false
                issues+="Estensione $ext non configurata\n"
            fi
        done
    else
        found_config=false
        issues+="Configurazione FilesMatch per estensioni permesse non trovata\n"
    fi

    if ! $found_config; then
        echo -e "${RED}✗ Configurazione FilesMatch non trovata${NC}"
        issues_found+=("no_extensions_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione FilesMatch non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione FilesMatch corretta${NC}"
        return 0
    fi
}

# Cerca file con estensioni non permesse nel DocumentRoot
print_section "Ricerca File con Estensioni non Permesse"
if [ -d "$DOCUMENT_ROOT" ]; then
    echo "Cercando file con estensioni non permesse in $DOCUMENT_ROOT..."
    find "$DOCUMENT_ROOT" -type f | while read -r file; do
        ext="${file##*.}"
        if [[ ! " ${ALLOWED_EXTENSIONS[@]} " =~ " ${ext} " ]] && [[ -n "$ext" ]]; then
            echo -e "${RED}✗ Trovato file non permesso: $file${NC}"
            issues_found+=("dangerous_files_found")
        fi
    done
fi

# Verifica la configurazione in tutti i file pertinenti
found_extensions_config=false
while IFS= read -r -d '' config_file; do
    if egrep -q '(FilesMatch|Files)' "$config_file"; then
        if check_extensions_config "$config_file"; then
            found_extensions_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la protezione delle estensioni file.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.13
        backup_dir="/root/apache_extensions_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"

        # Aggiungi la configurazione per le estensioni file
        echo -e "\n${YELLOW}Aggiunta configurazione per estensioni file...${NC}"

        # Rimuovi configurazioni esistenti e aggiungi la nuova
        sed -i '/<Files.*>/,/<\/Files>/d' "$MAIN_CONFIG"
        sed -i '/<FilesMatch.*>/,/<\/FilesMatch>/d' "$MAIN_CONFIG"
        echo -e "\n$FILESMATCH_CONFIG" >> "$MAIN_CONFIG"

        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"

            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                # Test pratico
                print_section "Test di Verifica"
                test_dir="/var/www/html/test_extensions"
                mkdir -p "$test_dir"

                # Test file permessi
                echo "Test allowed" > "$test_dir/test.html"
                # Test file non permessi
                echo "Test denied" > "$test_dir/test.php"

                if command_exists curl; then
                    # Test file permesso
                    response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/test_extensions/test.html")
                    if [ "$response" = "200" ]; then
                        echo -e "${GREEN}✓ Accesso a file HTML correttamente permesso${NC}"
                    fi

                    # Test file non permesso
                    response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/test_extensions/test.php")
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso a file PHP correttamente negato${NC}"
                    fi
                fi

                # Pulizia
                rm -rf "$test_dir"
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp -r "$backup_dir"/* "$APACHE_CONFIG_DIR/"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La protezione delle estensioni file è configurata correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. DocumentRoot controllato: $DOCUMENT_ROOT"
echo "3. Estensioni permesse:"
for ext in "${ALLOWED_EXTENSIONS[@]}"; do
    echo "   - .$ext"
done
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La nuova configurazione di sicurezza:${NC}"
echo -e "${BLUE}- Blocca l'accesso a TUTTI i file per default${NC}"
echo -e "${BLUE}- Permette solo le estensioni specificamente consentite${NC}"
echo -e "${BLUE}- Blocca l'accesso a file nascosti (dot files)${NC}"
echo -e "${BLUE}- Blocca l'accesso a file di backup e temporanei${NC}"
echo -e "${BLUE}- Migliora significativamente la sicurezza del server web${NC}"
