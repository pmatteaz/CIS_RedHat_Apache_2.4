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

print_section "Verifica CIS 5.12: Restrizione Accesso ai File .svn"

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

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione DirectoryMatch per .svn"

# Configurazione necessaria
SVN_CONFIG="<DirectoryMatch \"\.svn\">
    Require all denied
</DirectoryMatch>"

# Funzione per verificare la configurazione .svn
check_svn_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca la direttiva DirectoryMatch per .svn
    if grep -q "<DirectoryMatch.*\\\.svn" "$config_file"; then
        found_config=true
        
        # Verifica che includa "Require all denied"
        if ! grep -A2 "<DirectoryMatch.*\\\.svn" "$config_file" | grep -q "Require all denied"; then
            correct_config=false
            issues+="Manca 'Require all denied' nella configurazione\n"
        fi
    else
        found_config=false
        issues+="Configurazione DirectoryMatch per .svn non trovata\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione DirectoryMatch per .svn non trovata${NC}"
        issues_found+=("no_svn_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione DirectoryMatch per .svn non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione DirectoryMatch per .svn corretta${NC}"
        return 0
    fi
}

# Cerca directory SVN esistenti nel DocumentRoot
print_section "Ricerca Directory SVN"
if [ -d "$DOCUMENT_ROOT" ]; then
    echo "Cercando directory .svn in $DOCUMENT_ROOT..."
    svn_dirs=$(find "$DOCUMENT_ROOT" -type d -name ".svn")
    if [ -n "$svn_dirs" ]; then
        echo -e "${RED}✗ Trovate directory .svn:${NC}"
        echo "$svn_dirs"
        issues_found+=("svn_dirs_found")
    else
        echo -e "${GREEN}✓ Nessuna directory .svn trovata in DocumentRoot${NC}"
    fi
fi

# Verifica la configurazione in tutti i file pertinenti
found_svn_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "DirectoryMatch.*\.svn" "$config_file"; then
        if check_svn_config "$config_file"; then
            found_svn_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_svn_config; then
    issues_found+=("no_svn_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la protezione dei file .svn.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.12
        backup_dir="/root/apache_svn_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Aggiungi la configurazione per i file .svn
        echo -e "\n${YELLOW}Aggiunta configurazione per file .svn...${NC}"
        
        # Cerca configurazione esistente
        if grep -q "<DirectoryMatch.*\\\.svn" "$MAIN_CONFIG"; then
            # Sostituisci la configurazione esistente
            sed -i '/<DirectoryMatch.*"\.svn"/,/<\/DirectoryMatch>/c\'"$SVN_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$SVN_CONFIG" >> "$MAIN_CONFIG"
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
                
                # Crea una directory .svn di test
                test_dir="/var/www/html/test_svn"
                mkdir -p "$test_dir/.svn/pristine"
                echo "format" > "$test_dir/.svn/format"
                echo "Test entries" > "$test_dir/.svn/entries"
                mkdir -p "$test_dir/.svn/wc.db"
                
                if command_exists curl; then
                    # Test accesso alla directory .svn
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_svn/.svn/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso alla directory .svn correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso alla directory .svn non bloccato (HTTP $response)${NC}"
                    fi
                    
                    # Test accesso a file specifici in .svn
                    files=("format" "entries" "wc.db")
                    for file in "${files[@]}"; do
                        response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_svn/.svn/$file)
                        if [ "$response" = "403" ]; then
                            echo -e "${GREEN}✓ Accesso a .svn/$file correttamente negato${NC}"
                        else
                            echo -e "${RED}✗ Accesso a .svn/$file non bloccato (HTTP $response)${NC}"
                        fi
                    done
                else
                    echo -e "${YELLOW}! curl non installato, impossibile eseguire i test pratici${NC}"
                fi
                
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
    echo -e "\n${GREEN}✓ La protezione dei file .svn è configurata correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. DocumentRoot controllato: $DOCUMENT_ROOT"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La protezione delle directory .svn garantisce che:${NC}"
echo -e "${BLUE}- I repository SVN non siano accessibili via web${NC}"
echo -e "${BLUE}- Le informazioni sensibili del codice sorgente siano protette${NC}"
echo -e "${BLUE}- Si prevenga l'accesso a metadati e configurazioni del repository${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva dell'applicazione web${NC}"
