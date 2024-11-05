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

print_section "Verifica CIS 5.4: Rimozione Contenuto HTML Predefinito"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    DOCUMENT_ROOT="/var/www/html"
    MANUAL_DIR="/var/www/manual"
    ERROR_DIR="/var/www/error"
    ICONS_DIR="/var/www/icons"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    DOCUMENT_ROOT="/var/www/html"
    MANUAL_DIR="/usr/share/apache2/manual"
    ERROR_DIR="/var/www/error"
    ICONS_DIR="/usr/share/apache2/icons"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array di directory e file da controllare
declare -a CHECK_PATHS=(
    "$DOCUMENT_ROOT/index.html"
    "$MANUAL_DIR"
    "$ERROR_DIR"
    "$ICONS_DIR"
)

# Array per memorizzare elementi trovati
declare -a found_items=()

print_section "Verifica Contenuti Predefiniti"

# Funzione per controllare file e directory
check_default_content() {
    local path="$1"
    
    if [ -e "$path" ]; then
        if [ -f "$path" ]; then
            echo -e "${RED}✗ Trovato file predefinito: $path${NC}"
            found_items+=("$path")
        elif [ -d "$path" ]; then
            if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
                echo -e "${RED}✗ Trovata directory predefinita non vuota: $path${NC}"
                found_items+=("$path")
            else
                echo -e "${GREEN}✓ Directory vuota: $path${NC}"
            fi
        fi
    else
        echo -e "${GREEN}✓ Elemento non presente: $path${NC}"
    fi
}

# Verifica tutti i percorsi
for path in "${CHECK_PATHS[@]}"; do
    check_default_content "$path"
done

# Verifica contenuti personalizzati in DocumentRoot
echo -e "\nVerifica contenuti in DocumentRoot..."
if [ -d "$DOCUMENT_ROOT" ]; then
    find "$DOCUMENT_ROOT" -type f -name "*.html" -o -name "*.htm" | while read -r file; do
        # Verifica se il file sembra essere un contenuto predefinito
        if grep -q "Test Page\|Welcome\|Apache" "$file" 2>/dev/null; then
            echo -e "${RED}✗ Possibile contenuto predefinito trovato: $file${NC}"
            found_items+=("$file")
        fi
    done
fi

# Se ci sono elementi trovati, offri remediation
if [ ${#found_items[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#found_items[@]} elementi predefiniti.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei contenuti
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_default_content_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        
        # Funzione per backup sicuro
        safe_backup() {
            local path="$1"
            local rel_path="${path#/}"  # Rimuove lo slash iniziale
            local backup_path="$backup_dir/$rel_path"
            
            # Crea la directory di destinazione
            mkdir -p "$(dirname "$backup_path")"
            
            if [ -f "$path" ]; then
                cp -p "$path" "$backup_path"
            elif [ -d "$path" ]; then
                cp -rp "$path" "$backup_path"
            fi
        }
        
        # Backup di tutti gli elementi trovati
        for item in "${found_items[@]}"; do
            echo "Backup di: $item"
            safe_backup "$item"
        done
        
        # Rimozione elementi
        echo -e "\n${YELLOW}Rimozione contenuti predefiniti...${NC}"
        
        for item in "${found_items[@]}"; do
            echo "Rimozione: $item"
            if [ -f "$item" ]; then
                rm -f "$item"
            elif [ -d "$item" ]; then
                rm -rf "$item"
            fi
        done
        
        # Verifica della configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                errors=0
                for item in "${found_items[@]}"; do
                    if [ -e "$item" ]; then
                        echo -e "${RED}✗ Elemento ancora presente: $item${NC}"
                        ((errors++))
                    else
                        echo -e "${GREEN}✓ Elemento rimosso con successo: $item${NC}"
                    fi
                done
                
                if [ $errors -eq 0 ]; then
                    echo -e "\n${GREEN}✓ Tutti gli elementi predefiniti sono stati rimossi con successo${NC}"
                    
                    # Crea un file index.html minimo
                    if [ ! -f "$DOCUMENT_ROOT/index.html" ]; then
                        echo -e "\n${YELLOW}Creazione file index.html minimo...${NC}"
                        echo "<html><body></body></html>" > "$DOCUMENT_ROOT/index.html"
                        chmod 644 "$DOCUMENT_ROOT/index.html"
                        chown root:root "$DOCUMENT_ROOT/index.html"
                    fi
                else
                    echo -e "\n${RED}✗ Alcuni elementi non sono stati rimossi correttamente${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            for item in "${found_items[@]}"; do
                rel_path="${item#/}"
                if [ -e "$backup_dir/$rel_path" ]; then
                    rm -rf "$item"
                    cp -rp "$backup_dir/$rel_path" "$item"
                fi
            done
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun contenuto predefinito trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Percorsi controllati:"
for path in "${CHECK_PATHS[@]}"; do
    echo "   - $path"
done
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La rimozione dei contenuti predefiniti garantisce che:${NC}"
echo -e "${BLUE}- Non vengano esposti dettagli sulla configurazione del server${NC}"
echo -e "${BLUE}- Si riduca la superficie di attacco${NC}"
echo -e "${BLUE}- Si minimizzi l'informazione disponibile agli attaccanti${NC}"
echo -e "${BLUE}- Il server web contenga solo i file necessari${NC}"
