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

# Array dei moduli di autenticazione da controllare
AUTH_MODULES=(
    "auth_basic_module"
    "auth_digest_module"
)

print_section "Verifica CIS 2.9: Moduli Basic e Digest Authentication"

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

print_section "Verifica dei Moduli di Autenticazione"

# Ottiene la lista dei moduli attivi
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

# Array per memorizzare i moduli di autenticazione attivi
declare -a active_auth_modules=()

# Controlla ogni modulo di autenticazione
for module in "${AUTH_MODULES[@]}"; do
    if echo "$ACTIVE_MODULES" | grep -q "$module"; then
        echo -e "${RED}✗ Modulo di autenticazione attivo trovato: $module${NC}"
        active_auth_modules+=("$module")
    else
        echo -e "${GREEN}✓ Modulo di autenticazione non attivo: $module${NC}"
    fi
done

# Se ci sono moduli di autenticazione attivi, cerca anche le configurazioni correlate
if [ ${#active_auth_modules[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Ricerca configurazioni di autenticazione...${NC}"
    
    # Array per memorizzare i file con configurazioni di autenticazione
    declare -a auth_configs=()
    
    # Cerca nelle directory di configurazione
    while IFS= read -r -d '' file; do
        if grep -l "AuthType\|AuthName\|AuthUserFile\|AuthDigestDomain\|AuthDigestProvider" "$file" >/dev/null 2>&1; then
            auth_configs+=("$file")
            echo -e "${RED}Trovata configurazione di autenticazione in: $file${NC}"
        fi
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)
    
    # Verifica anche file .htaccess
    if [ -d "/var/www" ]; then
        echo -e "\n${YELLOW}Ricerca configurazioni di autenticazione in file .htaccess...${NC}"
        while IFS= read -r -d '' htaccess; do
            if grep -l "AuthType\|AuthName\|AuthUserFile\|AuthDigestDomain" "$htaccess" >/dev/null 2>&1; then
                auth_configs+=("$htaccess")
                echo -e "${RED}Trovata configurazione di autenticazione in: $htaccess${NC}"
            fi
        done < <(find /var/www -type f -name ".htaccess" -print0)
    fi
    
    echo -e "\n${YELLOW}Trovati ${#active_auth_modules[@]} moduli di autenticazione attivi.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la disabilitazione di questi moduli? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_auth_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        
        # Backup completo della configurazione
        if [ "$APACHE_CMD" = "httpd" ]; then
            cp -r "$MODULES_DIR" "$backup_dir/"
            cp -r "$CONF_DIR" "$backup_dir/"
        else
            cp -r "$APACHE_CONFIG_DIR/mods-enabled" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/mods-available" "$backup_dir/"
            cp -r "$APACHE_CONFIG_DIR/conf-enabled" "$backup_dir/"
        fi
        
        # Backup dei file .htaccess trovati
        if [ ${#auth_configs[@]} -gt 0 ]; then
            mkdir -p "$backup_dir/htaccess_backups"
            for config in "${auth_configs[@]}"; do
                if [[ "$config" == *".htaccess" ]]; then
                    cp "$config" "$backup_dir/htaccess_backups/"
                fi
            done
        fi
        
        # Disabilitazione dei moduli di autenticazione
        echo -e "\n${YELLOW}Disabilitazione moduli di autenticazione...${NC}"
        
        # Per sistemi Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            for module in "${active_auth_modules[@]}"; do
                echo -e "Disabilitazione $module..."
                find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i "s/^LoadModule ${module}/##LoadModule ${module}/" {} \;
            done
            
            # Commenta le configurazioni di autenticazione
            for config in "${auth_configs[@]}"; do
                sed -i 's/^[[:space:]]*AuthType/##AuthType/' "$config"
                sed -i 's/^[[:space:]]*AuthName/##AuthName/' "$config"
                sed -i 's/^[[:space:]]*AuthUserFile/##AuthUserFile/' "$config"
                sed -i 's/^[[:space:]]*AuthDigestDomain/##AuthDigestDomain/' "$config"
                sed -i 's/^[[:space:]]*AuthDigestProvider/##AuthDigestProvider/' "$config"
                sed -i 's/^[[:space:]]*Require/##Require/' "$config"
            done
            
        # Per sistemi Debian
        else
            for module in "${active_auth_modules[@]}"; do
                module_name=$(echo "$module" | sed 's/_module$//')
                echo -e "Disabilitazione $module_name..."
                if ! a2dismod "$module_name" >/dev/null 2>&1; then
                    echo -e "${RED}Errore nella disabilitazione di $module_name${NC}"
                fi
            done
            
            # Commenta le configurazioni di autenticazione
            for config in "${auth_configs[@]}"; do
                sed -i 's/^[[:space:]]*AuthType/##AuthType/' "$config"
                sed -i 's/^[[:space:]]*AuthName/##AuthName/' "$config"
                sed -i 's/^[[:space:]]*AuthUserFile/##AuthUserFile/' "$config"
                sed -i 's/^[[:space:]]*AuthDigestDomain/##AuthDigestDomain/' "$config"
                sed -i 's/^[[:space:]]*AuthDigestProvider/##AuthDigestProvider/' "$config"
                sed -i 's/^[[:space:]]*Require/##Require/' "$config"
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
                auth_still_active=0
                
                for module in "${AUTH_MODULES[@]}"; do
                    if echo "$FINAL_MODULES" | grep -q "$module"; then
                        echo -e "${RED}✗ Modulo $module ancora attivo${NC}"
                        auth_still_active=1
                    else
                        echo -e "${GREEN}✓ Modulo $module disabilitato con successo${NC}"
                    fi
                done
                
                if [ $auth_still_active -eq 0 ]; then
                    echo -e "\n${GREEN}✓ Tutti i moduli di autenticazione sono stati disabilitati con successo${NC}"
                else
                    echo -e "\n${RED}✗ Alcuni moduli di autenticazione sono ancora attivi${NC}"
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
            
            # Ripristino dei file .htaccess
            if [ -d "$backup_dir/htaccess_backups" ]; then
                cp -r "$backup_dir/htaccess_backups/"* "$(dirname "${auth_configs[0]}")/"
            fi
            
            systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Nessun modulo di autenticazione basic o digest attivo trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep auth_"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione dell'autenticazione basic e digest migliora la sicurezza${NC}"
echo -e "${BLUE}Considera l'utilizzo di metodi di autenticazione più sicuri come:${NC}"
echo -e "${BLUE}- Certificati client SSL${NC}"
echo -e "${BLUE}- Autenticazione tramite reverse proxy con HTTPS${NC}"
echo -e "${BLUE}- Sistemi di Single Sign-On (SSO)${NC}"
