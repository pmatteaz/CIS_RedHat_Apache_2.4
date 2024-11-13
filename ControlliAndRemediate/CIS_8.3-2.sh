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

print_section "CIS Control 8.3 - Verifica Rimozione Contenuti Predefiniti Apache"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    HTML_DIR="/var/www/html"
    HTTPD_DIR="/usr/share/httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    DEFAULT_FILES=(
        "/var/www/html/index.html"
        "/usr/share/httpd/icons/"
        "/usr/share/httpd/manual/"
        "/usr/share/httpd/error/"
    )
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    HTML_DIR="/var/www/html"
    HTTPD_DIR="/usr/share/apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    DEFAULT_FILES=(
        "/var/www/html/index.html"
        "/usr/share/apache2/icons/"
        "/usr/share/apache2/error/"
        "/var/www/manual/"
    )
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Funzione per verificare la direttiva Include httpd-autoindex.conf
check_autoindex_include() {
    echo -e "\n${BLUE}Verifica direttiva Include httpd-autoindex.conf...${NC}"
    
    local conf_files=()
    
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        conf_files+=("$APACHE_CONF" "/etc/httpd/conf.d/*.conf")
    else
        conf_files+=("$APACHE_CONF" "/etc/apache2/conf-enabled/*.conf")
    fi
    
    local found_autoindex=false
    
    for conf_pattern in "${conf_files[@]}"; do
        for conf_file in $conf_pattern; do
            if [ -f "$conf_file" ]; then
                if grep -q "^[[:space:]]*Include.*httpd-autoindex\.conf" "$conf_file"; then
                    found_autoindex=true
                    echo -e "${RED}✗ Trovata direttiva Include httpd-autoindex.conf in: $conf_file${NC}"
                    issues_found+=("found_autoindex_include")
                fi
            fi
        done
    done
    
    if [ "$found_autoindex" = false ]; then
        echo -e "${GREEN}✓ Nessuna direttiva Include httpd-autoindex.conf attiva trovata${NC}"
    fi
    
    return 0
}

print_section "Verifica Contenuti Predefiniti"

# [Il resto delle funzioni di verifica dei contenuti predefiniti rimane invariato...]
check_default_content() {
        echo "Controllo contenuti predefiniti Apache..."
    
    local found_default_content=false
    
    # Controlla ogni percorso predefinito
    for path in "${DEFAULT_FILES[@]}"; do
        if [ -e "$path" ]; then
            found_default_content=true
            echo -e "${RED}✗ Trovato contenuto predefinito: $path${NC}"
            issues_found+=("found_${path//\//_}")
            
            # Se è una directory, mostra il contenuto
            if [ -d "$path" ]; then
                echo -e "${BLUE}Contenuto della directory:${NC}"
                ls -la "$path" | head -n 5
                if [ $(ls -1 "$path" | wc -l) -gt 5 ]; then
                    echo "..."
                fi
            fi
        else
            echo -e "${GREEN}✓ Non trovato contenuto predefinito: $path${NC}"
        fi
    done
    
    # Controlla per file di esempio o readme
    local example_files=$(find "$HTML_DIR" -type f -name "*example*" -o -name "README*" -o -name "*.sample" 2>/dev/null)
    if [ -n "$example_files" ]; then
        found_default_content=true
        echo -e "${RED}✗ Trovati file di esempio:${NC}"
        echo "$example_files"
        issues_found+=("found_example_files")
    fi
    
    # Verifica permessi directory principale
    if [ -d "$HTML_DIR" ]; then
        local dir_perms=$(stat -c "%a" "$HTML_DIR")
        local dir_owner=$(stat -c "%U:%G" "$HTML_DIR")
        
        echo -e "\n${BLUE}Permessi directory principale $HTML_DIR:${NC}"
        echo "Permessi: $dir_perms"
        echo "Proprietario: $dir_owner"
        
        if [ "$dir_perms" != "755" ]; then
            echo -e "${RED}✗ Permessi directory non corretti${NC}"
            issues_found+=("wrong_dir_perms")
        fi
        
        if [ "$SYSTEM_TYPE" = "redhat" ] && [ "$dir_owner" != "apache:apache" ]; then
            echo -e "${RED}✗ Proprietario directory non corretto${NC}"
            issues_found+=("wrong_dir_owner")
        elif [ "$SYSTEM_TYPE" = "debian" ] && [ "$dir_owner" != "www-data:www-data" ]; then
            echo -e "${RED}✗ Proprietario directory non corretto${NC}"
            issues_found+=("wrong_dir_owner")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui le verifiche
# check_default_content
check_autoindex_include

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Trovati problemi di configurazione.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_8.3
        backup_dir="/root/apache_content_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Backup dei file di configurazione
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            cp -r /etc/httpd "$backup_dir/"
        else
            cp -r /etc/apache2 "$backup_dir/"
        fi
        
        # Commenta la direttiva Include httpd-autoindex.conf
        if grep -l "^[[:space:]]*Include.*httpd-autoindex\.conf" "$APACHE_CONF" > /dev/null; then
            sed -i 's/^[[:space:]]*Include.*httpd-autoindex\.conf/#&/' "$APACHE_CONF"
            echo -e "${GREEN}✓ Commentata direttiva Include httpd-autoindex.conf${NC}"
        fi
        
        # [Il resto del codice di remediation rimane invariato...]
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_CMD -t; then
            echo -e "${GREEN}✓ Configurazione Apache valida${NC}"
            
            # Riavvia Apache
            echo -e "\n${YELLOW}Riavvio Apache...${NC}"
            systemctl restart $APACHE_CMD
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                check_autoindex_include
                if check_default_content; then
                    echo -e "\n${GREEN}✓ Configurazione corretta${NC}"
                else
                    echo -e "\n${RED}✗ Alcuni problemi persistono${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun problema rilevato nella configurazione${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory principale web: $HTML_DIR"
echo "2. Directory Apache: $HTTPD_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi
