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

print_section "Verifica CIS 6.2: Configurazione Syslog per il Logging degli Errori"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    RSYSLOG_CONFIG="/etc/rsyslog.conf"
    RSYSLOG_APACHE_CONFIG="/etc/rsyslog.d/apache.conf"
    LOG_DIR="/var/log/httpd"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    RSYSLOG_CONFIG="/etc/rsyslog.conf"
    RSYSLOG_APACHE_CONFIG="/etc/rsyslog.d/apache.conf"
    LOG_DIR="/var/log/apache2"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Configurazioni necessarie
SYSLOG_FACILITY="local1"
ERRORLOG_CONFIG="ErrorLog \"syslog:${SYSLOG_FACILITY}\""
RSYSLOG_APACHE_RULE="$SYSLOG_FACILITY.* $LOG_DIR/error_log"

print_section "Verifica Configurazione Syslog"

# Funzione per verificare la configurazione syslog
check_syslog_config() {
    local apache_config="$1"
    local rsyslog_config="$2"
    local found_syslog=false
    local found_rsyslog=false
    local issues=""
    
    echo "Controllo configurazione Apache in $apache_config..."
    
    # Verifica ErrorLog con syslog
    if grep -q "^ErrorLog.*syslog:" "$apache_config"; then
        found_syslog=true
        # Verifica che sia configurato con il facility corretto
        if ! grep -q "^ErrorLog.*syslog:$SYSLOG_FACILITY" "$apache_config"; then
            issues+="ErrorLog non usa il facility corretto\n"
        fi
    else
        issues+="ErrorLog non configurato per syslog\n"
    fi
    
    echo "Controllo configurazione rsyslog..."
    
    # Verifica configurazione rsyslog
    if [ -f "$rsyslog_config" ]; then
        if grep -q "$SYSLOG_FACILITY.*$LOG_DIR/error_log" "$rsyslog_config" || \
           grep -q "$SYSLOG_FACILITY.*$LOG_DIR/error_log" "$RSYSLOG_APACHE_CONFIG" 2>/dev/null; then
            found_rsyslog=true
        fi
    fi
    
    if [ "$found_syslog" = false ]; then
        echo -e "${RED}✗ Configurazione syslog in Apache non trovata${NC}"
        issues_found+=("no_syslog_config")
    fi
    
    if [ "$found_rsyslog" = false ]; then
        echo -e "${RED}✗ Configurazione rsyslog per Apache non trovata${NC}"
        issues_found+=("no_rsyslog_config")
    fi
    
    if [ -n "$issues" ]; then
        echo -e "${RED}Problemi trovati:${NC}"
        echo -e "${RED}$issues${NC}"
        return 1
    else
        echo -e "${GREEN}✓ Configurazione syslog corretta${NC}"
        return 0
    fi
}

# Verifica il servizio rsyslog
if ! systemctl is-active --quiet rsyslog; then
    echo -e "${RED}✗ Servizio rsyslog non attivo${NC}"
    issues_found+=("rsyslog_not_running")
fi

# Verifica la configurazione
check_syslog_config "$MAIN_CONFIG" "$RSYSLOG_CONFIG"

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione syslog.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.2
        backup_dir="/root/apache_syslog_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -p "$MAIN_CONFIG" "$backup_dir/"
        [ -f "$RSYSLOG_CONFIG" ] && cp -p "$RSYSLOG_CONFIG" "$backup_dir/"
        [ -f "$RSYSLOG_APACHE_CONFIG" ] && cp -p "$RSYSLOG_APACHE_CONFIG" "$backup_dir/"
        
        # Verifica se rsyslog è installato
        if ! command_exists rsyslogd; then
            echo -e "\n${YELLOW}Installazione rsyslog...${NC}"
            if [ -f /etc/debian_version ]; then
                apt-get update && apt-get install -y rsyslog
            else
                yum install -y rsyslog
            fi
        fi
        
        # Crea directory log se non esiste
        mkdir -p "$LOG_DIR"
        chown root:root "$LOG_DIR"
        chmod 750 "$LOG_DIR"
        
        # Configura Apache per usare syslog
        echo -e "\n${YELLOW}Configurazione Apache per syslog...${NC}"
        if grep -q "^ErrorLog" "$MAIN_CONFIG"; then
            sed -i "s|^ErrorLog.*|$ERRORLOG_CONFIG|" "$MAIN_CONFIG"
        else
            echo "$ERRORLOG_CONFIG" >> "$MAIN_CONFIG"
        fi
        
        # Configura rsyslog
        echo -e "\n${YELLOW}Configurazione rsyslog...${NC}"
        mkdir -p "$(dirname "$RSYSLOG_APACHE_CONFIG")"
        echo "$RSYSLOG_APACHE_RULE" > "$RSYSLOG_APACHE_CONFIG"
        
        # Imposta permessi corretti per il file di configurazione rsyslog
        chown root:root "$RSYSLOG_APACHE_CONFIG"
        chmod 644 "$RSYSLOG_APACHE_CONFIG"
        
        # Riavvia rsyslog
        echo -e "\n${YELLOW}Riavvio rsyslog...${NC}"
        systemctl restart rsyslog
        
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
                
                # Attendi un momento per permettere a syslog di processare il messaggio
                sleep 2
                
                # Verifica se l'errore è stato registrato
                if [ -f "$LOG_DIR/error_log" ]; then
                    if tail -n 5 "$LOG_DIR/error_log" | grep -q "nonexistent"; then
                        echo -e "${GREEN}✓ Logging tramite syslog funzionante${NC}"
                        
                        # Verifica formato del log
                        if tail -n 1 "$LOG_DIR/error_log" | grep -q "$SYSLOG_FACILITY"; then
                            echo -e "${GREEN}✓ Formato syslog corretto${NC}"
                        else
                            echo -e "${YELLOW}! Formato syslog potrebbe non essere corretto${NC}"
                        fi
                    else
                        echo -e "${RED}✗ Logging tramite syslog non funziona correttamente${NC}"
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
            
            # Ripristina dal backup
            cp -p "$backup_dir/$(basename "$MAIN_CONFIG")" "$MAIN_CONFIG"
            [ -f "$backup_dir/$(basename "$RSYSLOG_CONFIG")" ] && cp -p "$backup_dir/$(basename "$RSYSLOG_CONFIG")" "$RSYSLOG_CONFIG"
            [ -f "$backup_dir/$(basename "$RSYSLOG_APACHE_CONFIG")" ] && cp -p "$backup_dir/$(basename "$RSYSLOG_APACHE_CONFIG")" "$RSYSLOG_APACHE_CONFIG"
            
            systemctl restart rsyslog
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione syslog è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione Apache: $MAIN_CONFIG"
echo "2. File di configurazione rsyslog: $RSYSLOG_APACHE_CONFIG"
echo "3. Directory log: $LOG_DIR"
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La configurazione syslog garantisce che:${NC}"
echo -e "${BLUE}- I log di Apache siano gestiti centralmente${NC}"
echo -e "${BLUE}- I log siano protetti e conservati in modo sicuro${NC}"
echo -e "${BLUE}- Si possa implementare una rotazione dei log efficiente${NC}"
echo -e "${BLUE}- I log siano facilmente integrabili con strumenti di monitoraggio${NC}"
