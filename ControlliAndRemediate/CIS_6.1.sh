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

print_section "Verifica CIS 6.1: Configurazione Log Level ed Error Log"

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
LOGLEVEL_CONFIG="LogLevel notice core:info"
ERROR_LOG_CONFIG="ErrorLog \"logs/error_log\""

print_section "Verifica Configurazione LogLevel ed ErrorLog"

# Funzione per verificare la configurazione dei log
check_log_config() {
    local config_file="$1"
    local found_loglevel=false
    local found_errorlog=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Verifica LogLevel
    if grep -q "^LogLevel" "$config_file"; then
        found_loglevel=true
        # Verifica che sia configurato correttamente
        if ! grep -q "^LogLevel notice core:info" "$config_file"; then
            correct_config=false
            issues+="LogLevel non configurato correttamente\n"
        fi
    else
        issues+="LogLevel non trovato\n"
    fi
    
    # Verifica ErrorLog
    if grep -q "^ErrorLog" "$config_file"; then
        found_errorlog=true
        # Verifica che sia configurato e puntato a un percorso valido
        if ! grep -q "^ErrorLog.*error_log" "$config_file"; then
            correct_config=false
            issues+="ErrorLog non configurato correttamente\n"
        fi
    else
        issues+="ErrorLog non trovato\n"
    fi
    
    if [ "$found_loglevel" = false ] || [ "$found_errorlog" = false ]; then
        echo -e "${RED}✗ Configurazioni di log mancanti${NC}"
        issues_found+=("missing_log_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazioni di log non corrette:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazioni di log corrette${NC}"
        return 0
    fi
}

# Verifica la configurazione
check_log_config "$MAIN_CONFIG"

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
    
    if [ "$dir_owner" != "root" ] || [ "$dir_group" != "$APACHE_USER" ]; then
        echo -e "${RED}✗ Proprietario/gruppo directory log non corretti: $dir_owner:$dir_group${NC}"
        issues_found+=("wrong_log_owner")
    fi
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione dei log.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.1
        backup_dir="/root/apache_log_backup_$timestamp"
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
        
        # LogLevel
        if grep -q "^LogLevel" "$MAIN_CONFIG"; then
            sed -i 's/^LogLevel.*/LogLevel notice core:info/' "$MAIN_CONFIG"
        else
            echo "$LOGLEVEL_CONFIG" >> "$MAIN_CONFIG"
        fi
        
        # ErrorLog
        if grep -q "^ErrorLog" "$MAIN_CONFIG"; then
            sed -i 's|^ErrorLog.*|ErrorLog "logs/error_log"|' "$MAIN_CONFIG"
        else
            echo "$ERROR_LOG_CONFIG" >> "$MAIN_CONFIG"
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
                echo -e "\n${YELLOW}Test di logging...${NC}"
                
                # Genera un errore di test
                curl -s "http://localhost/nonexistent" > /dev/null
                
                # Verifica se l'errore è stato registrato
                if [ -f "$LOG_DIR/error_log" ]; then
                    if tail -n 5 "$LOG_DIR/error_log" | grep -q "nonexistent"; then
                        echo -e "${GREEN}✓ Log degli errori funzionante${NC}"
                    else
                        echo -e "${RED}✗ Log degli errori non funziona correttamente${NC}"
                    fi
                    
                    # Verifica formato del log
                    if tail -n 1 "$LOG_DIR/error_log" | grep -q "\[[a-z:]*\]"; then
                        echo -e "${GREEN}✓ Formato log corretto${NC}"
                    else
                        echo -e "${RED}✗ Formato log non corretto${NC}"
                    fi
                else
                    echo -e "${RED}✗ File di log non trovato${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione dei log è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
echo "2. Directory log: $LOG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione dei log garantisce che:${NC}"
echo -e "${BLUE}- Gli errori vengano registrati con il livello appropriato${NC}"
echo -e "${BLUE}- I file di log siano accessibili solo agli utenti autorizzati${NC}"
echo -e "${BLUE}- Le informazioni di debug e gli errori siano tracciabili${NC}"
echo -e "${BLUE}- I log siano protetti e conservati correttamente${NC}"
