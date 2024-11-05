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

print_section "Verifica CIS 3.6: Limitare l'accesso in scrittura 'other' per file e directory Apache"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il percorso della configurazione di Apache
if [ -d "/etc/httpd" ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_LOG_DIR="/var/log/httpd"
    APACHE_DOC_ROOT="/var/www/html"
elif [ -d "/etc/apache2" ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_LOG_DIR="/var/log/apache2"
    APACHE_DOC_ROOT="/var/www/html"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

# Array delle directory da controllare
declare -a APACHE_DIRS=(
    "$APACHE_CONFIG_DIR"
    "$APACHE_LOG_DIR"
    "$APACHE_DOC_ROOT"
)

# Array per memorizzare i file con permessi errati
declare -a wrong_permissions=()

print_section "Verifica Permessi di Scrittura"

# Funzione per verificare i permessi
check_permissions() {
    local path="$1"
    echo -e "\nControllo permessi in: $path"
    
    while IFS= read -r -d '' file; do
        # Verifica se il file ha permessi di scrittura per "others"
        if [ -h "$file" ]; then
            continue  # Salta i link simbolici
        fi
        
        perms=$(stat -c '%a' "$file")
        if [ $((perms & 2)) -eq 2 ]; then
            echo -e "${RED}✗ Trovato file con permessi di scrittura 'other': $file (${perms})${NC}"
            wrong_permissions+=("$file")
        fi
    done < <(find "$path" -not -type l -print0)
}

# Controlla tutte le directory Apache
for dir in "${APACHE_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        check_permissions "$dir"
    else
        echo -e "${YELLOW}Directory non trovata: $dir${NC}"
    fi
done

# Se ci sono problemi, offri remediation
if [ ${#wrong_permissions[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_permissions[@]} file/directory con permessi di scrittura 'other' non sicuri.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_perms_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        
        # Crea un file di log dei permessi attuali
        echo -e "\n${YELLOW}Creazione log dei permessi attuali...${NC}"
        for file in "${wrong_permissions[@]}"; do
            current_perms=$(stat -c '%a %n' "$file")
            echo "$current_perms" >> "$backup_dir/permissions.log"
        done
        
        # Correggi i permessi
        echo -e "\n${YELLOW}Correzione permessi...${NC}"
        for file in "${wrong_permissions[@]}"; do
            if [ -e "$file" ]; then
                echo "Rimozione permessi di scrittura 'other' per: $file"
                original_perms=$(stat -c '%a' "$file")
                
                # Rimuovi permesso di scrittura per others
                if [ -d "$file" ]; then
                    chmod o-w "$file"
                    # Per directory, assicurati che rimangano eseguibili se necessario
                    if [ $((original_perms & 1)) -eq 1 ]; then
                        chmod o+x "$file"
                    fi
                else
                    chmod o-w "$file"
                fi
                
                # Verifica il risultato
                new_perms=$(stat -c '%a' "$file")
                if [ $((new_perms & 2)) -eq 0 ]; then
                    echo -e "${GREEN}✓ Permessi corretti con successo per $file (${original_perms} -> ${new_perms})${NC}"
                else
                    echo -e "${RED}✗ Errore nella correzione dei permessi per $file${NC}"
                fi
            fi
        done
        
        # Verifica configurazione Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_CONFIG_DIR/bin/httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
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
        for file in "${wrong_permissions[@]}"; do
            if [ -e "$file" ]; then
                perms=$(stat -c '%a' "$file")
                if [ $((perms & 2)) -eq 2 ]; then
                    echo -e "${RED}✗ $file ha ancora permessi di scrittura 'other' (${perms})${NC}"
                    ((errors++))
                else
                    echo -e "${GREEN}✓ $file ha ora permessi corretti (${perms})${NC}"
                fi
            fi
        done
        
        if [ $errors -eq 0 ]; then
            echo -e "\n${GREEN}✓ Tutti i permessi sono stati corretti con successo${NC}"
        else
            echo -e "\n${RED}✗ Alcuni file presentano ancora problemi${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Non sono stati trovati file con permessi di scrittura 'other' non sicuri${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory controllate:"
for dir in "${APACHE_DIRS[@]}"; do
    echo "   - $dir"
done

if [ -d "$backup_dir" ]; then
    echo -e "\n2. Backup salvato in: $backup_dir"
    echo "   - Log dei permessi originali: $backup_dir/permissions.log"
fi

echo -e "\n${BLUE}Nota: La rimozione dei permessi di scrittura 'other' garantisce che:${NC}"
echo -e "${BLUE}- Solo gli utenti autorizzati possano modificare i file${NC}"
echo -e "${BLUE}- I file di configurazione siano protetti da modifiche non autorizzate${NC}"
echo -e "${BLUE}- La sicurezza complessiva del server web sia migliorata${NC}"
