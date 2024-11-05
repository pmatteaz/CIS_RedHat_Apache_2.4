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

print_section "Verifica CIS 3.5: File e Directory Apache devono avere il gruppo corretto"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="root"
    APACHE_GROUP="root"
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_LOG_DIR="/var/log/httpd"
    APACHE_BINARY="/usr/sbin/httpd"
    APACHE_DOC_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="root"
    APACHE_GROUP="root"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_LOG_DIR="/var/log/apache2"
    APACHE_BINARY="/usr/sbin/apache2"
    APACHE_DOC_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Struttura di controllo per directory e gruppi attesi
declare -A DIR_GROUP_MAP
DIR_GROUP_MAP=(
    ["$APACHE_CONFIG_DIR"]="root"
    ["$APACHE_LOG_DIR"]="$APACHE_GROUP"
    ["$APACHE_DOC_ROOT"]="$APACHE_GROUP"
)

# Array per memorizzare i problemi trovati
declare -a wrong_group=()

print_section "Verifica Gruppi File e Directory"

# Funzione per verificare il gruppo di file e directory
check_group() {
    local path="$1"
    local expected_group="$2"
    local type="$3"  # 'file' o 'directory'

    if [ ! -e "$path" ]; then
        echo -e "${YELLOW}Path non trovato: $path${NC}"
        return
    fi

    local current_group=$(stat -c '%G' "$path")
    if [ "$current_group" != "$expected_group" ]; then
        echo -e "${RED}✗ $type $path ha gruppo errato (attuale: $current_group, atteso: $expected_group)${NC}"
        wrong_group+=("$path|$expected_group")
    else
        echo -e "${GREEN}✓ $type $path ha il gruppo corretto ($expected_group)${NC}"
    fi
}

# Verifica directory principali
echo -e "\nVerifica directory principali..."
for dir in "${!DIR_GROUP_MAP[@]}"; do
    check_group "$dir" "${DIR_GROUP_MAP[$dir]}" "Directory"
done

# Verifica ricorsiva delle directory
echo -e "\nVerifica ricorsiva delle directory..."
for dir in "${!DIR_GROUP_MAP[@]}"; do
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' file; do
            # Determina il gruppo atteso basato sulla directory padre
            parent_dir="$dir"
            expected_group="${DIR_GROUP_MAP[$parent_dir]}"
            check_group "$file" "$expected_group" "File"
        done < <(find "$dir" -type f -print0)
    fi
done

# Se ci sono problemi, offri remediation
if [ ${#wrong_group[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_group[@]} file/directory con gruppo errato.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS3.5
        backup_dir="/root/apache_group_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup della configurazione in $backup_dir..."

        # Crea un file di log dei permessi attuali
        echo -e "\n${YELLOW}Creazione log dei permessi attuali...${NC}"
        for entry in "${wrong_group[@]}"; do
            path=${entry%|*}
            ls -l "$path" >> "$backup_dir/permissions.log"
        done

        # Correggi i gruppi
        echo -e "\n${YELLOW}Correzione gruppi...${NC}"
        for entry in "${wrong_group[@]}"; do
            path=${entry%|*}
            expected_group=${entry#*|}

            if [ -e "$path" ]; then
                echo "Correzione gruppo per: $path"
                if [ -d "$path" ]; then
                    # Per le directory, applica ricorsivamente
                    chgrp -R "$expected_group" "$path"
                    # Imposta i permessi appropriati
                    if [ "$expected_group" = "$APACHE_GROUP" ]; then
                        find "$path" -type d -exec chmod 755 {} \;
                        find "$path" -type f -exec chmod 644 {} \;
                    else
                        find "$path" -type d -exec chmod 750 {} \;
                        find "$path" -type f -exec chmod 640 {} \;
                    fi
                else
                    # Per i file singoli
                    chgrp "$expected_group" "$path"
                    if [ "$expected_group" = "$APACHE_GROUP" ]; then
                        chmod 644 "$path"
                    else
                        chmod 640 "$path"
                    fi
                fi

                # Verifica il risultato
                if [ "$(stat -c '%G' "$path")" = "$expected_group" ]; then
                    echo -e "${GREEN}✓ Gruppo corretto con successo per $path${NC}"
                else
                    echo -e "${RED}✗ Errore nella correzione del gruppo per $path${NC}"
                fi
            fi
        done

        # Impostazioni speciali per i binari
        if [ -f "$APACHE_BINARY" ]; then
            chgrp root "$APACHE_BINARY"
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
        for entry in "${wrong_group[@]}"; do
            path=${entry%|*}
            expected_group=${entry#*|}

            if [ -e "$path" ]; then
                current_group=$(stat -c '%G' "$path")
                if [ "$current_group" != "$expected_group" ]; then
                    echo -e "${RED}✗ $path ancora con gruppo errato (attuale: $current_group, atteso: $expected_group)${NC}"
                    ((errors++))
                else
                    echo -e "${GREEN}✓ $path correttamente impostato con gruppo $expected_group${NC}"
                fi
            fi
        done

        if [ $errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutti i gruppi sono stati corretti con successo${NC}"
        else
            echo -e "\n${RED}✗ Alcuni file/directory presentano ancora problemi${NC}"
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Tutti i gruppi sono corretti${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory principali verificate:"
for dir in "${!DIR_GROUP_MAP[@]}"; do
    echo "   - $dir (gruppo atteso: ${DIR_GROUP_MAP[$dir]})"
done

if [ -d "$backup_dir" ]; then
    echo -e "\n2. Backup delle configurazioni salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi
