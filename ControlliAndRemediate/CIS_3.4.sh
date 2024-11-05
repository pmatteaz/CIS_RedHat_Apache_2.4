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

print_section "Verifica CIS 3.4: File e Directory Apache devono essere di proprietà di Root"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_LOG_DIR="/var/log/httpd"
    APACHE_BINARY="/usr/sbin/httpd"
    APACHE_DOC_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_LOG_DIR="/var/log/apache2"
    APACHE_BINARY="/usr/sbin/apache2"
    APACHE_DOC_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array di directory da controllare
declare -a APACHE_DIRS=(
    "$APACHE_CONFIG_DIR"
    "$APACHE_LOG_DIR"
    "$APACHE_DOC_ROOT"
    "$(dirname $APACHE_BINARY)"
)

# Array di file specifici da controllare
declare -a APACHE_FILES=(
    "$APACHE_BINARY"
    "${APACHE_CONFIG_DIR}/conf"
    "${APACHE_CONFIG_DIR}/conf.d"
    "${APACHE_CONFIG_DIR}/conf.modules.d"
)

# Array per memorizzare i problemi trovati
declare -a wrong_ownership=()

print_section "Verifica Proprietà File e Directory"

# Funzione per verificare la proprietà di file e directory
check_ownership() {
    local path="$1"
    local type="$2"  # 'file' o 'directory'
    
    if [ ! -e "$path" ]; then
        echo -e "${YELLOW}Path non trovato: $path${NC}"
        return
    fi
    
    local owner=$(stat -c '%U' "$path")
    if [ "$owner" != "root" ]; then
        echo -e "${RED}✗ $type $path non è di proprietà di root (attuale: $owner)${NC}"
        wrong_ownership+=("$path")
    else
        echo -e "${GREEN}✓ $type $path è di proprietà di root${NC}"
    fi
}

# Verifica directory principali
echo -e "\nVerifica directory principali..."
for dir in "${APACHE_DIRS[@]}"; do
    check_ownership "$dir" "Directory"
done

# Verifica file specifici
echo -e "\nVerifica file specifici..."
for file in "${APACHE_FILES[@]}"; do
    check_ownership "$file" "File"
done

# Verifica ricorsiva delle configurazioni
echo -e "\nVerifica ricorsiva delle configurazioni..."
while IFS= read -r -d '' file; do
    check_ownership "$file" "File"
done < <(find "$APACHE_CONFIG_DIR" -type f -print0)

# Se ci sono problemi, offri remediation
if [ ${#wrong_ownership[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_ownership[@]} file/directory con proprietà errata.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS3.4
        backup_dir="/root/apache_ownership_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        
        # Crea un file di log dei permessi attuali
        echo -e "\n${YELLOW}Creazione log dei permessi attuali...${NC}"
        for path in "${wrong_ownership[@]}"; do
            if [ -e "$path" ]; then
                ls -l "$path" >> "$backup_dir/permissions.log"
                if [ -d "$path" ]; then
                    find "$path" -type f -exec ls -l {} \; >> "$backup_dir/permissions.log"
                fi
            fi
        done
        
        # Correggi le proprietà
        echo -e "\n${YELLOW}Correzione proprietà...${NC}"
        for path in "${wrong_ownership[@]}"; do
            if [ -e "$path" ]; then
                echo "Correzione proprietà per: $path"
                if [ -d "$path" ]; then
                    # Per le directory, applica ricorsivamente
                    chown -R root:root "$path"
                    find "$path" -type d -exec chmod 755 {} \;
                    find "$path" -type f -exec chmod 644 {} \;
                else
                    # Per i file singoli
                    chown root:root "$path"
                    chmod 644 "$path"
                fi
                
                # Verifica il risultato
                if [ "$(stat -c '%U' "$path")" = "root" ]; then
                    echo -e "${GREEN}✓ Proprietà corretta con successo per $path${NC}"
                else
                    echo -e "${RED}✗ Errore nella correzione delle proprietà per $path${NC}"
                fi
            fi
        done
        
        # Impostazioni speciali per i binari
        if [ -f "$APACHE_BINARY" ]; then
            chmod 755 "$APACHE_BINARY"
            echo -e "${GREEN}✓ Permessi binario Apache corretti${NC}"
        fi
        
        # Verifica configurazione Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_BINARY -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup consigliato${NC}"
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        errors=0
        for path in "${wrong_ownership[@]}"; do
            if [ -e "$path" ]; then
                owner=$(stat -c '%U' "$path")
                if [ "$owner" != "root" ]; then
                    echo -e "${RED}✗ $path ancora non di proprietà di root (attuale: $owner)${NC}"
                    ((errors++))
                else
                    echo -e "${GREEN}✓ $path correttamente di proprietà di root${NC}"
                fi
            fi
        done
        
        if [ $errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutte le proprietà sono state corrette con successo${NC}"
        else
            echo -e "\n${RED}✗ Alcuni file/directory presentano ancora problemi${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Tutte le proprietà sono corrette${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory Apache verificate:"
for dir in "${APACHE_DIRS[@]}"; do
    echo "   - $dir"
done

if [ -d "$backup_dir" ]; then
    echo -e "\n2. Backup delle configurazioni salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi

echo -e "\n${BLUE}Nota: La proprietà root dei file Apache garantisce che:${NC}"
echo -e "${BLUE}- Solo root possa modificare i file di configurazione${NC}"
echo -e "${BLUE}- I file di configurazione siano protetti da modifiche non autorizzate${NC}"
echo -e "${BLUE}- L'utente Apache possa solo leggere i file necessari${NC}"
