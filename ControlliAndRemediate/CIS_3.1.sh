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

# Configurazioni predefinite
DEFAULT_APACHE_USER="apache"
DEFAULT_APACHE_GROUP="apache"
DEFAULT_APACHE_HOME="/var/www"
DEFAULT_APACHE_SHELL="/sbin/nologin"

print_section "Verifica CIS 3.1: Apache deve essere eseguito come utente non-root"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il comando Apache corretto e le directory di configurazione
APACHE_CMD="httpd"
if command_exists apache2; then
    APACHE_CMD="apache2"
    DEFAULT_APACHE_USER="www-data"
    DEFAULT_APACHE_GROUP="www-data"
fi

# Determina il percorso della configurazione di Apache
if [ -d "/etc/httpd" ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
elif [ -d "/etc/apache2" ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

print_section "Verifica della Configurazione Utente"

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Verifica le direttive User e Group nel file di configurazione principale
CURRENT_USER=$(grep -i "^User" "$MAIN_CONFIG" | awk '{print $2}')
CURRENT_GROUP=$(grep -i "^Group" "$MAIN_CONFIG" | awk '{print $2}')

echo "Verifica configurazione utente corrente..."
if [ -z "$CURRENT_USER" ]; then
    echo -e "${RED}✗ Direttiva User non trovata nel file di configurazione${NC}"
    issues_found+=("User_not_configured")
else
    echo -e "Utente configurato: $CURRENT_USER"
    # Verifica se l'utente è root
    if [ "$CURRENT_USER" = "root" ]; then
        echo -e "${RED}✗ Apache è configurato per essere eseguito come root${NC}"
        issues_found+=("Running_as_root")
    fi
fi

if [ -z "$CURRENT_GROUP" ]; then
    echo -e "${RED}✗ Direttiva Group non trovata nel file di configurazione${NC}"
    issues_found+=("Group_not_configured")
else
    echo -e "Gruppo configurato: $CURRENT_GROUP"
    # Verifica se il gruppo è root
    if [ "$CURRENT_GROUP" = "root" ]; then
        echo -e "${RED}✗ Apache è configurato per essere eseguito nel gruppo root${NC}"
        issues_found+=("Group_is_root")
    fi
fi

# Verifica l'utente effettivo sotto cui gira Apache
if pgrep -x "$APACHE_CMD" > /dev/null; then
    RUNNING_USER=$(ps -ef | grep "$APACHE_CMD" | grep -v grep | tail -n 1 | awk '{print $1}')
    if [ "$RUNNING_USER" = "root" ]; then
        echo -e "${RED}✗ Apache sta attualmente girando come root${NC}"
        issues_found+=("Currently_running_as_root")
    else
        echo -e "${GREEN}✓ Apache sta girando come $RUNNING_USER${NC}"
    fi
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con la configurazione dell'utente Apache.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.1
        backup_dir="/root/apache_user_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup della configurazione in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"

        # Verifica se l'utente apache/www-data esiste
        if ! id -u "$DEFAULT_APACHE_USER" >/dev/null 2>&1; then
            echo -e "${YELLOW}Creazione utente $DEFAULT_APACHE_USER...${NC}"
            groupadd -r "$DEFAULT_APACHE_GROUP" 2>/dev/null
            useradd -r -g "$DEFAULT_APACHE_GROUP" -d "$DEFAULT_APACHE_HOME" -s "$DEFAULT_APACHE_SHELL" "$DEFAULT_APACHE_USER"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Utente $DEFAULT_APACHE_USER creato con successo${NC}"
            else
                echo -e "${RED}✗ Errore nella creazione dell'utente $DEFAULT_APACHE_USER${NC}"
                exit 1
            fi
        fi

        # Modifica il file di configurazione
        echo -e "\n${YELLOW}Aggiornamento configurazione Apache...${NC}"
        sed -i "s/^User.*$/User $DEFAULT_APACHE_USER/" "$MAIN_CONFIG"
        sed -i "s/^Group.*$/Group $DEFAULT_APACHE_GROUP/" "$MAIN_CONFIG"

        # Imposta i permessi corretti sulle directory principali
        echo -e "\n${YELLOW}Impostazione permessi sulle directory...${NC}"
        directories=(
            "$DEFAULT_APACHE_HOME"
            "/var/log/$APACHE_CMD"
            "/var/run/$APACHE_CMD"
        )

        for dir in "${directories[@]}"; do
            if [ -d "$dir" ]; then
                chown -R "$DEFAULT_APACHE_USER:$DEFAULT_APACHE_GROUP" "$dir"
                chmod -R 750 "$dir"
                echo -e "${GREEN}✓ Permessi aggiornati per $dir${NC}"
            fi
        done

        # Verifica della configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_CMD -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"

            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart $APACHE_CMD; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                # Verifica finale
                print_section "Verifica Finale"
                NEW_RUNNING_USER=$(ps -ef | grep "$APACHE_CMD" | grep -v grep | head -n 1 | awk '{print $1}')
                if [ "$NEW_RUNNING_USER" = "$DEFAULT_APACHE_USER" ]; then
                    echo -e "${GREEN}✓ Apache ora sta girando correttamente come $DEFAULT_APACHE_USER${NC}"
                else
                    echo -e "${RED}✗ Apache non sta girando come $DEFAULT_APACHE_USER${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
                echo -e "${YELLOW}Ripristino del backup...${NC}"
                cp -r "$backup_dir/"* "$APACHE_CONFIG_DIR/"
                systemctl restart $APACHE_CMD
                echo -e "${GREEN}Backup ripristinato${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp -r "$backup_dir/"* "$APACHE_CONFIG_DIR/"
            systemctl restart $APACHE_CMD
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione dell'utente Apache è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica l'utente Apache configurato in: $MAIN_CONFIG"
echo "2. Controlla l'utente in esecuzione con: ps -ef | grep $APACHE_CMD"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi
