#!/bin/bash
# Da mettere apposto.


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

print_section "Verifica CIS 3.10: Sicurezza del File ScoreBoard"

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
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    SCOREBOARD_FILE="$APACHE_RUN_DIR/apache_runtime_status"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
    APACHE_RUN_DIR="/var/run/apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    SCOREBOARD_FILE="$APACHE_RUN_DIR/apache_runtime_status"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica File ScoreBoard"

# Verifica directory di run
if [ ! -d "$APACHE_RUN_DIR" ]; then
    echo -e "${RED}✗ Directory $APACHE_RUN_DIR non trovata${NC}"
    issues_found+=("no_run_dir")
else
    echo -e "${GREEN}✓ Directory $APACHE_RUN_DIR presente${NC}"

    # Verifica permessi directory
    DIR_PERMS=$(stat -c '%a' "$APACHE_RUN_DIR")
    DIR_OWNER=$(stat -c '%U' "$APACHE_RUN_DIR")
    DIR_GROUP=$(stat -c '%G' "$APACHE_RUN_DIR")

    if [ "$DIR_PERMS" != "755" ] || [ "$DIR_OWNER" != "root" ] || [ "$DIR_GROUP" != "root" ]; then
        echo -e "${RED}✗ Permessi o proprietà directory errati:${NC}"
        echo "Permessi attuali: $DIR_PERMS (dovrebbero essere 755)"
        echo "Proprietario attuale: $DIR_OWNER (dovrebbe essere root)"
        echo "Gruppo attuale: $DIR_GROUP (dovrebbe essere root)"
        issues_found+=("wrong_dir_perms")
    else
        echo -e "${GREEN}✓ Permessi e proprietà directory corretti${NC}"
    fi
fi

# Cerca file ScoreBoard esistenti
echo -e "\nRicerca file ScoreBoard..."
FOUND_SCOREBOARDS=$(find "$APACHE_RUN_DIR" -name "apache_runtime_status*" 2>/dev/null)
if [ -n "$FOUND_SCOREBOARDS" ]; then
    echo -e "${YELLOW}Trovati file ScoreBoard esistenti:${NC}"
    while IFS= read -r file; do
        echo "$file"

        # Verifica proprietà e permessi per ogni file trovato
        FILE_OWNER=$(stat -c '%U' "$file")
        FILE_GROUP=$(stat -c '%G' "$file")
        FILE_PERMS=$(stat -c '%a' "$file")

        if [ "$FILE_OWNER" != "root" ] || \
           [ "$FILE_GROUP" != "$APACHE_GROUP" ] || \
           [ "$FILE_PERMS" != "640" ]; then
            echo -e "${RED}✗ Permessi o proprietà errati per $file${NC}"
            issues_found+=("wrong_file_perms")
        fi
    done <<< "$FOUND_SCOREBOARDS"
else
    echo -e "${YELLOW}Nessun file ScoreBoard trovato (verrà creato da Apache)${NC}"
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con il file ScoreBoard.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.10
        backup_dir="/root/apache_scoreboard_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
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

        # Rimuovi vecchi file ScoreBoard se esistono
        if [ -n "$FOUND_SCOREBOARDS" ]; then
            echo -e "\n${YELLOW}Rimozione vecchi file ScoreBoard...${NC}"
            while IFS= read -r file; do
                rm -f "$file"
                echo "Rimosso: $file"
            done <<< "$FOUND_SCOREBOARDS"
        fi

        # Crea nuovo file ScoreBoard
        echo -e "\n${YELLOW}Creazione nuovo file ScoreBoard...${NC}"
        touch "$SCOREBOARD_FILE"
        chown root:"$APACHE_GROUP" "$SCOREBOARD_FILE"
        chmod 640 "$SCOREBOARD_FILE"

        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"

            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                # Attendi un momento per permettere ad Apache di ricreare il file
                sleep 2

                # Verifica finale
                print_section "Verifica Finale"

                # Controlla nuovamente i file ScoreBoard
                NEW_SCOREBOARDS=$(find "$APACHE_RUN_DIR" -name "apache_runtime_status*" 2>/dev/null)

                if [ -n "$NEW_SCOREBOARDS" ]; then
                    ERRORS=0
                    while IFS= read -r file; do
                        FILE_OWNER=$(stat -c '%U' "$file")
                        FILE_GROUP=$(stat -c '%G' "$file")
                        FILE_PERMS=$(stat -c '%a' "$file")

                        if [ "$FILE_OWNER" = "root" ] && \
                           [ "$FILE_GROUP" = "$APACHE_GROUP" ] && \
                           [ "$FILE_PERMS" = "640" ]; then
                            echo -e "${GREEN}✓ File $file configurato correttamente${NC}"
                        else
                            echo -e "${RED}✗ File $file non configurato correttamente${NC}"
                            echo "Proprietario: $FILE_OWNER (dovrebbe essere root)"
                            echo "Gruppo: $FILE_GROUP (dovrebbe essere $APACHE_GROUP)"
                            echo "Permessi: $FILE_PERMS (dovrebbero essere 640)"
                            ((ERRORS++))
                        fi
                    done <<< "$NEW_SCOREBOARDS"

                    if [ $ERRORS -eq 0 ]; then
                        echo -e "\n${GREEN}✓ Tutti i file ScoreBoard sono configurati correttamente${NC}"
                    else
                        echo -e "\n${RED}✗ Alcuni file ScoreBoard presentano ancora problemi${NC}"
                    fi
                else
                    echo -e "${YELLOW}! Nessun file ScoreBoard trovato dopo il riavvio${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp -r "$backup_dir/"* "$APACHE_RUN_DIR/"
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione del file ScoreBoard è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory di run: $APACHE_RUN_DIR"
echo "2. File ScoreBoard predefinito: $SCOREBOARD_FILE"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi
