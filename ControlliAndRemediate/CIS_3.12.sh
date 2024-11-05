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

print_section "Verifica CIS 3.12: Permessi di Scrittura del Gruppo per Document Root"

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
    DOCUMENT_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    DOCUMENT_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Verifica se la Document Root è configurata diversamente nel file di configurazione
if [ -f "$APACHE_CONFIG_DIR/conf/httpd.conf" ]; then
    CUSTOM_DOC_ROOT=$(grep -i "^DocumentRoot" "$APACHE_CONFIG_DIR/conf/httpd.conf" | awk '{print $2}' | tr -d '"')
    if [ -n "$CUSTOM_DOC_ROOT" ]; then
        DOCUMENT_ROOT="$CUSTOM_DOC_ROOT"
    fi
elif [ -f "$APACHE_CONFIG_DIR/apache2.conf" ]; then
    CUSTOM_DOC_ROOT=$(grep -i "^DocumentRoot" "$APACHE_CONFIG_DIR/apache2.conf" | awk '{print $2}' | tr -d '"')
    if [ -n "$CUSTOM_DOC_ROOT" ]; then
        DOCUMENT_ROOT="$CUSTOM_DOC_ROOT"
    fi
fi

# Array per memorizzare i file con permessi non corretti
declare -a wrong_permissions=()

print_section "Verifica Permessi Document Root"

# Verifica se la Document Root esiste
if [ ! -d "$DOCUMENT_ROOT" ]; then
    echo -e "${RED}✗ Document Root non trovata: $DOCUMENT_ROOT${NC}"
    exit 1
fi

echo "Controllo permessi in Document Root: $DOCUMENT_ROOT"

# Funzione per verificare i permessi di scrittura del gruppo
check_group_write() {
    local path="$1"
    local file_type="$2"  # 'file' o 'directory'
    
    perms=$(stat -c '%a' "$path")
    owner=$(stat -c '%U' "$path")
    group=$(stat -c '%G' "$path")
    
    if [ $((perms & 020)) -eq 020 ]; then
        echo -e "${RED}✗ Trovato $file_type con permessi di scrittura del gruppo: $path${NC}"
        echo "   Proprietario: $owner, Gruppo: $group, Permessi: $perms"
        wrong_permissions+=("$path")
        return 1
    fi
    return 0
}

# Verifica la Document Root stessa
check_group_write "$DOCUMENT_ROOT" "directory"

# Verifica ricorsivamente tutti i file e le directory
while IFS= read -r -d '' item; do
    if [ -h "$item" ]; then
        continue  # Salta i link simbolici
    fi
    
    if [ -f "$item" ]; then
        check_group_write "$item" "file"
    elif [ -d "$item" ]; then
        check_group_write "$item" "directory"
    fi
done < <(find "$DOCUMENT_ROOT" -not -type l -print0)

# Se ci sono problemi, offri remediation
if [ ${#wrong_permissions[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_permissions[@]} file/directory con permessi di scrittura del gruppo non sicuri.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_docroot_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Crea un file di log dei permessi attuali
        for item in "${wrong_permissions[@]}"; do
            # Salva il percorso relativo nella struttura del backup
            rel_path=${item#$DOCUMENT_ROOT}
            backup_path="$backup_dir/docroot$rel_path"
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
                ((errors++))
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina i file dal backup
            for item in "${wrong_permissions[@]}"; do
                rel_path=${item#$DOCUMENT_ROOT}
                backup_path="$backup_dir/docroot$rel_path"
                if [ -f "$backup_path" ] || [ -d "$backup_path" ]; then
                    cp -p "$backup_path" "$item"
                fi
            done
            
            echo -e "${GREEN}Backup ripristinato${NC}"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        
        final_errors=0
        for item in "${wrong_permissions[@]}"; do
            current_perms=$(stat -c '%a' "$item")
            if [ $((current_perms & 020)) -eq 020 ]; then
                echo -e "${RED}✗ $item ancora con permessi di scrittura del gruppo (${current_perms})${NC}"
                ((final_errors++))
            else
                echo -e "${GREEN}✓ $item ora ha permessi corretti (${current_perms})${NC}"
            fi
        done
        
        if [ $final_errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutti i permessi sono stati corretti con successo${NC}"
        else
            echo -e "\n${RED}✗ Alcuni file/directory presentano ancora problemi${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun file o directory con permessi di scrittura del gruppo non sicuri trovati in Document Root${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Document Root: $DOCUMENT_ROOT"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi

echo -e "\n${BLUE}Nota: La rimozione dei permessi di scrittura del gruppo per Document Root garantisce che:${NC}"
echo -e "${BLUE}- Solo gli utenti autorizzati possano modificare i file web${NC}"
echo -e "${BLUE}- Il contenuto web sia protetto da modifiche non autorizzate${NC}"
echo -e "${BLUE}- Si riduca il rischio di defacement del sito${NC}"
echo -e "${BLUE}- Si mantenga l'integrità dei contenuti web${NC}"
