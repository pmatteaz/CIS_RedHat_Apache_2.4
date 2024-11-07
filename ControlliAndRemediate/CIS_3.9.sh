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

print_section "CIS Control 3.9 - Verifica PidFile"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    SERVER_ROOT="/etc/httpd"
    DEFAULT_DOCUMENT_ROOT="/var/www/html"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    SERVER_ROOT="/etc/apache2"
    DEFAULT_DOCUMENT_ROOT="/var/www/html"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione PidFile"

# Funzione per ottenere il ServerRoot
get_server_root() {
    local server_root=$(grep "^ServerRoot" "$APACHE_CONF" | awk '{print $2}' | tr -d '"')
    if [ -z "$server_root" ]; then
        echo "$SERVER_ROOT"
    else
        echo "$server_root"
    fi
}

# Funzione per ottenere il DocumentRoot
get_document_root() {
    local document_root=$(grep "^DocumentRoot" "$APACHE_CONF" | awk '{print $2}' | tr -d '"')
    if [ -z "$document_root" ]; then
        echo "$DEFAULT_DOCUMENT_ROOT"
    else
        echo "$document_root"
    fi
}

# Funzione per verificare la configurazione del PidFile
check_pidfile() {
    echo "Controllo configurazione PidFile..."

    # 1. Trova la directory del PidFile
    local server_root=$(get_server_root)
    local pidfile_path="$server_root/`httpd -V | grep DEFAULT_PIDLOG | cut -d"=" -f2 |tr -d '"'`"
    local document_root=$(get_document_root)

    if [ -z "$pidfile_path" ]; then
        # Se PidFile non è specificato, usa il valore predefinito
        pidfile_path="$server_root/logs/httpd.pid"
        echo -e "${YELLOW}! PidFile non specificato, verrà utilizzato il percorso predefinito: $pidfile_path${NC}"
    else
        echo -e "${BLUE}PidFile configurato: ${NC}$pidfile_path"
    fi

    # Ottieni la directory del PidFile
    local pidfile_dir=$(dirname "$pidfile_path")

    # Verifica che pidfile_dir non sia un link in caso ottieni la vera directory
    if [ -L $pidfile_dir ];then
      local pidfile_dir=$(readlink -f $pidfile_dir)
    fi

    # 2. Verifica che la directory del PidFile non sia dentro DocumentRoot
    if [[ "$pidfile_dir" == "$document_root"* ]]; then
        echo -e "${RED}✗ Directory PidFile è all'interno del DocumentRoot${NC}"
        issues_found+=("pidfile_in_docroot")
    else
        echo -e "${GREEN}✓ Directory PidFile non è nel DocumentRoot${NC}"
    fi

    # 3. Verifica proprietario e gruppo della directory
    if [ -d "$pidfile_dir" ]; then
        local dir_owner=$(stat -c "%U" "$pidfile_dir")
        local dir_group=$(stat -c "%G" "$pidfile_dir")

        echo -e "${BLUE}Proprietario directory: ${NC}$dir_owner:$dir_group"

        if [ "$dir_owner" != "root" ] || [ "$dir_group" != "root" ]; then
            echo -e "${RED}✗ Directory non appartiene a root:root${NC}"
            issues_found+=("wrong_ownership")
        else
            echo -e "${GREEN}✓ Directory appartiene a root:root${NC}"
        fi

        # 4. Verifica permessi della directory
        local dir_perms=$(stat -c "%a" "$pidfile_dir")
        echo -e "${BLUE}Permessi directory: ${NC}$dir_perms"

        if [ "$dir_perms" -gt "755" ]; then
            echo -e "${RED}✗ Permessi directory troppo permissivi${NC}"
            issues_found+=("wrong_permissions")
        else
            echo -e "${GREEN}✓ Permessi directory corretti${NC}"
        fi
    else
        echo -e "${RED}✗ Directory PidFile non esiste${NC}"
        issues_found+=("no_pidfile_dir")
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_pidfile

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione del PidFile.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.9
        backup_dir="/root/pidfile_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp "$APACHE_CONF" "$backup_dir/"

        # Determina il percorso sicuro per il PidFile
        SAFE_PIDFILE_DIR="/var/run/apache2"
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            SAFE_PIDFILE_DIR="/var/run/httpd"
        fi

        # Crea directory se non esiste
        if [ ! -d "$SAFE_PIDFILE_DIR" ]; then
            mkdir -p "$SAFE_PIDFILE_DIR"
        fi

        # Imposta proprietario e permessi corretti
        chown root:root "$SAFE_PIDFILE_DIR"
        chmod 755 "$SAFE_PIDFILE_DIR"

        # Aggiorna la configurazione del PidFile
        if grep -q "^PidFile" "$APACHE_CONF"; then
            sed -i "s|^PidFile.*|PidFile $SAFE_PIDFILE_DIR/apache2.pid|" "$APACHE_CONF"
        else
            echo "PidFile $SAFE_PIDFILE_DIR/apache2.pid" >> "$APACHE_CONF"
        fi

        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_CMD -t; then
            echo -e "${GREEN}✓ Configurazione Apache valida${NC}"

            # Riavvia Apache
            echo -e "\n${YELLOW}Riavvio Apache...${NC}"
            systemctl restart $APACHE_CMD

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                # Verifica finale
                print_section "Verifica Finale"
                if check_pidfile; then
                    echo -e "\n${GREEN}✓ PidFile configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$APACHE_CONF")" "$APACHE_CONF"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione del PidFile è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione Apache: $APACHE_CONF"
echo "2. ServerRoot: $(get_server_root)"
echo "3. DocumentRoot: $(get_document_root)"
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza PidFile:${NC}"
echo -e "${BLUE}- Il file PID deve essere in una directory sicura${NC}"
echo -e "${BLUE}- La directory non deve essere accessibile via web${NC}"
echo -e "${BLUE}- Solo root deve poter scrivere nella directory${NC}"
echo -e "${BLUE}- I permessi corretti proteggono da manomissioni${NC}"

# Verifica finale del processo Apache
if pgrep -x "$APACHE_CMD" > /dev/null; then
    echo -e "\n${GREEN}✓ Processo Apache in esecuzione${NC}"
    pidfile=$(grep "^PidFile" "$APACHE_CONF" | awk '{print $2}' | tr -d '"')
    if [ -f "$pidfile" ]; then
        echo -e "${GREEN}✓ File PID presente: $pidfile${NC}"
    else
        echo -e "${RED}✗ File PID non trovato${NC}"
    fi
else
    echo -e "\n${RED}✗ Processo Apache non in esecuzione${NC}"
fi
