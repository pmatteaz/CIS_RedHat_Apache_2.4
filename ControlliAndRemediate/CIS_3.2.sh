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

# Array di shell non valide accettabili
INVALID_SHELLS=(
    "/sbin/nologin"
    "/bin/false"
    "/usr/sbin/nologin"
)

# Determina l'utente Apache corretto per il sistema
if [ -f /etc/redhat-release ]; then
    APACHE_USER="apache"
elif [ -f /etc/debian_version ]; then
    APACHE_USER="www-data"
else
    APACHE_USER="apache"  # Default fallback
fi

print_section "Verifica CIS 3.2: L'utente Apache deve avere una shell non valida"

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

# Ottieni la shell corrente dell'utente Apache
CURRENT_SHELL=$(getent passwd "$APACHE_USER" | cut -d: -f7)
echo -e "\n${YELLOW}Shell corrente per l'utente $APACHE_USER: $CURRENT_SHELL${NC}"

# Verifica se la shell è valida
SHELL_VALID=0
for invalid_shell in "${INVALID_SHELLS[@]}"; do
    if [ "$CURRENT_SHELL" = "$invalid_shell" ]; then
        SHELL_VALID=1
        break
    fi
done

# Verifica se la shell è nel file /etc/shells
if [ -f "/etc/shells" ] && grep -q "^$CURRENT_SHELL$" "/etc/shells"; then
    echo -e "${RED}✗ La shell $CURRENT_SHELL è presente in /etc/shells${NC}"
    SHELL_VALID=0
fi

if [ $SHELL_VALID -eq 1 ]; then
    echo -e "${GREEN}✓ L'utente $APACHE_USER ha una shell non valida appropriata${NC}"
else
    echo -e "${RED}✗ L'utente $APACHE_USER ha una shell potenzialmente valida: $CURRENT_SHELL${NC}"
    
    echo -e "\n${YELLOW}Vuoi impostare una shell non valida per l'utente $APACHE_USER? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni degli utenti
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_user_shell_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        cp /etc/passwd "$backup_dir/passwd.bak"
        cp /etc/shadow "$backup_dir/shadow.bak"
        
        # Verifica quale shell non valida è disponibile nel sistema
        SELECTED_SHELL=""
        for shell in "${INVALID_SHELLS[@]}"; do
            if [ -f "$shell" ]; then
                SELECTED_SHELL="$shell"
                break
            fi
        done
        
        if [ -z "$SELECTED_SHELL" ]; then
            echo -e "${RED}Non è stata trovata nessuna shell non valida valida nel sistema${NC}"
            exit 1
        fi
        
        # Modifica la shell dell'utente
        echo -e "\n${YELLOW}Impostazione della shell $SELECTED_SHELL per l'utente $APACHE_USER...${NC}"
        if usermod -s "$SELECTED_SHELL" "$APACHE_USER"; then
            echo -e "${GREEN}✓ Shell modificata con successo${NC}"
            
            # Verifica finale
            NEW_SHELL=$(getent passwd "$APACHE_USER" | cut -d: -f7)
            if [ "$NEW_SHELL" = "$SELECTED_SHELL" ]; then
                echo -e "${GREEN}✓ Verifica finale: la shell è stata correttamente impostata a $SELECTED_SHELL${NC}"
                
                # Verifica che la shell non sia in /etc/shells
                if ! grep -q "^$SELECTED_SHELL$" "/etc/shells" 2>/dev/null; then
                    echo -e "${GREEN}✓ La shell non è presente in /etc/shells${NC}"
                else
                    echo -e "${YELLOW}Attenzione: La shell è presente in /etc/shells${NC}"
                    echo -e "${YELLOW}Considerare la rimozione della shell da /etc/shells per maggiore sicurezza${NC}"
                fi
                
                # Verifica tentativi di login
                echo -e "\n${YELLOW}Test tentativo di login...${NC}"
                if ! su - "$APACHE_USER" -s /bin/bash -c "echo test" >/dev/null 2>&1; then
                    echo -e "${GREEN}✓ Login diretto come utente $APACHE_USER non è possibile${NC}"
                else
                    echo -e "${RED}✗ Attenzione: È ancora possibile effettuare il login come utente $APACHE_USER${NC}"
                fi
            else
                echo -e "${RED}✗ La shell non è stata impostata correttamente${NC}"
                echo -e "${YELLOW}Ripristino del backup...${NC}"
                cp "$backup_dir/passwd.bak" /etc/passwd
                cp "$backup_dir/shadow.bak" /etc/shadow
                echo -e "${GREEN}Backup ripristinato${NC}"
            fi
        else
            echo -e "${RED}✗ Errore durante la modifica della shell${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/passwd.bak" /etc/passwd
            cp "$backup_dir/shadow.bak" /etc/shadow
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Utente Apache: $APACHE_USER"
echo "2. Shell attuale: $(getent passwd "$APACHE_USER" | cut -d: -f7)"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La shell non valida garantisce che:${NC}"
echo -e "${BLUE}- L'utente Apache non possa effettuare login interattivi${NC}"
echo -e "${BLUE}- Non sia possibile utilizzare l'account per accessi shell${NC}"
echo -e "${BLUE}- Il servizio Apache funzioni correttamente con privilegi limitati${NC}"
