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

print_section "Verifica CIS 2.7: Modulo User Directories"

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
    CONF_DIR="$APACHE_CONFIG_DIR/conf"
elif [ -d "/etc/apache2" ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MODULES_DIR="$APACHE_CONFIG_DIR/mods-enabled"
    CONF_DIR="$APACHE_CONFIG_DIR/conf-enabled"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

print_section "Verifica del Modulo UserDir"

# Verifica se il modulo userdir è caricato
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

if echo "$ACTIVE_MODULES" | grep -q "userdir_module"; then
    echo -e "${RED}✗ Modulo userdir è attualmente attivo${NC}"
    
    # Cerca configurazioni del modulo userdir
    echo -e "\n${YELLOW}Ricerca configurazioni userdir...${NC}"
    
    # Array per memorizzare i file con configurazioni userdir
    declare -a userdir_configs=()
    
    # Cerca nelle directory di configurazione
    while IFS= read -r -d '' file; do
        if grep -l "UserDir\|mod_userdir.c\|mod_userdir.so" "$file" >/dev/null 2>&1; then
            userdir_configs+=("$file")
            echo -e "${RED}Trovata configurazione userdir in: $file${NC}"
        fi
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)
    
    # Verifica se ci sono directory public_html negli home degli utenti
    echo -e "\n${YELLOW}Verifica directory public_html degli utenti...${NC}"
    for userdir in /home/*/public_html; do
        if [ -d "$userdir" ]; then
            echo -e "${RED}Trovata directory public_html in: $userdir${NC}"
        fi
    done
    
    echo -e "\n${YELLOW}Vuoi procedere con la disabilitazione del modulo userdir? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_2.7
        backup_dir="/root/apache_userdir_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        
        # Backup dei file di configurazione
        if [ "$APACHE_CMD" = "httpd" ]; then
            cp -r "$MODULES_DIR" "$backup_dir/"
            cp -r "$CONF_DIR" "$backup_dir/"
        else
            cp -r "$APACHE_CONFIG_DIR/mods-enabled" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/mods-available" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/conf-enabled" "$backup_dir/"
        fi
        
        # Disabilitazione del modulo userdir
        echo -e "\n${YELLOW}Disabilitazione modulo userdir...${NC}"
        
        # Per sistemi Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            # Cerca e commenta il LoadModule per userdir_module
            find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i 's/^LoadModule userdir_module/##LoadModule userdir_module/' {} \;
            
            # Commenta tutte le direttive UserDir
            for config in "${userdir_configs[@]}"; do
                sed -i 's/^[[:space:]]*UserDir/##UserDir/' "$config"
                sed -i 's/^[[:space:]]*<Directory.*public_html>/##&/' "$config"
                sed -i 's/^[[:space:]]*<\/Directory>/##&/' "$config"
            done
            
        # Per sistemi Debian
        else
            if ! a2dismod userdir; then
                echo -e "${RED}Errore nella disabilitazione del modulo userdir${NC}"
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
                print_section "Verifica Finale"
                FINAL_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)
                
                if ! echo "$FINAL_MODULES" | grep -q "userdir_module"; then
                    echo -e "${GREEN}✓ Modulo userdir disabilitato con successo${NC}"
                    
                    # Verifica accesso alle directory degli utenti
                    if command_exists curl; then
                        echo -e "\n${YELLOW}Verifica accesso alle directory degli utenti...${NC}"
                        for user in $(cut -d: -f1 /etc/passwd); do
                            if curl -s "http://localhost/~$user/" | grep -q "Index of" || curl -s "http://localhost/~$user/" | grep -q "public_html"; then
                                echo -e "${RED}✗ Directory dell'utente $user ancora accessibile${NC}"
                            fi
                        done
                        echo -e "${GREEN}✓ Directory degli utenti non sono più accessibili${NC}"
                    fi
                else
                    echo -e "${RED}✗ Modulo userdir è ancora attivo${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            if [ "$APACHE_CMD" = "httpd" ]; then
                cp -r "$backup_dir/conf.modules.d/"* "$MODULES_DIR/"
                cp -r "$backup_dir/conf/"* "$CONF_DIR/"
            else
                cp -r "$backup_dir/mods-enabled/"* "$APACHE_CONFIG_DIR/mods-enabled/"
                cp -r "$backup_dir/mods-available/"* "$APACHE_CONFIG_DIR/mods-available/"
                cp -r "$backup_dir/conf-enabled/"* "$APACHE_CONFIG_DIR/conf-enabled/"
            fi
            
            systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "${GREEN}✓ Modulo userdir non è attivo${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep userdir"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione del modulo userdir migliora la sicurezza impedendo${NC}"
echo -e "${BLUE}l'accesso alle directory personali degli utenti attraverso il web server${NC}"
echo -e "${BLUE}Considera l'utilizzo di alternative più sicure per l'hosting di contenuti personali${NC}"
