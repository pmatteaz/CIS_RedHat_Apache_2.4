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

print_section "Verifica CIS 6.3: Configurazione Log di Accesso"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    LOG_DIR="/var/log/httpd"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    LOG_DIR="/var/log/apache2"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Configurazioni necessarie
LOGFORMAT_CONFIG='LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-agent}i\"" combined'
CUSTOMLOG_CONFIG='CustomLog "logs/access_log" combined'

print_section "Verifica Configurazione Access Log"

# Funzione per verificare la configurazione dei log di accesso
check_access_log_config() {
    local config_file="$1"
    local found_logformat=false
    local found_customlog=false
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Verifica LogFormat
    if grep -q "^LogFormat.*combined" "$config_file"; then
        found_logformat=true
        # Verifica che contenga tutti i campi necessari
        local current_format=$(grep "^LogFormat.*combined" "$config_file" | tail -1)
        for field in "%h" "%l" "%u" "%t" "\"%r\"" "%>s" "%b" "\"%{Referer}i\"" "\"%{User-agent}i\""; do
            if ! echo "$current_format" | grep -q "$field"; then
                correct_format=false
                issues+="Campo $field mancante nel LogFormat\n"
            fi
        done
    else
        issues+="LogFormat combined non trovato\n"
    fi
    
    # Verifica CustomLog
    if grep -q "^CustomLog.*combined" "$config_file"; then
        found_customlog=true
    else
        issues+="CustomLog non trovato o non usa il formato combined\n"
    fi
    
    if [ "$found_logformat" = false ] || [ "$found_customlog" = false ]; then
        echo -e "${RED}✗ Configurazione access log non completa${NC}"
        issues_found+=("missing_access_log_config")
    fi
    
    if [ -n "$issues" ]; then
        echo -e "${RED}Problemi trovati:${NC}"
        echo -e "${RED}$issues${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Configurazione access log corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione
check_access_log_config "$MAIN_CONFIG"

# Verifica l'esistenza e i permessi della directory dei log
if [ ! -d "$LOG_DIR" ]; then
    echo -e "${RED}✗ Directory dei log non trovata: $LOG_DIR${NC}"
    issues_found+=("no_log_dir")
else
    # Verifica permessi directory
    dir_perms=$(stat -c '%a' "$LOG_DIR")
    dir_owner=$(stat -c '%U' "$LOG_DIR")
    dir_group=$(stat -c '%G' "$LOG_DIR")
    
    if [ "$dir_perms" != "750" ]; then
        echo -e "${RED}✗ Permessi directory log non corretti: $dir_perms (dovrebbe essere 750)${NC}"
        issues_found+=("wrong_log_perms")
    fi
    
    # Verifica access_log se esiste
    if [ -f "$LOG_DIR/access_log" ]; then
        file_perms=$(stat -c '%a' "$LOG_DIR/access_log")
        file_owner=$(stat -c '%U' "$LOG_DIR/access_log")
        file_group=$(stat -c '%G' "$LOG_DIR/access_log")
        
        if [ "$file_perms" != "640" ]; then
            echo -e "${RED}✗ Permessi access_log non corretti: $file_perms (dovrebbe essere 640)${NC}"
            issues_found+=("wrong_file_perms")
        fi
    fi
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione dei log di accesso.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.3
        backup_dir="/root/apache_access_log_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        
        # Crea directory log se non esiste
        if [ ! -d "$LOG_DIR" ]; then
            echo -e "\n${YELLOW}Creazione directory log...${NC}"
            mkdir -p "$LOG_DIR"
        fi
        
        # Imposta permessi corretti sulla directory log
        echo -e "\n${YELLOW}Impostazione permessi directory log...${NC}"
        chown root:"$APACHE_USER" "$LOG_DIR"
        chmod 750 "$LOG_DIR"
        
        # Aggiorna la configurazione
        echo -e "\n${YELLOW}Aggiornamento configurazione log...${NC}"
        
        # LogFormat
        if grep -q "^LogFormat.*combined" "$MAIN_CONFIG"; then
            sed -i '/^LogFormat.*combined/c\'"$LOGFORMAT_CONFIG" "$MAIN_CONFIG"
        else
            echo "$LOGFORMAT_CONFIG" >> "$MAIN_CONFIG"
        fi
        
        # CustomLog
        if grep -q "^CustomLog.*combined" "$MAIN_CONFIG"; then
            sed -i '/^CustomLog.*combined/c\'"$CUSTOMLOG_CONFIG" "$MAIN_CONFIG"
        else
            echo "$CUSTOMLOG_CONFIG" >> "$MAIN_CONFIG"
        fi
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                # Test di logging
                echo -e "\n${YELLOW}Test di logging di accesso...${NC}"
                
                # Genera una richiesta di test
                curl -s -A "Test-Agent" "http://localhost/" > /dev/null
                
                # Attendi un momento per permettere la scrittura del log
                sleep 2
                
                # Verifica il log di accesso
                if [ -f "$LOG_DIR/access_log" ]; then
                    last_log=$(tail -n 1 "$LOG_DIR/access_log")
                    
                    # Verifica la presenza dei campi richiesti nel log
                    local fields_ok=true
                    for field in "Test-Agent" "GET" "HTTP" "["; do
                        if ! echo "$last_log" | grep -q "$field"; then
                            fields_ok=false
                            break
                        fi
                    done
                    
                    if [ "$fields_ok" = true ]; then
                        echo -e "${GREEN}✓ Log di accesso funzionante e formattato correttamente${NC}"
                        echo "Ultimo log: $last_log"
                    else
                        echo -e "${RED}✗ Formato del log di accesso non corretto${NC}"
                    fi
                else
                    echo -e "${RED}✗ File di log di accesso non trovato${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            cp -p "$backup_dir/$(basename "$MAIN_CONFIG")" "$MAIN_CONFIG"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione dei log di accesso è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. Directory log: $LOG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione dei log di accesso garantisce che:${NC}"
echo -e "${BLUE}- Tutte le richieste siano registrate con dettagli sufficienti${NC}"
echo -e "${BLUE}- I log siano protetti da accessi non autorizzati${NC}"
echo -e "${BLUE}- Si possa tracciare l'attività degli utenti${NC}"
echo -e "${BLUE}- Si possano identificare potenziali problemi di sicurezza${NC}"
