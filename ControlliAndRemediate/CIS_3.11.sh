#!/bin/bash
# Da vedere meglio

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

print_section "Verifica CIS 3.11: Permessi di Scrittura del Gruppo per File e Directory Apache"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_GROUP="apache"
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_LOG_DIR="/var/log/httpd"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_LOG_DIR="/var/log/apache2"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i file con permessi non corretti
declare -a wrong_permissions=()

print_section "Verifica Permessi di Scrittura del Gruppo"

# Funzione per verificare i permessi di scrittura del gruppo
check_group_write() {
    local path="$1"
    echo -e "\nControllo permessi in: $path"
    
    # Cerca file con permessi di scrittura del gruppo
    while IFS= read -r -d '' file; do
        if [ -h "$file" ]; then
            continue  # Salta i link simbolici
        fi
        
        # Verifica se il file ha permessi di scrittura per il gruppo
        perms=$(stat -c '%A' "$file")
        if [[ ${perms:5:1} == "w" ]]; then
            echo -e "${RED}✗ Trovato file con permessi di scrittura del gruppo: $file (${perms})${NC}"
            wrong_permissions+=("$file")
        fi
    done < <(find "$path" -type f -print0)
    
    # Cerca directory con permessi di scrittura del gruppo
    while IFS= read -r -d '' dir; do
        if [ -h "$dir" ]; then
            continue  # Salta i link simbolici
        fi
        
        perms=$(stat -c '%A' "$dir")
        if [[ ${perms:5:1} == "w" ]]; then
           echo "Directory ha permessi di scrittura per il gruppo"
        else
            echo -e "${RED}✗ Trovata directory con permessi di scrittura del gruppo: $dir (${perms})${NC}"
            wrong_permissions+=("$dir")
        fi
    done < <(find "$path" -type d -print0)
}

# Controlla i permessi nella directory di configurazione di Apache
check_group_write "$APACHE_CONFIG_DIR"

# Se ci sono problemi, offri remediation
if [ ${#wrong_permissions[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_permissions[@]} file/directory con permessi di scrittura del gruppo non sicuri.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.11
        backup_dir="/root/apache_group_write_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Crea un file di log dei permessi attuali
        for item in "${wrong_permissions[@]}"; do
            # Salva il percorso completo nella struttura del backup
            rel_path=${item#$APACHE_CONFIG_DIR}
            backup_path="$backup_dir/config$rel_path"
            mkdir -p "$(dirname "$backup_path")"
            cp -p "$item" "$backup_path"
            
            # Salva i permessi originali nel log
            stat -c '%a %U %G %n' "$item" >> "$backup_dir/permissions.log"
        done
        
        # Correggi i permessi
        echo -e "\n${YELLOW}Correzione permessi...${NC}"
        errors=0
        
        for item in "${wrong_permissions[@]}"; do
            echo "Rimozione permessi di scrittura del gruppo per: $item"
            if [ -d "$item" ]; then
                # Per le directory, mantieni x se presente
                current_perms=$(stat -c '%a' "$item")
                if [ $((current_perms & 010)) -eq 010 ]; then
                    # Mantieni x ma rimuovi w
                    chmod g-w,g+x "$item"
                else
                    chmod g-w "$item"
                fi
            else
                chmod g-w "$item"
            fi
            
            # Verifica la correzione
            new_perms=$(stat -c '%a' "$item")
            if [ $((new_perms & 020)) -eq 0 ]; then
                echo -e "${GREEN}✓ Permessi corretti con successo per $item${NC}"
            else
                echo -e "${RED}✗ Errore nella correzione dei permessi per $item${NC}"
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
                errors=$((errors + 1))
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina i file dal backup
            for item in "${wrong_permissions[@]}"; do
                rel_path=${item#$APACHE_CONFIG_DIR}
                backup_path="$backup_dir/config$rel_path"
                if [ -f "$backup_path" ]; then
                    cp -p "$backup_path" "$item"
                fi
            done
            
            echo -e "${GREEN}Backup ripristinato${NC}"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
        fi
        
        # Verifica finale
        if [ $errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutti i permessi sono stati corretti con successo${NC}"
        else
            echo -e "\n${RED}✗ Si sono verificati $errors errori durante la correzione${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Non sono stati trovati file o directory con permessi di scrittura del gruppo non sicuri${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory controllata: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi

echo -e "\n${BLUE}Nota: La rimozione dei permessi di scrittura del gruppo garantisce che:${NC}"
echo -e "${BLUE}- Solo il proprietario possa modificare i file${NC}"
echo -e "${BLUE}- I file di configurazione siano protetti da modifiche non autorizzate${NC}"
echo -e "${BLUE}- Sia mantenuta l'integrità delle configurazioni${NC}"
echo -e "${BLUE}- Si riduca il rischio di modifiche accidentali o malevole${NC}"
