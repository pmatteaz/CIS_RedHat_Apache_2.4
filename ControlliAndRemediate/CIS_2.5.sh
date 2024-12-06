#!/bin/bash
# verificare non va con server_info vedi slb28irt01

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

print_section "Verifica CIS 2.5: Autoindex Module Is Disabled"

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
    MODULES_DIR="$APACHE_CONFIG_DIR/mods-enabled"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

print_section "Verifica del Modulo Status"

# Verifica se il modulo status è caricato
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

if echo "$ACTIVE_MODULES" | grep -q "status_module"; then
    echo -e "${RED}✗ Modulo status è attualmente attivo${NC}"

    # Cerca configurazioni del modulo status
    echo -e "\n${YELLOW}Ricerca configurazioni del modulo status...${NC}"

    # Array per memorizzare i file con configurazioni status
    declare -a status_configs=()

    # Cerca nelle directory di configurazione
    while IFS= read -r -d '' file; do
        if grep -l "mod_status\|status_module\|server-status" "$file" >/dev/null 2>&1; then
            status_configs+=("$file")
            echo -e "${RED}Trovata configurazione status in: $file${NC}"
        fi
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)

    echo -e "\n${YELLOW}Vuoi procedere con la disabilitazione del modulo status? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_2.5
        backup_dir="/root/apache_status_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup della configurazione in $backup_dir..."

        # Backup dei file di configurazione
        if [ "$APACHE_CMD" = "httpd" ]; then
            cp -r "$APACHE_CONFIG_DIR/conf.modules.d" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/conf.d" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/conf" "$backup_dir/"
        else
            cp -r "$APACHE_CONFIG_DIR/mods-enabled" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/mods-available" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/conf-enabled" "$backup_dir/"
        fi

        # Disabilitazione del modulo status
        echo -e "\n${YELLOW}Disabilitazione modulo status...${NC}"

        # Per sistemi Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            # Cerca e commenta il LoadModule per status_module
            find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i 's/^LoadModule status_module/##LoadModule status_module/' {} \;

            # Cerca e commenta le configurazioni di server-status
            for config in "${status_configs[@]}"; do
                sed -i 's/^[[:space:]]*<Location \/server-status>/##<Location \/server-status>/' "$config"
                sed -i 's/^[[:space:]]*SetHandler server-status/##SetHandler server-status/' "$config"
                sed -i 's/^[[:space:]]*<\/Location>/##<\/Location>/' "$config"
            done

        # Per sistemi Debian
        else
            if ! a2dismod status; then
                echo -e "${RED}Errore nella disabilitazione del modulo status${NC}"
                exit 1
            fi

            # Rimuovi eventuali configurazioni residue
            for config in "${status_configs[@]}"; do
                sed -i '/server-status/d' "$config"
            done
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

                if ! echo "$FINAL_MODULES" | grep -q "status_module"; then
                    echo -e "${GREEN}✓ Modulo status disabilitato con successo${NC}"

                    # Verifica accesso a server-status
                    if command_exists curl; then
                        echo -e "\n${YELLOW}Verifica accesso a server-status...${NC}"
                        if ! curl -s -I "http://localhost/server-status" | grep -q "200 OK"; then
                            echo -e "${GREEN}✓ /server-status non è più accessibile${NC}"
                        else
                            echo -e "${RED}✗ /server-status è ancora accessibile${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}✗ Modulo status è ancora attivo${NC}"
                fi

            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"

            if [ "$APACHE_CMD" = "httpd" ]; then
                cp -r "$backup_dir/conf.modules.d/"* "$APACHE_CONFIG_DIR/conf.modules.d/"
                cp -r "$backup_dir/conf/"* "$APACHE_CONFIG_DIR/conf/"
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
    echo -e "${GREEN}✓ Modulo status non è attivo${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep status"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi
