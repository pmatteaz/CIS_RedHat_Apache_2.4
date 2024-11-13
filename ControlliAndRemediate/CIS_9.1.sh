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

print_section "CIS Control 9.1 - Verifica Timeout"

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
    APACHE_CONF_D="/etc/httpd/conf.d"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    APACHE_CONF_D="/etc/apache2/conf-available"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Array dei file da controllare
declare -a config_files=("$APACHE_CONF")


print_section "Verifica Configurazione Timeout"

# Funzione per verificare la configurazione del timeout
check_timeout_configuration() {
    echo "Controllo configurazione Timeout..."

    local timeout_found=false
    local config_file=""
    local timeout_correct=false

    # Aggiungi file da conf.d
    if [ -d "$APACHE_CONF_D" ]; then
        while IFS= read -r -d '' file; do
            config_files+=("$file")
        done < <(find "$APACHE_CONF_D" -type f -name "*.conf" -print0)
    fi

    # Controlla ogni file di configurazione
    for conf_file in "${config_files[@]}"; do
        if [ -f "$conf_file" ]; then
            if grep -q "^[[:space:]]*Timeout[[:space:]]" "$conf_file"; then
                timeout_found=true
                config_file="$conf_file"
                echo -e "${BLUE}Timeout trovato in: ${NC}$conf_file"

                local current_value=$(grep "^[[:space:]]*Timeout[[:space:]]" "$conf_file" | awk '{print $2}')
                echo -e "${BLUE}Valore attuale: ${NC}$current_value secondi"

                if [ "$current_value" -le 10 ] 2>/dev/null; then
                    timeout_correct=true
                    echo -e "${GREEN}✓ Timeout è configurato correttamente (≤ 10 secondi)${NC}"
                else
                    echo -e "${RED}✗ Timeout è troppo alto (> 10 secondi)${NC}"
                    issues_found+=("high_timeout")
                fi
            fi
        fi
    done

    if ! $timeout_found; then
        echo -e "${RED}✗ Timeout non configurato esplicitamente${NC}"
        echo -e "${YELLOW}! Verrà utilizzato il valore predefinito di 300 secondi${NC}"
        issues_found+=("no_timeout_config")
    fi

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_timeout_configuration

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione Timeout.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_9.1
        backup_dir="/root/timeout_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                cp "$conf_file" "$backup_dir/"
            fi
        done

        # Determina il file di configurazione da modificare
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            CONF_TO_USE="/etc/apache2/conf-available/timeout.conf"
            touch "$CONF_TO_USE"
            a2enconf timeout
        else
            CONF_TO_USE="$APACHE_CONF"
        fi

        echo -e "\n${YELLOW}Configurazione Timeout...${NC}"

        # Rimuovi eventuali configurazioni Timeout esistenti
        for conf_file in "${config_files[@]}"; do
            if [ -f "$conf_file" ]; then
                sed -i '/^[[:space:]]*Timeout[[:space:]]/d' "$conf_file"
            fi
        done

        # Aggiungi la nuova configurazione
        echo -e "\n# Set timeout to 10 seconds" >> "$CONF_TO_USE"
        echo "Timeout 10" >> "$CONF_TO_USE"

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
                if check_timeout_configuration; then
                    echo -e "\n${GREEN}✓ Timeout configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"

            # Ripristina i file originali
            for conf_file in "${config_files[@]}"; do
                if [ -f "$backup_dir/$(basename "$conf_file")" ]; then
                    cp "$backup_dir/$(basename "$conf_file")" "$conf_file"
                fi
            done

            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione Timeout è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione principale: $APACHE_CONF"
if [ -n "$CONF_TO_USE" ]; then
    echo "2. File configurazione Timeout: $CONF_TO_USE"
fi
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

# Test timeout se possibile
if command_exists curl && command_exists timeout; then
    print_section "Test Timeout"
    echo -e "${YELLOW}Verifica risposta del server con timeout...${NC}"

    # Attendi che Apache sia completamente riavviato
    sleep 2

    echo -e "\n${BLUE}Test connessione rapida:${NC}"
    if curl -ks -I https://localhost > /dev/null; then
        echo -e "${GREEN}✓ Il server risponde correttamente a richieste rapide${NC}"
    fi

    echo -e "\n${BLUE}Test timeout connessione:${NC}"
    if ! timeout 11 curl -ks -o /dev/null https://localhost/nonexistent; then
        echo -e "${GREEN}✓ Il server chiude correttamente le connessioni dopo il timeout${NC}"
    else
        echo -e "${YELLOW}! Impossibile verificare il comportamento del timeout${NC}"
    fi
fi
