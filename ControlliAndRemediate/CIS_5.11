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

print_section "Verifica CIS 5.11: Restrizione Accesso ai File .git"

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

print_section "Verifica Configurazione DirectoryMatch per .git"

# Configurazione necessaria
GIT_CONFIG="<DirectoryMatch \"\.git\">
    Require all denied
</DirectoryMatch>"

# Funzione per verificare la configurazione .git
check_git_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca la direttiva DirectoryMatch per .git
    if grep -q "<DirectoryMatch.*\\\.git" "$config_file"; then
        found_config=true
        
        # Verifica che includa "Require all denied"
        if ! grep -A2 "<DirectoryMatch.*\\\.git" "$config_file" | grep -q "Require all denied"; then
            correct_config=false
            issues+="Manca 'Require all denied' nella configurazione\n"
        fi
    else
        found_config=false
        issues+="Configurazione DirectoryMatch per .git non trovata\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione DirectoryMatch per .git non trovata${NC}"
        issues_found+=("no_git_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione DirectoryMatch per .git non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione DirectoryMatch per .git corretta${NC}"
        return 0
    fi
}

# Cerca repository git esistenti nel DocumentRoot
print_section "Ricerca Repository Git"
if [ -d "$DOCUMENT_ROOT" ]; then
    echo "Cercando directory .git in $DOCUMENT_ROOT..."
    git_dirs=$(find "$DOCUMENT_ROOT" -type d -name ".git")
    if [ -n "$git_dirs" ]; then
        echo -e "${RED}✗ Trovate directory .git:${NC}"
        echo "$git_dirs"
        issues_found+=("git_dirs_found")
    else
        echo -e "${GREEN}✓ Nessuna directory .git trovata in DocumentRoot${NC}"
    fi
fi

# Verifica la configurazione in tutti i file pertinenti
found_git_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "DirectoryMatch.*\.git" "$config_file"; then
        if check_git_config "$config_file"; then
            found_git_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_git_config; then
    issues_found+=("no_git_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la protezione dei file .git.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.11
        backup_dir="/root/apache_git_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Aggiungi la configurazione per i file .git
        echo -e "\n${YELLOW}Aggiunta configurazione per file .git...${NC}"
        
        # Cerca configurazione esistente
        if grep -q "<DirectoryMatch.*\\\.git" "$MAIN_CONFIG"; then
            # Sostituisci la configurazione esistente
            sed -i '/<DirectoryMatch.*"\.git"/,/<\/DirectoryMatch>/c\'"$GIT_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$GIT_CONFIG" >> "$MAIN_CONFIG"
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
                
                # Crea una directory .git di test
                test_dir="/var/www/html/test_git"
                mkdir -p "$test_dir/.git"
                echo "ref: refs/heads/master" > "$test_dir/.git/HEAD"
                echo "Test config" > "$test_dir/.git/config"
                
                if command_exists curl; then
                    # Test accesso alla directory .git
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_git/.git/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso alla directory .git correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso alla directory .git non bloccato (HTTP $response)${NC}"
                    fi
                    
                    # Test accesso a file specifici in .git
                    files=("config" "HEAD" "index")
                    for file in "${files[@]}"; do
                        response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_git/.git/$file)
                        if [ "$response" = "403" ]; then
                            echo -e "${GREEN}✓ Accesso a .git/$file correttamente negato${NC}"
                        else
                            echo -e "${RED}✗ Accesso a .git/$file non bloccato (HTTP $response)${NC}"
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
    echo -e "\n${GREEN}✓ La protezione dei file .git è configurata correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. DocumentRoot controllato: $DOCUMENT_ROOT"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La protezione delle directory .git garantisce che:${NC}"
echo -e "${BLUE}- I repository git non siano accessibili via web${NC}"
echo -e "${BLUE}- Le informazioni sensibili del codice sorgente siano protette${NC}"
echo -e "${BLUE}- Si prevenga l'accesso a metadati e configurazioni del repository${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva dell'applicazione web${NC}"
