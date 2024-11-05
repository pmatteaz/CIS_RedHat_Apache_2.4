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

# Array dei moduli WebDAV da controllare
WEBDAV_MODULES=(
    "dav_module"
    "dav_fs_module"
    "dav_lock_module"
)

print_section "Verifica CIS 2.3: Moduli WebDAV"

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

# Array per memorizzare i moduli WebDAV attivi
declare -a active_webdav_modules=()

print_section "Verifica dei Moduli WebDAV"

# Ottiene la lista dei moduli attivi
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

# Controlla ogni modulo WebDAV
for module in "${WEBDAV_MODULES[@]}"; do
    if echo "$ACTIVE_MODULES" | grep -q "$module"; then
        echo -e "${RED}✗ Modulo WebDAV attivo trovato: $module${NC}"
        active_webdav_modules+=("$module")
    else
        echo -e "${GREEN}✓ Modulo WebDAV non attivo: $module${NC}"
    fi
done

# Se ci sono moduli WebDAV attivi, offri remediation
if [ ${#active_webdav_modules[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Trovati ${#active_webdav_modules[@]} moduli WebDAV attivi.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la disabilitazione di questi moduli? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_webdav_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        if [ "$APACHE_CMD" = "httpd" ]; then
            cp -r "$APACHE_CONFIG_DIR/conf.modules.d" "$backup_dir/"
        else
            cp -r "$APACHE_CONFIG_DIR/mods-enabled" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/mods-available" "$backup_dir/"
        fi
        
        # Disabilitazione dei moduli WebDAV
        for module in "${active_webdav_modules[@]}"; do
            echo -e "\n${YELLOW}Disabilitazione $module...${NC}"
            
            # Per sistemi Red Hat
            if [ "$APACHE_CMD" = "httpd" ]; then
                # Cerca in tutti i file .conf nella directory modules.d
                find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i "s/^LoadModule ${module}/##LoadModule ${module}/" {} \;
                
            # Per sistemi Debian
            else
                module_name=$(echo "$module" | sed 's/_module$//')
                if ! a2dismod "${module_name}"; then
                    echo -e "${RED}Errore nella disabilitazione del modulo ${module_name}${NC}"
                    continue
                fi
            fi
        done
        
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
                webdav_still_active=0
                
                for module in "${WEBDAV_MODULES[@]}"; do
                    if echo "$FINAL_MODULES" | grep -q "$module"; then
                        echo -e "${RED}✗ Modulo $module ancora attivo${NC}"
                        webdav_still_active=1
                    else
                        echo -e "${GREEN}✓ Modulo $module disabilitato con successo${NC}"
                    fi
                done
                
                if [ $webdav_still_active -eq 0 ]; then
                    echo -e "\n${GREEN}✓ Tutti i moduli WebDAV sono stati disabilitati con successo${NC}"
                else
                    echo -e "\n${RED}✗ Alcuni moduli WebDAV sono ancora attivi${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            if [ "$APACHE_CMD" = "httpd" ]; then
                cp -r "$backup_dir/conf.modules.d/"* "$APACHE_CONFIG_DIR/conf.modules.d/"
            else
                cp -r "$backup_dir/mods-enabled/"* "$APACHE_CONFIG_DIR/mods-enabled/"
                cp -r "$backup_dir/mods-available/"* "$APACHE_CONFIG_DIR/mods-available/"
            fi
            
            systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun modulo WebDAV attivo trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep dav_"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
echo "3. Se necessario, i backup sono disponibili in: $backup_dir"
