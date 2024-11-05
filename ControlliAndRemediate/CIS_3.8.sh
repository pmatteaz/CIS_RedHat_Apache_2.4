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

print_section "Verifica CIS 3.8: Sicurezza del File di Lock"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_GROUP="apache"
    APACHE_RUN_DIR="/var/run/httpd"
    LOCK_FILE="$APACHE_RUN_DIR/httpd.lock"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_RUN_DIR="/var/run/apache2"
    LOCK_FILE="$APACHE_RUN_DIR/apache2.lock"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica File di Lock"

# Verifica directory di run
if [ ! -d "$APACHE_RUN_DIR" ]; then
    echo -e "${RED}✗ Directory $APACHE_RUN_DIR non trovata${NC}"
    issues_found+=("no_run_dir")
else
    echo -e "${GREEN}✓ Directory $APACHE_RUN_DIR presente${NC}"
    
    # Verifica permessi directory
    DIR_PERMS=$(stat -c '%a' "$APACHE_RUN_DIR")
    if [ "$DIR_PERMS" != "755" ]; then
        echo -e "${RED}✗ Permessi directory errati: $DIR_PERMS (dovrebbero essere 755)${NC}"
        issues_found+=("wrong_dir_perms")
    else
        echo -e "${GREEN}✓ Permessi directory corretti: 755${NC}"
    fi
fi

# Verifica file di lock
echo -e "\nControllo file di lock $LOCK_FILE..."

if [ -f "$LOCK_FILE" ]; then
    # Verifica proprietario
    OWNER=$(stat -c '%U' "$LOCK_FILE")
    if [ "$OWNER" != "root" ]; then
        echo -e "${RED}✗ Proprietario errato: $OWNER (dovrebbe essere root)${NC}"
        issues_found+=("wrong_owner")
    else
        echo -e "${GREEN}✓ Proprietario corretto: root${NC}"
    fi
    
    # Verifica gruppo
    GROUP=$(stat -c '%G' "$LOCK_FILE")
    if [ "$GROUP" != "$APACHE_GROUP" ]; then
        echo -e "${RED}✗ Gruppo errato: $GROUP (dovrebbe essere $APACHE_GROUP)${NC}"
        issues_found+=("wrong_group")
    else
        echo -e "${GREEN}✓ Gruppo corretto: $APACHE_GROUP${NC}"
    fi
    
    # Verifica permessi
    PERMS=$(stat -c '%a' "$LOCK_FILE")
    if [ "$PERMS" != "640" ]; then
        echo -e "${RED}✗ Permessi errati: $PERMS (dovrebbero essere 640)${NC}"
        issues_found+=("wrong_perms")
    else
        echo -e "${GREEN}✓ Permessi corretti: 640${NC}"
    fi
else
    echo -e "${RED}✗ File di lock non trovato${NC}"
    issues_found+=("no_lock_file")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con il file di lock.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup directory se esiste
        if [ -d "$APACHE_RUN_DIR" ]; then
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_dir="/root/apache_lock_backup_$timestamp"
            mkdir -p "$backup_dir"
            
            echo "Creazione backup in $backup_dir..."
            cp -r "$APACHE_RUN_DIR" "$backup_dir/"
        fi
        
        # Crea/correggi directory di run
        echo -e "\n${YELLOW}Configurazione directory di run...${NC}"
        if [ ! -d "$APACHE_RUN_DIR" ]; then
            mkdir -p "$APACHE_RUN_DIR"
            echo -e "${GREEN}✓ Directory creata${NC}"
        fi
        
        # Imposta permessi directory
        chown root:root "$APACHE_RUN_DIR"
        chmod 755 "$APACHE_RUN_DIR"
        echo -e "${GREEN}✓ Permessi directory impostati${NC}"
        
        # Crea/correggi file di lock
        echo -e "\n${YELLOW}Configurazione file di lock...${NC}"
        touch "$LOCK_FILE"
        chown root:"$APACHE_GROUP" "$LOCK_FILE"
        chmod 640 "$LOCK_FILE"
        
        # Verifica finale
        print_section "Verifica Finale"
        
        ERRORS=0
        
        # Verifica directory
        if [ -d "$APACHE_RUN_DIR" ]; then
            DIR_PERMS=$(stat -c '%a' "$APACHE_RUN_DIR")
            if [ "$DIR_PERMS" = "755" ]; then
                echo -e "${GREEN}✓ Directory configurata correttamente${NC}"
            else
                echo -e "${RED}✗ Directory non configurata correttamente${NC}"
                ((ERRORS++))
            fi
        else
            echo -e "${RED}✗ Directory non creata${NC}"
            ((ERRORS++))
        fi
        
        # Verifica file di lock
        if [ -f "$LOCK_FILE" ]; then
            LOCK_OWNER=$(stat -c '%U' "$LOCK_FILE")
            LOCK_GROUP=$(stat -c '%G' "$LOCK_FILE")
            LOCK_PERMS=$(stat -c '%a' "$LOCK_FILE")
            
            if [ "$LOCK_OWNER" = "root" ] && \
               [ "$LOCK_GROUP" = "$APACHE_GROUP" ] && \
               [ "$LOCK_PERMS" = "640" ]; then
                echo -e "${GREEN}✓ File di lock configurato correttamente${NC}"
            else
                echo -e "${RED}✗ File di lock non configurato correttamente${NC}"
                ((ERRORS++))
            fi
        else
            echo -e "${RED}✗ File di lock non creato${NC}"
            ((ERRORS++))
        fi
        
        if [ $ERRORS -eq 0 ]; then
            echo -e "\n${GREEN}✓ Remediation completata con successo${NC}"
        else
            echo -e "\n${RED}✗ Remediation completata con errori${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Il file di lock è configurato correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory di run: $APACHE_RUN_DIR"
echo "2. File di lock: $LOCK_FILE"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Un file di lock correttamente configurato garantisce che:${NC}"
echo -e "${BLUE}- Solo root possa gestire il file di lock${NC}"
echo -e "${BLUE}- Il processo Apache possa accedere al file quando necessario${NC}"
echo -e "${BLUE}- Il file sia protetto da accessi non autorizzati${NC}"
echo -e "${BLUE}- Il sistema di locking funzioni correttamente${NC}"
