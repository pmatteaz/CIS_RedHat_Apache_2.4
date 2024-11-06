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

print_section "Verifica CIS 6.6: ModSecurity Installato e Attivo"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_PACKAGE="httpd"
    MODSEC_PACKAGE="mod_security"
    APACHE_CONFIG_DIR="/etc/httpd"
    MODSEC_CONFIG_DIR="/etc/httpd/conf.d"
    MODSEC_CONF="$MODSEC_CONFIG_DIR/mod_security.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_PACKAGE="apache2"
    MODSEC_PACKAGE="libapache2-mod-security2"
    APACHE_CONFIG_DIR="/etc/apache2"
    MODSEC_CONFIG_DIR="/etc/modsecurity"
    MODSEC_CONF="$MODSEC_CONFIG_DIR/modsecurity.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica ModSecurity"

# Funzione per verificare ModSecurity
check_modsecurity() {
    local found_module=false
    local correct_config=true
    local issues=""
    
    # Verifica se il modulo è installato
    if [ "$SYSTEM_TYPE" = "redhat" ]; then
        if ! rpm -q $MODSEC_PACKAGE >/dev/null 2>&1; then
            echo -e "${RED}✗ ModSecurity non installato${NC}"
            issues_found+=("modsec_not_installed")
            return 1
        fi
    else
        if ! dpkg -l | grep -q $MODSEC_PACKAGE; then
            echo -e "${RED}✗ ModSecurity non installato${NC}"
            issues_found+=("modsec_not_installed")
            return 1
        fi
    fi
    
    # Verifica se il modulo è caricato
    if ! ($APACHE_PACKAGE -M 2>/dev/null || apache2ctl -M 2>/dev/null) | grep -q "security2_module"; then
        echo -e "${RED}✗ ModSecurity non caricato${NC}"
        issues_found+=("modsec_not_loaded")
        correct_config=false
    else
        echo -e "${GREEN}✓ ModSecurity caricato${NC}"
        found_module=true
    fi
    
    # Verifica la configurazione
    if [ -f "$MODSEC_CONF" ]; then
        echo "Verifica configurazione ModSecurity..."
        
        # Verifica SecRuleEngine
        if ! grep -q "^SecRuleEngine.*On" "$MODSEC_CONF"; then
            echo -e "${RED}✗ SecRuleEngine non attivo${NC}"
            issues_found+=("secengine_not_on")
            correct_config=false
        else
            echo -e "${GREEN}✓ SecRuleEngine attivo${NC}"
        fi
        
    else
        echo -e "${RED}✗ File di configurazione ModSecurity non trovato${NC}"
        issues_found+=("no_modsec_config")
        correct_config=false
    fi
    
    if ! $found_module || ! $correct_config; then
        return 1
    fi
    
    return 0
}

# Esegui il controllo
check_modsecurity

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con ModSecurity.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_modsec_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        # Backup delle configurazioni esistenti
        if [ -d "$MODSEC_CONFIG_DIR" ]; then
            cp -r "$MODSEC_CONFIG_DIR" "$backup_dir/"
        fi
        
        echo "Backup creato in: $backup_dir"
        
        # Installa ModSecurity se necessario
        if [[ " ${issues_found[@]} " =~ "modsec_not_installed" ]]; then
            echo -e "\n${YELLOW}Installazione ModSecurity...${NC}"
            if [ "$SYSTEM_TYPE" = "redhat" ]; then
                yum install -y $MODSEC_PACKAGE
            else
                apt-get update
                apt-get install -y $MODSEC_PACKAGE
            fi
        fi
        
        # Configura ModSecurity
        echo -e "\n${YELLOW}Configurazione ModSecurity...${NC}"
        
        # Crea/aggiorna la configurazione base
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            # Per sistemi RedHat
            cat > "$MODSEC_CONF" << EOL
LoadModule security2_module modules/mod_security2.so
<IfModule security2_module>
    SecRuleEngine On
    SecRequestBodyAccess On
    SecResponseBodyAccess On
    SecResponseBodyMimeType text/plain text/html text/xml
    SecDataDir /tmp/modsecurity_tmp
</IfModule>
EOL
        else
            # Per sistemi Debian/Ubuntu
            if [ -f "$MODSEC_CONFIG_DIR/modsecurity.conf-recommended" ]; then
                cp "$MODSEC_CONFIG_DIR/modsecurity.conf-recommended" "$MODSEC_CONF"
            fi
            sed -i 's/SecRuleEngine DetectionOnly/SecRuleEngine On/' "$MODSEC_CONF"
            a2enmod security2
        fi
        
        # Crea directory temporanea per ModSecurity
        mkdir -p /tmp/modsecurity_tmp
        chown $APACHE_PACKAGE:$APACHE_PACKAGE /tmp/modsecurity_tmp
        chmod 750 /tmp/modsecurity_tmp
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if $APACHE_PACKAGE -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart $APACHE_PACKAGE; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                # Verifica che il modulo sia caricato
                if ($APACHE_PACKAGE -M 2>/dev/null || apache2ctl -M 2>/dev/null) | grep -q "security2_module"; then
                    echo -e "${GREEN}✓ ModSecurity caricato correttamente${NC}"
                    
                    # Test funzionale
                    echo -e "\n${YELLOW}Esecuzione test ModSecurity...${NC}"
                    
                    # Crea una pagina di test
                    test_dir="/var/www/html/modsec_test"
                    mkdir -p "$test_dir"
                    echo "Test page" > "$test_dir/index.html"
                    
                    # Test con una richiesta potenzialmente malevola
                    if curl -s -o /dev/null -w "%{http_code}" "http://localhost/modsec_test/index.html?test=<script>alert(1)</script>" | grep -q "403"; then
                        echo -e "${GREEN}✓ ModSecurity blocca correttamente le richieste malevole${NC}"
                    else
                        echo -e "${YELLOW}! ModSecurity potrebbe non bloccare correttamente le richieste malevole${NC}"
                    fi
                    
                    # Pulizia
                    rm -rf "$test_dir"
                else
                    echo -e "${RED}✗ ModSecurity non caricato dopo il riavvio${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            if [ -d "$backup_dir" ]; then
                cp -r "$backup_dir"/* "$MODSEC_CONFIG_DIR/"
            fi
            systemctl restart $APACHE_PACKAGE
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ ModSecurity è installato e configurato correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione ModSecurity: $MODSEC_CONF"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: ModSecurity correttamente configurato garantisce:${NC}"
echo -e "${BLUE}- Protezione da attacchi web comuni${NC}"
echo -e "${BLUE}- Monitoraggio del traffico HTTP${NC}"
echo -e "${BLUE}- Filtraggio delle richieste malevole${NC}"
echo -e "${BLUE}- Un ulteriore livello di sicurezza per il server web${NC}"

# Mostra il log di ModSecurity se esiste
if [ -f "/var/log/modsec_audit.log" ]; then
    echo -e "\n${BLUE}Ultimi eventi ModSecurity:${NC}"
    tail -n 5 "/var/log/modsec_audit.log"
fi
