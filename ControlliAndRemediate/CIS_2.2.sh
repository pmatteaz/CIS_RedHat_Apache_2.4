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

print_section "Verifica CIS 2.2: Modulo Log Config"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il comando Apache corretto
APACHE_CMD="httpd"
if command_exists apache2; then
    APACHE_CMD="apache2"
fi

# Determina il percorso della configurazione di Apache
if [ -d "/etc/httpd" ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MODULES_DIR="$APACHE_CONFIG_DIR/conf.modules.d"
elif [ -d "/etc/apache2" ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MODULES_DIR="$APACHE_CONFIG_DIR/mods-available"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

# Verifica presenza del modulo log_config
echo -e "\n${YELLOW}Verifica presenza modulo log_config...${NC}"
MODULE_STATUS=$($APACHE_CMD -M 2>/dev/null | grep "log_config_module" || apache2ctl -M 2>/dev/null | grep "log_config_module")

if [ -n "$MODULE_STATUS" ]; then
    echo -e "${GREEN}✓ Modulo log_config è attivo${NC}"
else
    echo -e "${RED}✗ Modulo log_config non è attivo${NC}"
    
    # Offri remediation
    echo -e "\n${YELLOW}Vuoi attivare il modulo log_config? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_2.2
        backup_dir="/root/apache_logconfig_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        
        # Backup basato sul tipo di sistema
        if [ -d "$MODULES_DIR" ]; then
            cp -r "$MODULES_DIR" "$backup_dir/"
        fi
        
        # Per sistemi basati su Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            MODULE_FILE="$MODULES_DIR/00-base.conf"
            if [ ! -f "$MODULE_FILE" ]; then
                MODULE_FILE="$MODULES_DIR/00-log_config.conf"
                touch "$MODULE_FILE"
            fi
            
            # Verifica se il modulo è già presente ma commentato
            if grep -q "^#.*log_config_module" "$MODULE_FILE"; then
                sed -i 's/^#.*\(LoadModule.*log_config_module.*\)/\1/' "$MODULE_FILE"
            else
                echo "LoadModule log_config_module modules/mod_log_config.so" >> "$MODULE_FILE"
            fi
            
            # Aggiunta configurazione di base per il logging
            cat << EOF >> "$APACHE_CONFIG_DIR/conf/httpd.conf"

# Basic logging configuration
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%h %l %u %t \"%r\" %>s %b" common
CustomLog "logs/access_log" combined
ErrorLog "logs/error_log"
LogLevel warn
EOF
            
        # Per sistemi basati su Debian
        elif [ "$APACHE_CMD" = "apache2" ]; then
            if ! a2enmod log_config; then
                echo -e "${RED}Errore nell'attivazione del modulo log_config${NC}"
                exit 1
            fi
        fi
        
        # Verifica della configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_CMD -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                if $APACHE_CMD -M 2>/dev/null | grep -q "log_config_module" || apache2ctl -M 2>/dev/null | grep -q "log_config_module"; then
                    echo -e "${GREEN}✓ Modulo log_config attivato con successo${NC}"
                else
                    echo -e "${RED}✗ Modulo log_config non è stato attivato correttamente${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            if [ -d "$backup_dir/modules" ]; then
                cp -r "$backup_dir/modules/"* "$MODULES_DIR/"
            fi
            
            systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
fi

# Verifica configurazione di logging
print_section "Verifica Configurazione di Logging"

# Array di configurazioni di logging da verificare
declare -a LOG_CONFIGS=(
    "LogFormat"
    "CustomLog"
    "ErrorLog"
    "LogLevel"
)

echo "Controllo configurazioni di logging..."
for config in "${LOG_CONFIGS[@]}"; do
    if grep -r "^$config" "$APACHE_CONFIG_DIR" >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Configurazione $config trovata${NC}"
    else
        echo -e "${RED}✗ Configurazione $config non trovata${NC}"
    fi
done

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep log_config"
echo "2. Controlla i file di log in: /var/log/$APACHE_CMD/ o /var/log/apache2/"
echo "3. Verifica le configurazioni di logging in: $APACHE_CONFIG_DIR"

if [ -d "$backup_dir" ]; then
    echo -e "\n${GREEN}Un backup della configurazione è stato salvato in: $backup_dir${NC}"
fi

echo -e "\n${BLUE}Nota: Assicurati che i file di log siano correttamente ruotati e monitorati${NC}"
