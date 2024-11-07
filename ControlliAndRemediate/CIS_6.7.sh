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

print_section "Verifica CIS 6.7: OWASP ModSecurity Core Rule Set"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    MODSEC_PACKAGE="mod_security_crs"
    MODSEC_DIR="/etc/httpd/modsecurity.d"
    ACTIVATED_RULES_DIR="$MODSEC_DIR/activated_rules"
    CRS_SETUP_CONF="$MODSEC_DIR/modsecurity_crs_10_setup.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    MODSEC_PACKAGE="modsecurity-crs"
    MODSEC_DIR="/etc/modsecurity"
    ACTIVATED_RULES_DIR="$MODSEC_DIR/rules"
    CRS_SETUP_CONF="$MODSEC_DIR/crs-setup.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Configurazione CRS necessaria
read -r -d '' CRS_CONFIG << 'EOL'
SecRuleEngine On
SecRequestBodyAccess On
SecRule REQUEST_HEADERS:Content-Type "text/xml" \
     "id:'200000',phase:1,t:none,t:lowercase,pass,nolog,ctl:requestBodyProcessor=XML"
SecRequestBodyLimit 13107200
SecRequestBodyNoFilesLimit 131072
SecRequestBodyInMemoryLimit 131072
SecRequestBodyLimitAction Reject
SecResponseBodyAccess On
SecResponseBodyMimeType text/plain text/html text/xml
SecResponseBodyLimit 524288
SecResponseBodyLimitAction ProcessPartial
SecTmpDir /tmp/
SecDataDir /tmp/
EOL

print_section "Verifica Core Rule Set"

# Funzione per verificare l'installazione del CRS
check_crs_installation() {
    local issues=""
    
    # Verifica se il pacchetto CRS è installato
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        if ! rpm -q $MODSEC_PACKAGE >/dev/null 2>&1; then
            echo -e "${RED}✗ Core Rule Set non installato${NC}"
            issues_found+=("crs_not_installed")
            return 1
        fi
    else
        if ! dpkg -l | grep -q $MODSEC_PACKAGE; then
            echo -e "${RED}✗ Core Rule Set non installato${NC}"
            issues_found+=("crs_not_installed")
            return 1
        fi
    fi
    
    # Verifica directory delle regole attivate
    if [ ! -d "$ACTIVATED_RULES_DIR" ]; then
        echo -e "${RED}✗ Directory delle regole attivate non trovata${NC}"
        issues_found+=("no_rules_dir")
        return 1
    fi
    
    # Verifica la presenza di regole attivate
    if [ -z "$(ls -A $ACTIVATED_RULES_DIR 2>/dev/null)" ]; then
        echo -e "${RED}✗ Nessuna regola attivata trovata${NC}"
        issues_found+=("no_active_rules")
        return 1
    fi
    
    # Verifica configurazione CRS
    if [ ! -f "$CRS_SETUP_CONF" ]; then
        echo -e "${RED}✗ File di configurazione CRS non trovato${NC}"
        issues_found+=("no_crs_config")
        return 1
    else
        # Verifica le direttive necessarie
        local required_directives=(
            "SecRuleEngine On"
            "SecRequestBodyAccess On"
            "SecRequestBodyLimit"
            "SecRequestBodyNoFilesLimit"
            "SecResponseBodyAccess On"
            "SecResponseBodyMimeType"
        )
        
        for directive in "${required_directives[@]}"; do
            if ! grep -q "$directive" "$CRS_SETUP_CONF"; then
                echo -e "${RED}✗ Direttiva mancante: $directive${NC}"
                issues_found+=("missing_directive")
            fi
        done
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        echo -e "${GREEN}✓ Core Rule Set installato e configurato correttamente${NC}"
        return 0
    fi
    return 1
}

# Esegui la verifica
check_crs_installation

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con il Core Rule Set.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni esistenti
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_6.7
        backup_dir="/root/modsecurity_crs_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        if [ -d "$MODSEC_DIR" ]; then
            cp -r "$MODSEC_DIR" "$backup_dir/"
        fi
        
        echo "Backup creato in: $backup_dir"
        
        # Installa CRS se necessario
        if [[ " ${issues_found[@]} " =~ "crs_not_installed" ]]; then
            echo -e "\n${YELLOW}Installazione Core Rule Set...${NC}"
            if [ "$SYSTEM_TYPE" = "redhat" ]; then
                yum install -y $MODSEC_PACKAGE
            else
                apt-get update
                apt-get install -y $MODSEC_PACKAGE
            fi
        fi
        
        # Crea directory necessarie
        mkdir -p "$ACTIVATED_RULES_DIR"
        mkdir -p "/tmp/modsecurity_tmp"
        chmod 750 "/tmp/modsecurity_tmp"
        
        # Configura CRS
        echo -e "\n${YELLOW}Configurazione Core Rule Set...${NC}"
        echo "$CRS_CONFIG" > "$CRS_SETUP_CONF"
        
        # Attiva le regole base
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            # Per sistemi RedHat
            cp /usr/share/modsecurity-crs/rules/*.conf "$ACTIVATED_RULES_DIR/"
        else
            # Per sistemi Debian/Ubuntu
            cp /usr/share/modsecurity-crs/rules/*.conf "$ACTIVATED_RULES_DIR/"
        fi
        
        # Imposta permessi corretti
        chown -R root:root "$MODSEC_DIR"
        chmod -R 644 "$MODSEC_DIR"
        find "$MODSEC_DIR" -type d -exec chmod 755 {} \;
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                # Test delle regole
                echo -e "\n${YELLOW}Test delle regole CRS...${NC}"
                
                # Test con richiesta malevola
                if curl -s -o /dev/null -w "%{http_code}" "http://localhost/?param=<script>alert(1)</script>" | grep -q "403"; then
                    echo -e "${GREEN}✓ CRS blocca correttamente gli attacchi XSS${NC}"
                else
                    echo -e "${RED}✗ CRS potrebbe non bloccare correttamente gli attacchi${NC}"
                fi
                
                # Test con SQL injection
                if curl -s -o /dev/null -w "%{http_code}" "http://localhost/?id=1' OR '1'='1" | grep -q "403"; then
                    echo -e "${GREEN}✓ CRS blocca correttamente le SQL injection${NC}"
                else
                    echo -e "${RED}✗ CRS potrebbe non bloccare correttamente le SQL injection${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            rm -rf "$MODSEC_DIR"/*
            cp -r "$backup_dir/$(basename "$MODSEC_DIR")"/* "$MODSEC_DIR/"
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Il Core Rule Set è installato e configurato correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory ModSecurity: $MODSEC_DIR"
echo "2. Directory regole attive: $ACTIVATED_RULES_DIR"
echo "3. File configurazione CRS: $CRS_SETUP_CONF"
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: Il Core Rule Set correttamente configurato garantisce:${NC}"
echo -e "${BLUE}- Protezione da attacchi web comuni (OWASP Top 10)${NC}"
echo -e "${BLUE}- Filtraggio avanzato delle richieste${NC}"
echo -e "${BLUE}- Protezione da SQL injection, XSS, e altri attacchi${NC}"
echo -e "${BLUE}- Conformità alle best practice di sicurezza${NC}"

# Mostra numero di regole attive
if [ -d "$ACTIVATED_RULES_DIR" ]; then
    rule_count=$(find "$ACTIVATED_RULES_DIR" -type f -name "*.conf" | wc -l)
    echo -e "\n${BLUE}Numero di regole attive: $rule_count${NC}"
fi
