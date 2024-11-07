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

print_section "Verifica CIS 3.9: Sicurezza del File PID"

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
    PID_FILE="$APACHE_RUN_DIR/httpd.pid"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_RUN_DIR="/var/run/apache2"
    PID_FILE="$APACHE_RUN_DIR/apache2.pid"
    APACHE_CONF="/etc/apache2/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica File PID"

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

# Verifica file PID
echo -e "\nControllo file PID $PID_FILE..."

# Verifica se il PidFile è configurato nel file di configurazione
if ! grep -q "^PidFile.*$PID_FILE" "$APACHE_CONF" 2>/dev/null; then
    echo -e "${RED}✗ PidFile non configurato correttamente in $APACHE_CONF${NC}"
    issues_found+=("no_pidfile_config")
fi

if [ -f "$PID_FILE" ]; then
    # Verifica proprietario
    OWNER=$(stat -c '%U' "$PID_FILE")
    if [ "$OWNER" != "root" ]; then
        echo -e "${RED}✗ Proprietario errato: $OWNER (dovrebbe essere root)${NC}"
        issues_found+=("wrong_owner")
    else
        echo -e "${GREEN}✓ Proprietario corretto: root${NC}"
    fi
    
    # Verifica gruppo
    GROUP=$(stat -c '%G' "$PID_FILE")
    if [ "$GROUP" != "$APACHE_GROUP" ]; then
        echo -e "${RED}✗ Gruppo errato: $GROUP (dovrebbe essere $APACHE_GROUP)${NC}"
        issues_found+=("wrong_group")
    else
        echo -e "${GREEN}✓ Gruppo corretto: $APACHE_GROUP${NC}"
    fi
    
    # Verifica permessi
    PERMS=$(stat -c '%a' "$PID_FILE")
    if [ "$PERMS" != "640" ]; then
        echo -e "${RED}✗ Permessi errati: $PERMS (dovrebbero essere 640)${NC}"
        issues_found+=("wrong_perms")
    else
        echo -e "${GREEN}✓ Permessi corretti: 640${NC}"
    fi
else
    echo -e "${YELLOW}! File PID non trovato (verrà creato da Apache)${NC}"
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con il file PID.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.9
        backup_dir="/root/apache_pid_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        if [ -f "$APACHE_CONF" ]; then
            cp "$APACHE_CONF" "$backup_dir/"
        fi
        if [ -d "$APACHE_RUN_DIR" ]; then
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
        
        # Configura PidFile nel file di configurazione
        echo -e "\n${YELLOW}Configurazione PidFile in Apache...${NC}"
        if ! grep -q "^PidFile.*$PID_FILE" "$APACHE_CONF"; then
            # Se c'è già una configurazione PidFile, la sostituiamo
            if grep -q "^PidFile" "$APACHE_CONF"; then
                sed -i "s|^PidFile.*|PidFile $PID_FILE|" "$APACHE_CONF"
            else
                # Altrimenti aggiungiamo la nuova configurazione
                echo "PidFile $PID_FILE" >> "$APACHE_CONF"
            fi
        fi
        
        # Crea/correggi file PID
        echo -e "\n${YELLOW}Configurazione file PID...${NC}"
        touch "$PID_FILE"
        chown root:"$APACHE_GROUP" "$PID_FILE"
        chmod 640 "$PID_FILE"
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Attendi un momento per permettere ad Apache di creare il file PID
                sleep 2
                
                # Verifica finale
                print_section "Verifica Finale"
                
                if [ -f "$PID_FILE" ]; then
                    FINAL_OWNER=$(stat -c '%U' "$PID_FILE")
                    FINAL_GROUP=$(stat -c '%G' "$PID_FILE")
                    FINAL_PERMS=$(stat -c '%a' "$PID_FILE")
                    
                    if [ "$FINAL_OWNER" = "root" ] && \
                       [ "$FINAL_GROUP" = "$APACHE_GROUP" ] && \
                       [ "$FINAL_PERMS" = "640" ]; then
                        echo -e "${GREEN}✓ File PID configurato correttamente${NC}"
                    else
                        echo -e "${RED}✗ File PID non configurato correttamente${NC}"
                        echo "Proprietario: $FINAL_OWNER (dovrebbe essere root)"
                        echo "Gruppo: $FINAL_GROUP (dovrebbe essere $APACHE_GROUP)"
                        echo "Permessi: $FINAL_PERMS (dovrebbero essere 640)"
                    fi
                else
                    echo -e "${RED}✗ File PID non creato dopo il riavvio${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$APACHE_CONF")" "$APACHE_CONF"
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Il file PID è configurato correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory di run: $APACHE_RUN_DIR"
echo "2. File PID: $PID_FILE"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Un file PID correttamente configurato garantisce che:${NC}"
echo -e "${BLUE}- Solo root possa gestire il file PID${NC}"
echo -e "${BLUE}- Il processo Apache possa accedere al file quando necessario${NC}"
echo -e "${BLUE}- Il file sia protetto da accessi non autorizzati${NC}"
echo -e "${BLUE}- Il sistema di gestione dei processi funzioni correttamente${NC}"
