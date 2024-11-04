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

print_section "Verifica CIS 2.5: Modulo Autoindex"

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

print_section "Verifica del Modulo Autoindex"

# Verifica se il modulo autoindex è caricato
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

if echo "$ACTIVE_MODULES" | grep -q "autoindex_module"; then
    echo -e "${RED}✗ Modulo autoindex è attualmente attivo${NC}"
    
    # Cerca configurazioni del modulo autoindex
    echo -e "\n${YELLOW}Ricerca configurazioni del modulo autoindex...${NC}"
    
    # Array per memorizzare i file con configurazioni autoindex
    declare -a autoindex_configs=()
    
    # Cerca nelle directory di configurazione
    while IFS= read -r -d '' file; do
        if grep -l "Options.*Indexes\|autoindex_module\|Options.*MultiViews" "$file" >/dev/null 2>&1; then
            autoindex_configs+=("$file")
            echo -e "${RED}Trovata configurazione autoindex in: $file${NC}"
        fi
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)
    
    echo -e "\n${YELLOW}Vuoi procedere con la disabilitazione del modulo autoindex? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_autoindex_backup_$timestamp"
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
        
        # Disabilitazione del modulo autoindex
        echo -e "\n${YELLOW}Disabilitazione modulo autoindex...${NC}"
        
        # Per sistemi Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            # Cerca e commenta il LoadModule per autoindex_module
            find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i 's/^LoadModule autoindex_module/##LoadModule autoindex_module/' {} \;
            
            # Modifica le opzioni Indexes nei file di configurazione
            for config in "${autoindex_configs[@]}"; do
                # Rimuovi Indexes dalle Options
                sed -i 's/Options.*Indexes/Options/g' "$config"
                sed -i 's/Options.*MultiViews/Options/g' "$config"
                # Aggiungi -Indexes se non presente
                sed -i '/Options/ s/$/ -Indexes/' "$config"
            done
            
        # Per sistemi Debian
        else
            if ! a2dismod autoindex; then
                echo -e "${RED}Errore nella disabilitazione del modulo autoindex${NC}"
                exit 1
            fi
            
            # Modifica le opzioni Indexes nei file di configurazione
            for config in "${autoindex_configs[@]}"; do
                # Rimuovi Indexes dalle Options
                sed -i 's/Options.*Indexes/Options/g' "$config"
                sed -i 's/Options.*MultiViews/Options/g' "$config"
                # Aggiungi -Indexes se non presente
                sed -i '/Options/ s/$/ -Indexes/' "$config"
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
                
                if ! echo "$FINAL_MODULES" | grep -q "autoindex_module"; then
                    echo -e "${GREEN}✓ Modulo autoindex disabilitato con successo${NC}"
                    
                    # Test di directory listing
                    if command_exists curl; then
                        echo -e "\n${YELLOW}Verifica directory listing...${NC}"
                        TEST_DIR="/var/www/html/test_dir"
                        mkdir -p "$TEST_DIR"
                        if ! curl -s "http://localhost/test_dir/" | grep -q "Index of"; then
                            echo -e "${GREEN}✓ Directory listing non è più accessibile${NC}"
                        else
                            echo -e "${RED}✗ Directory listing è ancora accessibile${NC}"
                        fi
                        rm -rf "$TEST_DIR"
                    fi
                else
                    echo -e "${RED}✗ Modulo autoindex è ancora attivo${NC}"
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
    echo -e "${GREEN}✓ Modulo autoindex non è attivo${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep autoindex"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione del modulo autoindex migliora la sicurezza impedendo il listing delle directory${NC}"
echo -e "${BLUE}Assicurati di avere pagine di indice (index.html, index.php, ecc.) in tutte le directory accessibili${NC}"
