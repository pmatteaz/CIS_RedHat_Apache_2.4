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

print_section "Verifica CIS 5.13: Restrizione Accesso File con Estensioni Inappropriate"

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

# Array delle estensioni da bloccare
DENIED_EXTENSIONS=(
    "bak"
    "config"
    "sql"
    "fla"
    "psd"
    "ini"
    "log"
    "sh"
    "inc"
    "swp"
    "dist"
    "old"
    "original"
    "template"
    "php~"
    "php#"
)

# Configurazione necessaria
EXTENSIONS_REGEX=$(IFS="|"; echo "${DENIED_EXTENSIONS[*]}")
FILESMATCH_CONFIG="<FilesMatch \"^.*\.(${EXTENSIONS_REGEX})\$\">
    Require all denied
</FilesMatch>"

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione FilesMatch per Estensioni"

# Funzione per verificare la configurazione delle estensioni
check_extensions_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca la direttiva FilesMatch per le estensioni
    if grep -q "<FilesMatch.*\\\.\(.*\)\\$" "$config_file"; then
        found_config=true
        
        # Verifica che includa tutte le estensioni necessarie
        for ext in "${DENIED_EXTENSIONS[@]}"; do
            if ! grep -q "$ext" "$config_file"; then
                correct_config=false
                issues+="Estensione $ext non bloccata\n"
            fi
        done
        
        # Verifica che includa "Require all denied"
        if ! grep -A2 "<FilesMatch.*\\\.\(.*\)\\$" "$config_file" | grep -q "Require all denied"; then
            correct_config=false
            issues+="Manca 'Require all denied' nella configurazione\n"
        fi
    else
        found_config=false
        issues+="Configurazione FilesMatch per estensioni non trovata\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione FilesMatch per estensioni non trovata${NC}"
        issues_found+=("no_extensions_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione FilesMatch per estensioni non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione FilesMatch per estensioni corretta${NC}"
        return 0
    fi
}

# Cerca file con estensioni non consentite nel DocumentRoot
print_section "Ricerca File con Estensioni non Consentite"
if [ -d "$DOCUMENT_ROOT" ]; then
    echo "Cercando file con estensioni non consentite in $DOCUMENT_ROOT..."
    for ext in "${DENIED_EXTENSIONS[@]}"; do
        found_files=$(find "$DOCUMENT_ROOT" -type f -name "*.$ext" 2>/dev/null)
        if [ -n "$found_files" ]; then
            echo -e "${RED}✗ Trovati file con estensione .$ext:${NC}"
            echo "$found_files"
            issues_found+=("dangerous_files_found")
        fi
    done
fi

# Verifica la configurazione in tutti i file pertinenti
found_extensions_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "FilesMatch.*\\.\(" "$config_file"; then
        if check_extensions_config "$config_file"; then
            found_extensions_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_extensions_config; then
    issues_found+=("no_extensions_config")
fi

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
        
        # Cerca configurazione esistente
        if grep -q "<FilesMatch.*\\.\(" "$MAIN_CONFIG"; then
            # Sostituisci la configurazione esistente
            sed -i '/<FilesMatch.*\.\(/,/<\/FilesMatch>/c\'"$FILESMATCH_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$FILESMATCH_CONFIG" >> "$MAIN_CONFIG"
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
                
                # Crea file di test per ogni estensione
                test_dir="/var/www/html/test_extensions"
                mkdir -p "$test_dir"
                
                for ext in "${DENIED_EXTENSIONS[@]}"; do
                    echo "Test content" > "$test_dir/test.$ext"
                    
                    if command_exists curl; then
                        response=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost/test_extensions/test.$ext")
                        if [ "$response" = "403" ]; then
                            echo -e "${GREEN}✓ Accesso a .$ext correttamente negato${NC}"
                        else
                            echo -e "${RED}✗ Accesso a .$ext non bloccato (HTTP $response)${NC}"
                        fi
                    fi
                done
                
                # Pulizia file di test
                rm -rf "$test_dir"
                
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
    echo -e "\n${GREEN}✓ La protezione delle estensioni file è configurata correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. DocumentRoot controllato: $DOCUMENT_ROOT"
echo "3. Estensioni bloccate:"
for ext in "${DENIED_EXTENSIONS[@]}"; do
    echo "   - .$ext"
done
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La protezione delle estensioni file garantisce che:${NC}"
echo -e "${BLUE}- File sensibili e di backup non siano accessibili via web${NC}"
echo -e "${BLUE}- File di configurazione e log siano protetti${NC}"
echo -e "${BLUE}- Script e file temporanei siano bloccati${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server${NC}"
