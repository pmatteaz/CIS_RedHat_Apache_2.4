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

# Determina l'utente Apache corretto per il sistema
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
else
    APACHE_USER="apache"  # Default fallback
fi

print_section "Verifica CIS 3.3: L'Account Apache deve essere bloccato"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Verifica se l'utente Apache esiste
if ! id -u "$APACHE_USER" >/dev/null 2>&1; then
    echo -e "${RED}L'utente $APACHE_USER non esiste nel sistema${NC}"
    echo -e "${YELLOW}Vuoi creare l'utente $APACHE_USER? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Creazione Utente Apache"
        
        groupadd -r "$APACHE_USER" 2>/dev/null
        useradd -r -g "$APACHE_USER" -d "/var/www" -s "/sbin/nologin" "$APACHE_USER"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Utente $APACHE_USER creato con successo${NC}"
        else
            echo -e "${RED}✗ Errore nella creazione dell'utente $APACHE_USER${NC}"
            exit 1
        fi
    else
        echo -e "${YELLOW}Operazione annullata${NC}"
        exit 1
    fi
fi

print_section "Verifica dello Stato dell'Account"

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Verifica se l'account è bloccato
echo "Controllo stato password account..."
PASSWD_STATUS=$(passwd -S "$APACHE_USER" 2>/dev/null)

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Impossibile ottenere lo stato della password${NC}"
    issues_found+=("password_status_error")
else
    # Verifica se l'account è bloccato
    if echo "$PASSWD_STATUS" | grep -q "L\|LK"; then
        echo -e "${GREEN}✓ L'account è già bloccato${NC}"
    else
        echo -e "${RED}✗ L'account non è bloccato${NC}"
        issues_found+=("account_not_locked")
    fi
    
    # Verifica se l'account ha una password
    if echo "$PASSWD_STATUS" | grep -q "NP"; then
        echo -e "${GREEN}✓ L'account non ha password impostata${NC}"
    else
        echo -e "${RED}✗ L'account ha una password impostata${NC}"
        issues_found+=("password_set")
    fi
fi

# Verifica le date di scadenza
echo -e "\nControllo date di scadenza account..."
CHAGE_INFO=$(chage -l "$APACHE_USER" 2>/dev/null)

if [ $? -eq 0 ]; then
    # Verifica se l'account è scaduto
    if echo "$CHAGE_INFO" | grep -q "Account expires" && ! echo "$CHAGE_INFO" | grep -q "Account expires.*never"; then
        echo -e "${GREEN}✓ L'account ha una data di scadenza impostata${NC}"
    else
        echo -e "${RED}✗ L'account non ha una data di scadenza${NC}"
        issues_found+=("no_expiry_date")
    fi
    
    # Verifica se la password è scaduta
    if echo "$CHAGE_INFO" | grep -q "Password expires" && ! echo "$CHAGE_INFO" | grep -q "Password expires.*never"; then
        echo -e "${GREEN}✓ La password ha una data di scadenza impostata${NC}"
    else
        echo -e "${RED}✗ La password non ha una data di scadenza${NC}"
        issues_found+=("no_password_expiry")
    fi
else
    echo -e "${RED}✗ Impossibile ottenere informazioni sulla scadenza${NC}"
    issues_found+=("chage_error")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati dei problemi con l'account $APACHE_USER.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_account_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        cp /etc/passwd "$backup_dir/passwd.bak"
        cp /etc/shadow "$backup_dir/shadow.bak"
        
        # Blocco dell'account
        echo -e "\n${YELLOW}Blocco dell'account $APACHE_USER...${NC}"
        
        # Prima rimuovi la password se presente
        passwd -d "$APACHE_USER" 2>/dev/null
        
        # Poi blocca l'account
        if passwd -l "$APACHE_USER"; then
            echo -e "${GREEN}✓ Account bloccato con successo${NC}"
        else
            echo -e "${RED}✗ Errore durante il blocco dell'account${NC}"
            exit 1
        fi
        
        # Imposta date di scadenza
        echo -e "\n${YELLOW}Impostazione date di scadenza...${NC}"
        
        # Imposta la password come già scaduta (data nel passato)
        past_date="2000-01-01"
        if chage -E "$past_date" -I 0 -m 99999 -M 0 -W 0 "$APACHE_USER"; then
            echo -e "${GREEN}✓ Date di scadenza impostate con successo${NC}"
        else
            echo -e "${RED}✗ Errore durante l'impostazione delle date di scadenza${NC}"
        fi
        
        # Verifica finale
        print_section "Verifica Finale"
        
        echo "Controllo stato account..."
        FINAL_STATUS=$(passwd -S "$APACHE_USER" 2>/dev/null)
        
        if echo "$FINAL_STATUS" | grep -q "L\|LK"; then
            echo -e "${GREEN}✓ Account correttamente bloccato${NC}"
        else
            echo -e "${RED}✗ Account non bloccato correttamente${NC}"
        fi
        
        # Test di accesso
        echo -e "\n${YELLOW}Test tentativi di accesso...${NC}"
        
        # Tentativo di login diretto
        if ! su - "$APACHE_USER" -c "echo test" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Login diretto non possibile${NC}"
        else
            echo -e "${RED}✗ Attenzione: È ancora possibile effettuare il login!${NC}"
        fi
        
        # Tentativo di cambio password
        if ! passwd "$APACHE_USER" >/dev/null 2>&1; then
            echo -e "${GREEN}✓ Cambio password non permesso${NC}"
        else
            echo -e "${RED}✗ Attenzione: È possibile cambiare la password!${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ L'account $APACHE_USER è correttamente bloccato e configurato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Account Apache: $APACHE_USER"
echo "2. Stato attuale: $(passwd -S "$APACHE_USER" 2>/dev/null)"
echo "3. Informazioni scadenza:"
chage -l "$APACHE_USER" 2>/dev/null | grep -E "Account expires|Password expires"
if [ -d "$backup_dir" ]; then
    echo "4. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Un account bloccato garantisce che:${NC}"
echo -e "${BLUE}- Non sia possibile effettuare login interattivi${NC}"
echo -e "${BLUE}- Non sia possibile utilizzare l'account per accessi al sistema${NC}"
echo -e "${BLUE}- Il servizio Apache continui a funzionare normalmente${NC}"
echo -e "${BLUE}- Le password non possano essere cambiate${NC}"
