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

print_section "Verifica CIS 5.7: Restrizione Metodi HTTP"

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

# Array dei metodi HTTP permessi
ALLOWED_METHODS=("GET" "POST" "HEAD")

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione LimitExcept"

# Funzione per verificare la configurazione LimitExcept
check_limitexcept_config() {
    local config_file="$1"
    local found_limitexcept=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca direttive LimitExcept
    if grep -q "<LimitExcept" "$config_file"; then
        found_limitexcept=true
        
        while read -r line; do
            # Verifica che includa solo i metodi permessi
            for method in "${ALLOWED_METHODS[@]}"; do
                if ! echo "$line" | grep -q "$method"; then
                    correct_config=false
                    issues+="Metodo $method non trovato nella configurazione LimitExcept\n"
                fi
            done
            
            # Verifica che includa "Require all denied"
            if ! grep -q "Require all denied" "$config_file"; then
                correct_config=false
                issues+="'Require all denied' non trovato nella configurazione LimitExcept\n"
            fi
        done < <(grep -A 5 "<LimitExcept" "$config_file")
    else
        found_limitexcept=false
        issues+="Direttiva LimitExcept non trovata\n"
    fi
    
    if ! $found_limitexcept; then
        echo -e "${RED}✗ Configurazione LimitExcept non trovata${NC}"
        issues_found+=("no_limitexcept")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione LimitExcept non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione LimitExcept corretta${NC}"
        return 0
    fi
}

# Cerca in tutti i file di configurazione
find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -exec grep -l "LimitExcept" {} \; | while read -r config_file; do
    check_limitexcept_config "$config_file"
done

# Se non è stata trovata nessuna configurazione, considera anche questo un problema
if [ ${#issues_found[@]} -eq 0 ] && ! grep -r "LimitExcept" "$APACHE_CONFIG_DIR" >/dev/null 2>&1; then
    issues_found+=("no_limitexcept")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione dei metodi HTTP.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_methods_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Prepara la nuova configurazione
        LIMITEXCEPT_CONFIG="<Location />\n    <LimitExcept GET POST HEAD>\n        Require all denied\n    </LimitExcept>\n</Location>"
        
        echo -e "\n${YELLOW}Aggiunta configurazione LimitExcept...${NC}"
        
        # Verifica se esiste già una configurazione Location
        if grep -q "<Location />" "$MAIN_CONFIG"; then
            # Aggiungi la configurazione all'interno della sezione Location esistente
            sed -i "/<Location \/>/,/<\/Location>/c\\<Location />\n    <LimitExcept GET POST HEAD>\n        Require all denied\n    </LimitExcept>\n</Location>" "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione alla fine del file
            echo -e "\n$LIMITEXCEPT_CONFIG" >> "$MAIN_CONFIG"
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
                
                # Verifica la presenza della nuova configurazione
                if grep -q "<LimitExcept GET POST HEAD>" "$MAIN_CONFIG" && \
                   grep -q "Require all denied" "$MAIN_CONFIG"; then
                    echo -e "${GREEN}✓ Configurazione LimitExcept aggiunta correttamente${NC}"
                    
                    # Test pratici
                    echo -e "\n${YELLOW}Esecuzione test dei metodi HTTP...${NC}"
                    
                    # Test dei metodi permessi
                    for method in "${ALLOWED_METHODS[@]}"; do
                        response=$(curl -X "$method" -s -o /dev/null -w "%{http_code}" http://localhost/)
                        if [ "$response" != "403" ]; then
                            echo -e "${GREEN}✓ Metodo $method permesso${NC}"
                        else
                            echo -e "${RED}✗ Metodo $method bloccato inaspettatamente${NC}"
                        fi
                    done
                    
                    # Test dei metodi non permessi
                    for method in "PUT" "DELETE" "TRACE" "OPTIONS"; do
                        response=$(curl -X "$method" -s -o /dev/null -w "%{http_code}" http://localhost/)
                        if [ "$response" = "403" ]; then
                            echo -e "${GREEN}✓ Metodo $method correttamente bloccato${NC}"
                        else
                            echo -e "${RED}✗ Metodo $method non bloccato correttamente${NC}"
                        fi
                    done
                    
                else
                    echo -e "${RED}✗ Configurazione LimitExcept non trovata dopo la remediation${NC}"
                fi
                
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
    echo -e "\n${GREEN}✓ La configurazione dei metodi HTTP è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. Metodi HTTP permessi: ${ALLOWED_METHODS[*]}"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta limitazione dei metodi HTTP garantisce che:${NC}"
echo -e "${BLUE}- Solo i metodi essenziali siano permessi${NC}"
echo -e "${BLUE}- Si riduca la superficie di attacco${NC}"
echo -e "${BLUE}- Si prevengano metodi potenzialmente pericolosi${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server web${NC}"
