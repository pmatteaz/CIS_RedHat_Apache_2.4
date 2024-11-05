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

print_section "Verifica CIS 3.13: Controllo Accesso alle Directory Speciali dell'Applicazione"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_GROUP="apache"
    DOCUMENT_ROOT="/var/www"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    DOCUMENT_ROOT="/var/www"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array di nomi comuni per directory speciali
declare -a SPECIAL_DIRS=(
    "writable"
    "uploads"
    "tmp"
    "temp"
    "cache"
    "files"
    "upload"
    "downloads"
    "media"
)

# Array per memorizzare le directory problematiche
declare -a problem_dirs=()

print_section "Ricerca Directory Speciali"

echo "Cercando directory speciali in $DOCUMENT_ROOT..."

# Funzione per verificare i permessi di una directory
check_directory_permissions() {
    local dir="$1"
    local issues=()
    
    # Verifica proprietario
    owner=$(stat -c '%U' "$dir")
    if [ "$owner" != "root" ]; then
        issues+=("proprietario non è root ($owner)")
    fi
    
    # Verifica gruppo
    group=$(stat -c '%G' "$dir")
    if [ "$group" != "$APACHE_GROUP" ]; then
        issues+=("gruppo non è $APACHE_GROUP ($group)")
    fi
    
    # Verifica permessi
    perms=$(stat -c '%a' "$dir")
    if [ "$perms" != "750" ]; then
        issues+=("permessi non sono 750 ($perms)")
    fi
    
    if [ ${#issues[@]} -gt 0 ]; then
        echo -e "${RED}✗ Directory: $dir${NC}"
        for issue in "${issues[@]}"; do
            echo -e "${RED}  - $issue${NC}"
        done
        problem_dirs+=("$dir")
        return 1
    fi
    
    echo -e "${GREEN}✓ Directory: $dir configurata correttamente${NC}"
    return 0
}

# Cerca le directory speciali
for special_dir in "${SPECIAL_DIRS[@]}"; do
    while IFS= read -r -d '' dir; do
        echo -e "\nControllo: $dir"
        check_directory_permissions "$dir"
    done < <(find "$DOCUMENT_ROOT" -type d -name "$special_dir" -print0)
done

# Se ci sono problemi, offri remediation
if [ ${#problem_dirs[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono state trovate ${#problem_dirs[@]} directory speciali con configurazioni non sicure.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_special_dirs_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Log delle configurazioni originali
        for dir in "${problem_dirs[@]}"; do
            rel_path=${dir#$DOCUMENT_ROOT}
            mkdir -p "$backup_dir$(dirname "$rel_path")"
            cp -rp "$dir" "$backup_dir$(dirname "$rel_path")/"
            stat -c '%a %U %G %n' "$dir" >> "$backup_dir/permissions.log"
        done
        
        # Correggi le directory
        echo -e "\n${YELLOW}Correzione permessi directory...${NC}"
        errors=0
        
        for dir in "${problem_dirs[@]}"; do
            echo -e "\nConfigurando directory: $dir"
            
            # Imposta proprietario e gruppo
            if ! chown root:"$APACHE_GROUP" "$dir"; then
                echo -e "${RED}✗ Errore nell'impostazione del proprietario/gruppo per $dir${NC}"
                ((errors++))
                continue
            fi
            
            # Imposta permessi
            if ! chmod 750 "$dir"; then
                echo -e "${RED}✗ Errore nell'impostazione dei permessi per $dir${NC}"
                ((errors++))
                continue
            fi
            
            # Verifica la configurazione
            if check_directory_permissions "$dir"; then
                echo -e "${GREEN}✓ Directory $dir configurata correttamente${NC}"
            else
                echo -e "${RED}✗ Errore nella configurazione di $dir${NC}"
                ((errors++))
            fi
        done
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
                ((errors++))
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            for dir in "${problem_dirs[@]}"; do
                rel_path=${dir#$DOCUMENT_ROOT}
                if [ -d "$backup_dir$rel_path" ]; then
                    rm -rf "$dir"
                    cp -rp "$backup_dir$rel_path" "$dir"
                fi
            done
            
            echo -e "${GREEN}Backup ripristinato${NC}"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        
        final_errors=0
        for dir in "${problem_dirs[@]}"; do
            if ! check_directory_permissions "$dir"; then
                ((final_errors++))
            fi
        done
        
        if [ $final_errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutte le directory sono state configurate correttamente${NC}"
        else
            echo -e "\n${RED}✗ Alcune directory presentano ancora problemi${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessuna directory speciale con configurazioni non sicure trovata${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory controllate:"
for dir in "${SPECIAL_DIRS[@]}"; do
    echo "   - */$dir"
done
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione delle directory speciali garantisce che:${NC}"
echo -e "${BLUE}- Solo root possa gestire le directory${NC}"
echo -e "${BLUE}- Il processo Apache possa accedere ai file quando necessario${NC}"
echo -e "${BLUE}- I contenuti siano protetti da accessi non autorizzati${NC}"
echo -e "${BLUE}- Le directory sensibili siano correttamente isolate${NC}"
