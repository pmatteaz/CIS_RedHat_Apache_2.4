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

print_section "Verifica CIS 3.8: Ensure Lock File is Secured"

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
    APACHE_CONF_FILE="$APACHE_CONFIG_DIR/conf/httpd.conf"

elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_CONF_FILE="$APACHE_CONFIG_DIR/apache2.conf"

else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.8
        backup_dir="/root/apache_coredump_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup della configurazione in $backup_dir..."
        cp "$APACHE_CONF_FILE" "$backup_dir/"

print_section "Verifica Configurazione Lock file"

# Verifica la configurazione di Apache
        for direttiva in "^Mutex fcntl" "^Mutex flock" "^Mutex file" ; do
                if grep -q "$direttiva" "$APACHE_CONF_FILE"; then
                echo -e "\n${YELLOW}La configurazione Mutex prevede un lock file...${NC}"
                file=$( grep "$direttiva" "$APACHE_CONF_FILE" | cut -d":" -f2 | cut -d" " -f1)
                # Controlla i permessi del file
                echo -e "\n${YELLOW}Controlla permessi lock file...${NC}"
                perms=$(stat -c '%A' "$file")
                prime_cifre="${perms: -5}"
                if [[ "`echo $prime_cifre |grep w`" =~ 'w' ]] ; then
                    echo -e "${RED}✗ Trovato file con permessi di scrittura errati: $file (${perms})${NC}"
                    wrong_permissions+=("$file")
                fi
            else
                echo -e "\n${GREEN}Configurazione Mutex fcntl non definita...${NC}"
            fi
        done

# Se ci sono problemi, offri remediation
if [ ${#wrong_permissions[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Trovato ${#wrong_permissions[@]} file con permessi di scrittura non sicuri.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.8
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
                echo "Rimozione permessi di scrittura per: $file"
                original_perms=$(stat -c '%a' "$file")

                # Rimuovi permesso di scrittura per others
                chmod go-w "$file"

                # Verifica il risultato
                new_perms=$(stat -c '%a' "$file")
                prime_cifre="${new_perms: -5}"
                if [ "`echo $prime_cifre |grep 'w'`" =~ 'w' ]; then
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
                    echo -e "${RED}✗ $file ha ancora permessi di scrittura (${perms})${NC}"
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
echo "1. File di configurazione: $APACHE_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup della configurazione: $backup_dir"
fi
