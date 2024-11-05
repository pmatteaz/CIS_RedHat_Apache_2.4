#!/bin/bash
# ## 2.1 Ensure Only Necessary Authentication and Authorization Modules Are Enabled

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Funzione per stampare intestazioni delle sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Lista dei moduli di autenticazione comunemente non necessari
#UNNECESSARY_AUTH_MODULES=(
#    "auth_digest_module"
#    "auth_form_module"
#    "authn_anon_module"
#    "authn_dbd_module"
#    "authn_dbm_module"
#    "authn_socache_module"
#    "authz_dbd_module"
#    "authz_dbm_module"
#    "authz_owner_module"
#)
UNNECESSARY_AUTH_MODULES=(
    "auth_digest_module"
)

# Lista dei moduli di autenticazione essenziali
ESSENTIAL_AUTH_MODULES=(
    "auth_basic_module"
    "authn_core_module"
    "authn_file_module"
    "authz_core_module"
    "authz_host_module"
    "authz_user_module"
    "authz_groupfile_module"
)

print_section "Verifica CIS 2.1: Moduli di Autenticazione e Autorizzazione"

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
elif [ -d "/etc/apache2" ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
else
    echo -e "${RED}Directory di configurazione di Apache non trovata${NC}"
    exit 1
fi

# Array per tenere traccia dei moduli non necessari attivi
declare -a active_unnecessary=()

print_section "Verifica dei Moduli di Autenticazione Attivi"

# Verifica i moduli attivi
echo "Controllo moduli di autenticazione..."
MODULES=$($APACHE_CMD -M 2>/dev/null | grep '_module' || apache2ctl -M 2>/dev/null | grep '_module')

# Verifica moduli non necessari
for module in "${UNNECESSARY_AUTH_MODULES[@]}"; do
    if echo "$MODULES" | grep -q "$module"; then
        active_unnecessary+=("$module")
        echo -e "${RED}✗ Modulo non necessario attivo: $module${NC}"
    fi
done

# Verifica moduli essenziali
echo -e "\n${YELLOW}Verifica moduli essenziali:${NC}"
for module in "${ESSENTIAL_AUTH_MODULES[@]}"; do
    if echo "$MODULES" | grep -q "$module"; then
        echo -e "${GREEN}✓ Modulo essenziale presente: $module${NC}"
    else
        echo -e "${RED}✗ Modulo essenziale mancante: $module${NC}"
    fi
done

# Se ci sono moduli non necessari attivi, offri la remediation
if [ ${#active_unnecessary[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#active_unnecessary[@]} moduli non necessari attivi.${NC}"
    echo "Vuoi procedere con la disabilitazione di questi moduli? (s/n)"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup della configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_2.1
        backup_dir="/root/apache_modules_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup della configurazione in $backup_dir..."
        if [ -d "$APACHE_CONFIG_DIR/conf.modules.d" ]; then
            cp -r "$APACHE_CONFIG_DIR/conf.modules.d" "$backup_dir/"
        elif [ -d "$APACHE_CONFIG_DIR/mods-enabled" ]; then
            cp -r "$APACHE_CONFIG_DIR/mods-enabled" "$backup_dir/"
        fi
        
        # Disabilitazione moduli non necessari
        for module in "${active_unnecessary[@]}"; do
            echo -e "\n${YELLOW}Disabilitazione $module...${NC}"
            
            # Per sistemi basati su Red Hat
            if [ -d "$APACHE_CONFIG_DIR/conf.modules.d" ]; then
                find "$APACHE_CONFIG_DIR/conf.modules.d" -type f -exec sed -i "s/^LoadModule ${module}/##LoadModule ${module}/" {} \;
            
            # Per sistemi basati su Debian
            elif [ -d "$APACHE_CONFIG_DIR/mods-enabled" ]; then
                module_name=$(echo "$module" | sed 's/_module$//')
                if [ -L "$APACHE_CONFIG_DIR/mods-enabled/${module_name}.load" ]; then
                    a2dismod "${module_name}"
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
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            if [ -d "$APACHE_CONFIG_DIR/conf.modules.d" ]; then
                cp -r "$backup_dir/conf.modules.d/"* "$APACHE_CONFIG_DIR/conf.modules.d/"
            elif [ -d "$APACHE_CONFIG_DIR/mods-enabled" ]; then
                cp -r "$backup_dir/mods-enabled/"* "$APACHE_CONFIG_DIR/mods-enabled/"
            fi
            systemctl restart $APACHE_CMD 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Non sono stati trovati moduli non necessari attivi${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Verifica i moduli attivi con: $APACHE_CMD -M"
echo "2. Controlla i file di configurazione in: $APACHE_CONFIG_DIR"
echo "3. Monitora il log di Apache per eventuali errori"
echo -e "\n${BLUE}Nota: Alcuni moduli potrebbero essere necessari per specifiche applicazioni web${NC}"
echo -e "${BLUE}Verifica sempre la compatibilità con le tue applicazioni prima di disabilitare i moduli${NC}"

if [ -d "$backup_dir" ]; then
    echo -e "\n${GREEN}Un backup della configurazione è stato salvato in: $backup_dir${NC}"
fi
