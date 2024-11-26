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

print_section "Verifica CIS 5.10: Restrizione Accesso ai File .ht*"

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

print_section "Verifica Configurazione FilesMatch per .ht*"

# Configurazione necessaria
HT_CONFIG="<FilesMatch \"^\.ht\">
    Require all denied
</FilesMatch>"

# Funzione per verificare la configurazione .ht*
check_ht_config() {
    local config_file="$1"
    local found_config=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca la direttiva FilesMatch per .ht*
    if grep -q "<FilesMatch.*\"\^\\\.ht\"" "$config_file"; then
        found_config=true
        
        # Verifica che includa "Require all denied"
        if ! grep -A2 "<FilesMatch.*\"\^\\\.ht\"" "$config_file" | grep -q "Require all denied"; then
            correct_config=false
            issues+="Manca 'Require all denied' nella configurazione\n"
        fi
    else
        found_config=false
        issues+="Configurazione FilesMatch per .ht* non trovata\n"
    fi
    
    if ! $found_config; then
        echo -e "${RED}✗ Configurazione FilesMatch per .ht* non trovata${NC}"
        issues_found+=("no_ht_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione FilesMatch per .ht* non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione FilesMatch per .ht* corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
found_ht_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "FilesMatch.*\.ht" "$config_file"; then
        if check_ht_config "$config_file"; then
            found_ht_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_ht_config; then
    issues_found+=("no_ht_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la protezione dei file .ht*.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.10
        backup_dir="/root/apache_htfiles_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Aggiungi la configurazione per i file .ht*
        echo -e "\n${YELLOW}Aggiunta configurazione per file .ht*...${NC}"
        
        # Cerca configurazione esistente
        if grep -q "<FilesMatch.*\"\^\\\.ht\"" "$MAIN_CONFIG"; then
            # Sostituisci la configurazione esistente
            sed -i '/<FilesMatch.*"^\.ht"/,/<\/FilesMatch>/c\'"$HT_CONFIG" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\n$HT_CONFIG" >> "$MAIN_CONFIG"
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
                
                # Crea un file .htaccess di test
                test_dir="/var/www/html/test_ht"
                mkdir -p "$test_dir"
                echo "Require all granted" > "$test_dir/.htaccess"
                echo "Test content" > "$test_dir/.htpasswd"
                
                if command_exists curl; then
                    # Test accesso a .htaccess
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_ht/.htaccess)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso a .htaccess correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso a .htaccess non bloccato (HTTP $response)${NC}"
                    fi
                    
                    # Test accesso a .htpasswd
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/test_ht/.htpasswd)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Accesso a .htpasswd correttamente negato${NC}"
                    else
                        echo -e "${RED}✗ Accesso a .htpasswd non bloccato (HTTP $response)${NC}"
                    fi
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
    echo -e "\n${GREEN}✓ La protezione dei file .ht* è configurata correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La protezione dei file .ht* garantisce che:${NC}"
echo -e "${BLUE}- I file di configurazione .htaccess siano protetti${NC}"
echo -e "${BLUE}- I file .htpasswd con le password siano inaccessibili${NC}"
echo -e "${BLUE}- Si prevenga l'accesso a file di configurazione sensibili${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server${NC}"
