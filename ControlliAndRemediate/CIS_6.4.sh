#!/bin/bash
# da mettere apposto non fa remediation correttamente
# verificare problema nome file
#

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

print_section "Verifica CIS 6.4: Configurazione Rotazione Log"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
    APACHE_GROUP="apache"
    LOGROTATE_CONF="/etc/logrotate.d/httpd"
    LOG_DIR="/var/log/httpd"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    LOGROTATE_CONF="/etc/logrotate.d/apache2"
    LOG_DIR="/var/log/apache2"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Configurazione logrotate necessaria
read -r -d '' LOGROTATE_CONFIG << EOM
$LOG_DIR/*log {
    daily
    rotate 30
    compress
    delaycompress
    notifempty
    missingok
    sharedscripts
    postrotate
        /bin/systemctl reload httpd.service > /dev/null 2>/dev/null || true
    endscript
}
EOM

print_section "Verifica Configurazione Logrotate"

# Funzione per verificare la configurazione logrotate
check_logrotate_config() {
    local config_file="$1"
    local issues=""
    local found_config=false
    
    echo "Controllo configurazione in $config_file..."
    
    # Verifica se il file esiste
    if [ ! -f "$config_file" ]; then
        echo -e "${RED}✗ File di configurazione logrotate non trovato${NC}"
        issues_found+=("no_logrotate_config")
        return 1
    fi
    
    # Verifica le opzioni necessarie
    local required_options=("daily" "rotate 30" "compress" "delaycompress" "notifempty" "missingok" "sharedscripts")
    
    for option in "${required_options[@]}"; do
        if ! grep -q "^\s*$option" "$config_file"; then
            issues+="Opzione $option non trovata\n"
            found_config=false
        else
            found_config=true
        fi
    done
    
    # Verifica la presenza dello script postrotate
    if ! grep -q "postrotate" "$config_file" || ! grep -q "systemctl reload" "$config_file"; then
        issues+="Script postrotate non configurato correttamente\n"
        found_config=false
    fi
    
    # Verifica i permessi del file
    local file_perms=$(stat -c '%a' "$config_file")
    local file_owner=$(stat -c '%U' "$config_file")
    
    if [ "$file_perms" != "644" ]; then
        issues+="Permessi file non corretti: $file_perms (dovrebbe essere 644)\n"
    fi
    
    if [ "$file_owner" != "root" ]; then
        issues+="Proprietario file non corretto: $file_owner (dovrebbe essere root)\n"
    fi
    
    if [ -n "$issues" ]; then
        echo -e "${RED}Problemi trovati:${NC}"
        echo -e "${RED}$issues${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione logrotate corretta${NC}"
        return 0
    fi
}

# Verifica se logrotate è installato
if ! command_exists logrotate; then
    echo -e "${RED}✗ logrotate non installato${NC}"
    issues_found+=("logrotate_not_installed")
else
    # Verifica la configurazione
    check_logrotate_config "$LOGROTATE_CONF"
    
    # Verifica se logrotate sta girando
    if ! grep -q "logrotate" /etc/cron.daily/* 2>/dev/null; then
        echo -e "${RED}✗ logrotate non configurato nel cron giornaliero${NC}"
        issues_found+=("no_logrotate_cron")
    fi
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione della rotazione dei log.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione esistente
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.4
        backup_dir="/root/apache_logrotate_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        [ -f "$LOGROTATE_CONF" ] && cp -p "$LOGROTATE_CONF" "$backup_dir/"
        
        # Installa logrotate se necessario
        if ! command_exists logrotate; then
            echo -e "\n${YELLOW}Installazione logrotate...${NC}"
            if [ -f /etc/debian_version ]; then
                apt-get update && apt-get install -y logrotate
            else
                yum install -y logrotate
            fi
        fi
        
        # Crea o aggiorna la configurazione logrotate
        echo -e "\n${YELLOW}Aggiornamento configurazione logrotate...${NC}"
        echo "$LOGROTATE_CONFIG" > "$LOGROTATE_CONF"
        
        # Imposta i permessi corretti
        chown root:root "$LOGROTATE_CONF"
        chmod 644 "$LOGROTATE_CONF"
        
        # Verifica la configurazione logrotate
        echo -e "\n${YELLOW}Verifica della configurazione logrotate...${NC}"
        if logrotate -d "$LOGROTATE_CONF" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Configurazione logrotate valida${NC}"
            
            # Test pratico
            echo -e "\n${YELLOW}Esecuzione test di rotazione...${NC}"
            
            # Crea un log di test
            test_log="$LOG_DIR/test.log"
            echo "Test log entry" > "$test_log"
            
            # Forza la rotazione
            if logrotate -f "$LOGROTATE_CONF" >/dev/null 2>&1; then
                if [ -f "${test_log}.1.gz" ] || [ -f "${test_log}.1" ]; then
                    echo -e "${GREEN}✓ Rotazione log funzionante${NC}"
                    
                    # Pulisci i file di test
                    rm -f "$test_log"* 2>/dev/null
                else
                    echo -e "${RED}✗ Rotazione log non funzionante${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il test di rotazione${NC}"
            fi
            
            # Verifica finale
            print_section "Verifica Finale"
            if check_logrotate_config "$LOGROTATE_CONF"; then
                echo -e "\n${GREEN}✓ Configurazione della rotazione log completata con successo${NC}"
            else
                echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
            fi
            
        else
            echo -e "${RED}✗ Errore nella configurazione logrotate${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            [ -f "$backup_dir/$(basename "$LOGROTATE_CONF")" ] && \
                cp -p "$backup_dir/$(basename "$LOGROTATE_CONF")" "$LOGROTATE_CONF"
            
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione della rotazione log è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione logrotate: $LOGROTATE_CONF"
echo "2. Directory log: $LOG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

# Mostra prossima esecuzione logrotate
if [ -f /etc/cron.daily/logrotate ]; then
    next_run=$(date -d "tomorrow 06:25" +"%Y-%m-%d %H:%M")
    echo -e "\n${BLUE}Prossima esecuzione logrotate prevista: $next_run${NC}"
fi
