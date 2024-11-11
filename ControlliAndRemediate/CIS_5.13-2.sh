#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Funzione per stampare messaggi con timestamp
log_message() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Verifica se Apache è installato
if ! command -v httpd >/dev/null 2>&1 && ! command -v apache2 >/dev/null 2>&1; then
    log_message "${RED}Apache non è installato${NC}"
    exit 1
fi

# Determina la distribuzione e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG="/etc/httpd/conf/httpd.conf"
    SECURITY_CONF="/etc/httpd/conf.d/security.conf"
    APACHE_SERVICE="httpd"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG="/etc/apache2/apache2.conf"
    SECURITY_CONF="/etc/apache2/conf-available/security.conf"
    APACHE_SERVICE="apache2"
else
    log_message "${RED}Distribuzione non supportata${NC}"
    exit 1
fi

# Lista delle estensioni consentite
ALLOWED_EXTENSIONS=(
    "html"
    "htm"
    "js"
    "css"
    "png"
    "jpg"
    "jpeg"
    "gif"
    "ico"
)

# Funzione per verificare la configurazione esistente
check_existing_config() {
    local config_file="$1"
    local has_deny_all=false
    local has_allow_specific=false
    local has_dot_files=false
    local has_backup_files=false
    local missing_configs=()

    log_message "${YELLOW}Verifico la configurazione esistente in: $config_file${NC}"

    if [ -f "$config_file" ]; then
        # Verifica deny all
        if grep -q '<Files "\*">' "$config_file" && grep -q 'Require all denied' "$config_file"; then
            has_deny_all=true
            log_message "${GREEN}✓ Trovata configurazione 'deny all'${NC}"
        else
            missing_configs+=("deny_all")
            log_message "${RED}✗ Manca configurazione 'deny all'${NC}"
        fi

        # Verifica allow specific
        if grep -q '<FilesMatch.*\.\(.*\)$' "$config_file"; then
            has_allow_specific=true
            log_message "${GREEN}✓ Trovata configurazione per estensioni permesse${NC}"
            
            # Verifica se tutte le estensioni necessarie sono presenti
            for ext in "${ALLOWED_EXTENSIONS[@]}"; do
                if ! grep -q "$ext" "$config_file"; then
                    has_allow_specific=false
                    missing_configs+=("allowed_extensions")
                    log_message "${RED}✗ Manca estensione .$ext nella configurazione${NC}"
                    break
                fi
            done
        else
            missing_configs+=("allowed_extensions")
            log_message "${RED}✗ Manca configurazione per estensioni permesse${NC}"
        fi

        # Verifica blocco dot files
        if grep -q '<FilesMatch "\^\\.">' "$config_file" || grep -q '<FilesMatch "^\.">' "$config_file"; then
            has_dot_files=true
            log_message "${GREEN}✓ Trovato blocco per dot files${NC}"
        else
            missing_configs+=("dot_files")
            log_message "${RED}✗ Manca blocco per dot files${NC}"
        fi

        # Verifica blocco file di backup
        if grep -q '<FilesMatch.*\(~\|\\#\|%\|\$\)' "$config_file"; then
            has_backup_files=true
            log_message "${GREEN}✓ Trovato blocco per file di backup${NC}"
        else
            missing_configs+=("backup_files")
            log_message "${RED}✗ Manca blocco per file di backup${NC}"
        fi
    else
        log_message "${RED}File di configurazione non trovato${NC}"
        missing_configs+=("all")
    fi

    echo "${missing_configs[@]}"
}

# Funzione per implementare la configurazione mancante
implement_missing_config() {
    local missing_configs=("$@")
    local need_restart=false

    # Crea backup se il file esiste
    if [ -f "$SECURITY_CONF" ]; then
        BACKUP_DATE=$(date +%Y%m%d_%H%M%S)_CIS_5.13
        cp "$SECURITY_CONF" "${SECURITY_CONF}.${BACKUP_DATE}.bak"
        log_message "${GREEN}Backup creato: ${SECURITY_CONF}.${BACKUP_DATE}.bak${NC}"
    fi

    # Se manca tutto o se ci sono configurazioni mancanti, crea/aggiorna il file
    if [[ " ${missing_configs[@]} " =~ "all" ]] || [ ${#missing_configs[@]} -gt 0 ]; then
        ALLOWED_EXT_STRING=$(IFS="|"; echo "${ALLOWED_EXTENSIONS[*]}")
        
        # Crea/aggiorna configurazione
        cat > "$SECURITY_CONF" << EOF
# Configurazione CIS 5.13 - Gestione estensioni file
# Configurazione generata il $(date)

# Nega accesso a tutti i file per default
<Files "*">
    Require all denied
</Files>

# Permetti solo le estensioni specificate
<FilesMatch "\.($ALLOWED_EXT_STRING)$">
    Require all granted
</FilesMatch>

# Blocca accesso a file nascosti
<FilesMatch "^\.">
    Require all denied
</FilesMatch>

# Blocca file di backup e temporanei
<FilesMatch "(~|\#|\%|\$)$">
    Require all denied
</FilesMatch>
EOF

        need_restart=true
        log_message "${GREEN}Configurazione aggiornata${NC}"
    fi

    # Per Debian/Ubuntu, abilita la configurazione
    if [ "$APACHE_SERVICE" = "apache2" ]; then
        a2enconf security > /dev/null 2>&1
    fi

    # Verifica e riavvia se necessario
    if [ "$need_restart" = true ]; then
        log_message "${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_SERVICE -t > /dev/null 2>&1; then
            log_message "${GREEN}Configurazione valida${NC}"
            log_message "${YELLOW}Riavvio Apache...${NC}"
            
            if systemctl restart $APACHE_SERVICE > /dev/null 2>&1; then
                log_message "${GREEN}Apache riavviato con successo${NC}"
            else
                log_message "${RED}Errore nel riavvio di Apache${NC}"
                if [ -f "${SECURITY_CONF}.${BACKUP_DATE}.bak" ]; then
                    log_message "${YELLOW}Ripristino backup...${NC}"
                    mv "${SECURITY_CONF}.${BACKUP_DATE}.bak" "$SECURITY_CONF"
                    systemctl restart $APACHE_SERVICE > /dev/null 2>&1
                fi
                exit 1
            fi
        else
            log_message "${RED}Errore nella configurazione${NC}"
            if [ -f "${SECURITY_CONF}.${BACKUP_DATE}.bak" ]; then
                log_message "${YELLOW}Ripristino backup...${NC}"
                mv "${SECURITY_CONF}.${BACKUP_DATE}.bak" "$SECURITY_CONF"
            fi
            exit 1
        fi
    fi
}

# Esegui la verifica
log_message "${YELLOW}Inizio verifica configurazione CIS 5.13${NC}"
missing_configs=($(check_existing_config "$SECURITY_CONF"))

# Se ci sono configurazioni mancanti, chiedi conferma per l'implementazione
if [ ${#missing_configs[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono state trovate configurazioni mancanti o incomplete.${NC}"
    read -p "Vuoi implementare le configurazioni mancanti? (s/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Ss]$ ]]; then
        implement_missing_config "${missing_configs[@]}"
        log_message "${GREEN}Implementazione completata${NC}"
    else
        log_message "${YELLOW}Implementazione annullata dall'utente${NC}"
    fi
else
    log_message "${GREEN}Tutte le configurazioni necessarie sono già presenti e corrette${NC}"
fi

# Mostra riepilogo finale
echo -e "\n${YELLOW}Riepilogo Configurazione:${NC}"
echo "1. File di configurazione: $SECURITY_CONF"
echo "2. Estensioni permesse:"
for ext in "${ALLOWED_EXTENSIONS[@]}"; do
    echo "   - .$ext"
done
if [ -f "${SECURITY_CONF}.${BACKUP_DATE}.bak" ]; then
    echo "3. Backup: ${SECURITY_CONF}.${BACKUP_DATE}.bak"
fi
