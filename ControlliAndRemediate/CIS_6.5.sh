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

print_section "Verifica CIS 6.5: Verifica e Applicazione Patch di Apache"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    PACKAGE_NAME="httpd"
    UPDATE_CHECK_CMD="yum check-update $PACKAGE_NAME"
    UPDATE_CMD="yum update -y $PACKAGE_NAME"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    PACKAGE_NAME="apache2"
    UPDATE_CHECK_CMD="apt list --upgradable | grep $PACKAGE_NAME"
    UPDATE_CMD="apt-get update && apt-get install -y --only-upgrade $PACKAGE_NAME"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Versione Apache e Aggiornamenti"

# Funzione per ottenere la versione attuale di Apache
get_apache_version() {
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        httpd -v | grep "Server version" | cut -d'/' -f2 | awk '{print $1}'
    else
        apache2 -v | grep "Server version" | cut -d'/' -f2 | awk '{print $1}'
    fi
}

# Funzione per verificare gli aggiornamenti disponibili
check_updates() {
    local updates_available=false
    local update_output

    echo "Controllo aggiornamenti disponibili..."

    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        update_output=$(yum check-update $PACKAGE_NAME 2>/dev/null)
        if [ $? -eq 100 ]; then
            updates_available=true
        fi
    else
        apt-get update >/dev/null 2>&1
        update_output=$(apt list --upgradable 2>/dev/null | grep "$PACKAGE_NAME")
        if [ -n "$update_output" ]; then
            updates_available=true
        fi
    fi

    if [ "$updates_available" = true ]; then
        echo -e "${RED}✗ Aggiornamenti disponibili per Apache${NC}"
        echo "$update_output"
        issues_found+=("updates_available")
        return 1
    else
        echo -e "${GREEN}✓ Apache è aggiornato all'ultima versione${NC}"
        return 0
    fi
}

# Ottieni la versione attuale
CURRENT_VERSION=$(get_apache_version)
echo "Versione Apache attuale: $CURRENT_VERSION"

# Verifica gli aggiornamenti
check_updates

# Verifica la configurazione del sistema di aggiornamenti automatici
#if [ "$SYSTEM_TYPE" = "redhat" ]; then
#    if ! rpm -q yum-cron >/dev/null 2>&1; then
#        echo -e "${YELLOW}! yum-cron non installato per gli aggiornamenti automatici${NC}"
#        issues_found+=("no_auto_updates")
#    fi
#else
#    if ! dpkg -l unattended-upgrades >/dev/null 2>&1; then
#        echo -e "${YELLOW}! unattended-upgrades non installato per gli aggiornamenti automatici${NC}"
#        issues_found+=("no_auto_updates")
#    fi
#fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con gli aggiornamenti di Apache.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup della configurazione Apache
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.5
        backup_dir="/root/apache_update_backup_$timestamp"
        mkdir -p "$backup_dir"

        # Backup delle configurazioni principali
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            cp -r /etc/httpd "$backup_dir/"
        else
            cp -r /etc/apache2 "$backup_dir/"
        fi

        echo "Backup creato in: $backup_dir"

        # Installa sistema di aggiornamenti automatici se mancante
        #if [[ " ${issues_found[@]} " =~ "no_auto_updates" ]]; then
        #    echo -e "\n${YELLOW}Installazione sistema aggiornamenti automatici...${NC}"
        #    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        #        yum install -y yum-cron
        #        # Configura yum-cron per gli aggiornamenti di sicurezza
        #        sed -i 's/^apply_updates = no/apply_updates = yes/' /etc/yum/yum-cron.conf
        #        systemctl enable yum-cron
        #        systemctl start yum-cron
        #    else
        #        apt-get install -y unattended-upgrades
        #        dpkg-reconfigure -plow unattended-upgrades
        #    fi
        #fi

        # Aggiorna Apache
        if [[ " ${issues_found[@]} " =~ "updates_available" ]]; then
            echo -e "\n${YELLOW}Aggiornamento Apache...${NC}"

            # Stoppa Apache
            echo "Arresto Apache..."
            systemctl stop $PACKAGE_NAME

            # Esegui l'aggiornamento
            if eval "$UPDATE_CMD"; then
                echo -e "${GREEN}✓ Aggiornamento completato con successo${NC}"

                # Verifica la nuova versione
                NEW_VERSION=$(get_apache_version)
                echo "Nuova versione Apache: $NEW_VERSION"

                # Verifica la configurazione
                echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
                if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
                    echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"

                    # Riavvio di Apache
                    echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
                    if systemctl restart $PACKAGE_NAME; then
                        echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                        # Test funzionale
                        echo -e "\n${YELLOW}Esecuzione test funzionale...${NC}"
                        if curl -s --head http://localhost/ | grep "200 OK" >/dev/null; then
                            echo -e "${GREEN}✓ Apache risponde correttamente${NC}"
                        else
                            echo -e "${RED}✗ Apache non risponde correttamente${NC}"
                            echo -e "${YELLOW}Ripristino del backup...${NC}"
                            # Ripristina backup e versione precedente
                            if [ "$SYSTEM_TYPE" = "redhat" ]; then
                                yum downgrade -y $PACKAGE_NAME-$CURRENT_VERSION
                            else
                                apt-get install -y --allow-downgrades $PACKAGE_NAME=$CURRENT_VERSION
                            fi
                            if [ -d "$backup_dir" ]; then
                                cp -r "$backup_dir"/* /etc/
                            fi
                            systemctl restart $PACKAGE_NAME
                            echo -e "${GREEN}Backup ripristinato${NC}"
                        fi
                    else
                        echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
                    fi
                else
                    echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
                    echo -e "${YELLOW}Ripristino del backup...${NC}"
                    if [ -d "$backup_dir" ]; then
                        cp -r "$backup_dir"/* /etc/
                    fi
                    systemctl restart $PACKAGE_NAME
                    echo -e "${GREEN}Backup ripristinato${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante l'aggiornamento${NC}"
            fi
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Apache è aggiornato e configurato correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Versione Apache: $(get_apache_version)"
if [ "$SYSTEM_TYPE" = "redhat" ]; then
    echo "2. Stato yum-cron: $(systemctl is-active yum-cron)"
else
    echo "2. Stato unattended-upgrades: $(dpkg -l unattended-upgrades | grep ^ii >/dev/null && echo "installato" || echo "non installato")"
fi
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi
