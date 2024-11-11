#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Verifica se Apache è installato
if ! command -v httpd >/dev/null 2>&1 && ! command -v apache2 >/dev/null 2>&1; then
    echo -e "${RED}Apache non è installato${NC}"
    exit 1
fi

# Determina la distribuzione e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG="/etc/httpd/conf/httpd.conf"
    SECURITY_CONF="/etc/httpd/conf.d/security.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG="/etc/apache2/apache2.conf"
    SECURITY_CONF="/etc/apache2/conf-available/security.conf"
else
    echo -e "${RED}Distribuzione non supportata${NC}"
    exit 1
fi

# Lista delle estensioni consentite secondo CIS
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

# Creazione della configurazione
echo -e "${YELLOW}Creazione configurazione di sicurezza per le estensioni...${NC}"

# Crea backup
BACKUP_DATE=$(date +%Y%m%d_%H%M%S)
if [ -f "$SECURITY_CONF" ]; then
    cp "$SECURITY_CONF" "${SECURITY_CONF}.${BACKUP_DATE}.bak"
    echo "Backup creato: ${SECURITY_CONF}.${BACKUP_DATE}.bak"
fi

# Genera la stringa delle estensioni permesse
ALLOWED_EXT_STRING=$(IFS="|"; echo "${ALLOWED_EXTENSIONS[*]}")

# Crea la nuova configurazione
cat > "$SECURITY_CONF" << EOF
# Configurazione CIS 5.13 - Gestione estensioni file
# Nega accesso a tutti i file per default
<Files "*">
    Require all denied
</Files>

# Permetti solo le estensioni specificate
<FilesMatch "\.($ALLOWED_EXT_STRING)$">
    Require all granted
</FilesMatch>

# Blocca accesso a file nascosti e di sistema
<FilesMatch "^\.">
    Require all denied
</FilesMatch>

# Blocca file di backup e temporanei
<FilesMatch "(~|\#|\%|\$)$">
    Require all denied
</FilesMatch>
EOF

# Se è Debian/Ubuntu, abilita la configurazione
if [ -f /etc/debian_version ]; then
    if ! a2enconf security > /dev/null 2>&1; then
        echo -e "${RED}Errore nell'abilitare la configurazione di sicurezza${NC}"
        exit 1
    fi
fi

# Verifica la configurazione
echo -e "${YELLOW}Verifica della configurazione Apache...${NC}"
if apache2ctl -t > /dev/null 2>&1 || httpd -t > /dev/null 2>&1; then
    echo -e "${GREEN}Configurazione Apache valida${NC}"
    
    # Riavvia Apache
    echo -e "${YELLOW}Riavvio Apache...${NC}"
    if systemctl restart apache2 > /dev/null 2>&1 || systemctl restart httpd > /dev/null 2>&1; then
        echo -e "${GREEN}Apache riavviato con successo${NC}"
    else
        echo -e "${RED}Errore nel riavvio di Apache${NC}"
        echo -e "${YELLOW}Ripristino backup...${NC}"
        if [ -f "${SECURITY_CONF}.${BACKUP_DATE}.bak" ]; then
            mv "${SECURITY_CONF}.${BACKUP_DATE}.bak" "$SECURITY_CONF"
            systemctl restart apache2 > /dev/null 2>&1 || systemctl restart httpd > /dev/null 2>&1
        fi
        exit 1
    fi
else
    echo -e "${RED}Errore nella configurazione Apache${NC}"
    echo -e "${YELLOW}Ripristino backup...${NC}"
    if [ -f "${SECURITY_CONF}.${BACKUP_DATE}.bak" ]; then
        mv "${SECURITY_CONF}.${BACKUP_DATE}.bak" "$SECURITY_CONF"
    fi
    exit 1
fi

echo -e "\n${GREEN}Configurazione completata con successo${NC}"
echo -e "\nEstensioni permesse:"
for ext in "${ALLOWED_EXTENSIONS[@]}"; do
    echo "- .$ext"
done

echo -e "\n${YELLOW}Note:${NC}"
echo "1. Tutte le altre estensioni sono ora bloccate"
echo "2. I file nascosti (dot files) sono bloccati"
echo "3. I file di backup e temporanei sono bloccati"
echo "4. Configurazione salvata in: $SECURITY_CONF"
echo "5. Backup salvato in: ${SECURITY_CONF}.${BACKUP_DATE}.bak"
