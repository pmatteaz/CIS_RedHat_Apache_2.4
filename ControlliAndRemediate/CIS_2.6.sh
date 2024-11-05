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

# Array dei moduli proxy da controllare
PROXY_MODULES=(
    "proxy_module"
    "proxy_connect_module"
    "proxy_ftp_module"
    "proxy_http_module"
    "proxy_fcgi_module"
    "proxy_scgi_module"
    "proxy_uwsgi_module"
    "proxy_fdpass_module"
    "proxy_wstunnel_module"
    "proxy_ajp_module"
    "proxy_balancer_module"
    "proxy_express_module"
    "proxy_hcheck_module"
)

print_section "Verifica CIS 2.6: Moduli Proxy"

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

print_section "Verifica dei Moduli Proxy"

# Ottiene la lista dei moduli attivi
ACTIVE_MODULES=$($APACHE_CMD -M 2>/dev/null || apache2ctl -M 2>/dev/null)

# Array per memorizzare i moduli proxy attivi
declare -a active_proxy_modules=()

# Controlla ogni modulo proxy
for module in "${PROXY_MODULES[@]}"; do
    if echo "$ACTIVE_MODULES" | grep -q "$module"; then
        echo -e "${RED}✗ Modulo proxy attivo trovato: $module${NC}"
        active_proxy_modules+=("$module")
    else
        echo -e "${GREEN}✓ Modulo proxy non attivo: $module${NC}"
    fi
done

# Se ci sono moduli proxy attivi, cerca anche le configurazioni correlate
if [ ${#active_proxy_modules[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Ricerca configurazioni proxy aggiuntive...${NC}"
    
    # Array per memorizzare i file con configurazioni proxy
    declare -a proxy_configs=()
    
    # Cerca nelle directory di configurazione
    while IFS= read -r -d '' file; do
        if grep -l "ProxyPass\|ProxyPassReverse\|ProxyRequest\|AllowCONNECT" "$file" >/dev/null 2>&1; then
            proxy_configs+=("$file")
            echo -e "${RED}Trovata configurazione proxy in: $file${NC}"
        fi
    done < <(find "$APACHE_CONFIG_DIR" -type f -print0)
    
    echo -e "\n${YELLOW}Trovati ${#active_proxy_modules[@]} moduli proxy attivi.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la disabilitazione di questi moduli? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_2.6
        backup_dir="/root/apache_proxy_backup_$timestamp"
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
        
        # Disabilitazione dei moduli proxy
        echo -e "\n${YELLOW}Disabilitazione moduli proxy...${NC}"
        
        # Per sistemi Red Hat
        if [ "$APACHE_CMD" = "httpd" ]; then
            for module in "${active_proxy_modules[@]}"; do
                echo -e "Disabilitazione $module..."
                find "$MODULES_DIR" -type f -name "*.conf" -exec sed -i "s/^LoadModule ${module}/##LoadModule ${module}/" {} \;
            done
            
            # Commenta le configurazioni proxy
            for config in "${proxy_configs[@]}"; do
                sed -i 's/^[[:space:]]*ProxyPass/##ProxyPass/' "$config"
                sed -i 's/^[[:space:]]*ProxyPassReverse/##ProxyPassReverse/' "$config"
                sed -i 's/^[[:space:]]*ProxyRequest/##ProxyRequest/' "$config"
                sed -i 's/^[[:space:]]*AllowCONNECT/##AllowCONNECT/' "$config"
            done
            
        # Per sistemi Debian
        else
            for module in "${active_proxy_modules[@]}"; do
                module_name=$(echo "$module" | sed 's/_module$//')
                echo -e "Disabilitazione $module_name..."
                if ! a2dismod "$module_name" >/dev/null 2>&1; then
                    echo -e "${RED}Errore nella disabilitazione di $module_name${NC}"
                fi
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
                proxy_still_active=0
                
                for module in "${PROXY_MODULES[@]}"; do
                    if echo "$FINAL_MODULES" | grep -q "$module"; then
                        echo -e "${RED}✗ Modulo $module ancora attivo${NC}"
                        proxy_still_active=1
                    else
                        echo -e "${GREEN}✓ Modulo $module disabilitato con successo${NC}"
                    fi
                done
                
                if [ $proxy_still_active -eq 0 ]; then
                    echo -e "\n${GREEN}✓ Tutti i moduli proxy sono stati disabilitati con successo${NC}"
                else
                    echo -e "\n${RED}✗ Alcuni moduli proxy sono ancora attivi${NC}"
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
    echo -e "\n${GREEN}✓ Nessun modulo proxy attivo trovato${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M | grep proxy"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
if [ -d "$backup_dir" ]; then
    echo "3. Backup della configurazione disponibile in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione dei moduli proxy migliora la sicurezza del server${NC}"
echo -e "${BLUE}Se necessiti di funzionalità proxy, considera l'utilizzo di un reverse proxy dedicato${NC}"
