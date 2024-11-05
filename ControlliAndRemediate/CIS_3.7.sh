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

print_section "Verifica CIS 3.7: Sicurezza della Directory Core Dump"

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
    CORE_DUMP_DIR="/var/log/httpd/cores"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_CONF_FILE="$APACHE_CONFIG_DIR/apache2.conf"
    CORE_DUMP_DIR="/var/log/apache2/cores"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione Core Dump"

# Verifica se la direttiva CoreDumpDirectory è configurata
echo "Controllo configurazione CoreDumpDirectory..."
CORE_DUMP_CONFIGURED=$(grep -i "^CoreDumpDirectory" "$APACHE_CONF_FILE" 2>/dev/null)

if [ -z "$CORE_DUMP_CONFIGURED" ]; then
    echo -e "${RED}✗ CoreDumpDirectory non configurata nel file di configurazione Apache${NC}"
    issues_found+=("no_coredump_config")
else
    CONFIGURED_DIR=$(echo "$CORE_DUMP_CONFIGURED" | awk '{print $2}')
    echo -e "${GREEN}✓ CoreDumpDirectory configurata: $CONFIGURED_DIR${NC}"
    
    # Verifica se la directory configurata corrisponde a quella attesa
    if [ "$CONFIGURED_DIR" != "$CORE_DUMP_DIR" ]; then
        echo -e "${YELLOW}! Directory configurata diversa da quella raccomandata${NC}"
        issues_found+=("wrong_directory")
    fi
fi

# Verifica la directory dei core dump
if [ -d "$CORE_DUMP_DIR" ]; then
    echo -e "\nControllo permessi directory $CORE_DUMP_DIR..."
    
    # Verifica proprietario
    OWNER=$(stat -c '%U' "$CORE_DUMP_DIR")
    if [ "$OWNER" != "root" ]; then
        echo -e "${RED}✗ Proprietario errato: $OWNER (dovrebbe essere root)${NC}"
        issues_found+=("wrong_owner")
    else
        echo -e "${GREEN}✓ Proprietario corretto: root${NC}"
    fi
    
    # Verifica gruppo
    GROUP=$(stat -c '%G' "$CORE_DUMP_DIR")
    if [ "$GROUP" != "$APACHE_GROUP" ]; then
        echo -e "${RED}✗ Gruppo errato: $GROUP (dovrebbe essere $APACHE_GROUP)${NC}"
        issues_found+=("wrong_group")
    else
        echo -e "${GREEN}✓ Gruppo corretto: $APACHE_GROUP${NC}"
    fi
    
    # Verifica permessi
    PERMS=$(stat -c '%a' "$CORE_DUMP_DIR")
    if [ "$PERMS" != "750" ]; then
        echo -e "${RED}✗ Permessi errati: $PERMS (dovrebbero essere 750)${NC}"
        issues_found+=("wrong_permissions")
    else
        echo -e "${GREEN}✓ Permessi corretti: 750${NC}"
    fi
else
    echo -e "${RED}✗ Directory core dump non trovata: $CORE_DUMP_DIR${NC}"
    issues_found+=("no_directory")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con la configurazione dei core dump.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_coredump_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        cp "$APACHE_CONF_FILE" "$backup_dir/"
        
        # Crea o assicura la directory dei core dump
        if [ ! -d "$CORE_DUMP_DIR" ]; then
            echo -e "\n${YELLOW}Creazione directory core dump...${NC}"
            mkdir -p "$CORE_DUMP_DIR"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Directory creata con successo${NC}"
            else
                echo -e "${RED}✗ Errore nella creazione della directory${NC}"
                exit 1
            fi
        fi
        
        # Imposta proprietario e gruppo corretti
        echo -e "\n${YELLOW}Impostazione proprietario e gruppo...${NC}"
        chown root:"$APACHE_GROUP" "$CORE_DUMP_DIR"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Proprietario e gruppo impostati correttamente${NC}"
        else
            echo -e "${RED}✗ Errore nell'impostazione di proprietario e gruppo${NC}"
        fi
        
        # Imposta i permessi corretti
        echo -e "\n${YELLOW}Impostazione permessi...${NC}"
        chmod 750 "$CORE_DUMP_DIR"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Permessi impostati correttamente${NC}"
        else
            echo -e "${RED}✗ Errore nell'impostazione dei permessi${NC}"
        fi
        
        # Aggiorna la configurazione Apache
        if ! grep -q "^CoreDumpDirectory" "$APACHE_CONF_FILE"; then
            echo -e "\n${YELLOW}Aggiunta configurazione CoreDumpDirectory...${NC}"
            echo "CoreDumpDirectory $CORE_DUMP_DIR" >> "$APACHE_CONF_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Configurazione aggiunta con successo${NC}"
            else
                echo -e "${RED}✗ Errore nell'aggiunta della configurazione${NC}"
            fi
        else
            echo -e "\n${YELLOW}Aggiornamento configurazione CoreDumpDirectory esistente...${NC}"
            sed -i "s|^CoreDumpDirectory.*|CoreDumpDirectory $CORE_DUMP_DIR|" "$APACHE_CONF_FILE"
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Configurazione aggiornata con successo${NC}"
            else
                echo -e "${RED}✗ Errore nell'aggiornamento della configurazione${NC}"
            fi
        fi
        
        # Verifica la configurazione di Apache
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
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$APACHE_CONF_FILE")" "$APACHE_CONF_FILE"
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        
        echo "Controllo configurazione finale..."
        if grep -q "^CoreDumpDirectory $CORE_DUMP_DIR" "$APACHE_CONF_FILE"; then
            echo -e "${GREEN}✓ CoreDumpDirectory correttamente configurata${NC}"
        else
            echo -e "${RED}✗ CoreDumpDirectory non configurata correttamente${NC}"
        fi
        
        if [ -d "$CORE_DUMP_DIR" ]; then
            FINAL_PERMS=$(stat -c '%U:%G %a' "$CORE_DUMP_DIR")
            echo -e "Permessi finali directory: $FINAL_PERMS"
            if [ "$(stat -c '%U' "$CORE_DUMP_DIR")" = "root" ] && \
               [ "$(stat -c '%G' "$CORE_DUMP_DIR")" = "$APACHE_GROUP" ] && \
               [ "$(stat -c '%a' "$CORE_DUMP_DIR")" = "750" ]; then
                echo -e "${GREEN}✓ Directory core dump configurata correttamente${NC}"
            else
                echo -e "${RED}✗ Directory core dump non configurata correttamente${NC}"
            fi
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione dei core dump è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory core dump: $CORE_DUMP_DIR"
echo "2. File di configurazione: $APACHE_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Una corretta configurazione dei core dump garantisce che:${NC}"
echo -e "${BLUE}- I file di core dump siano salvati in una directory sicura${NC}"
echo -e "${BLUE}- Solo gli utenti autorizzati possano accedere ai core dump${NC}"
echo -e "${BLUE}- Il processo Apache possa scrivere i core dump quando necessario${NC}"
echo -e "${BLUE}- I core dump siano protetti da accessi non autorizzati${NC}"
