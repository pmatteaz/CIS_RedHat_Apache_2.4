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

print_section "CIS Control 7.9 - Verifica Accesso Contenuto Web via HTTPS"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    SSL_CONF_DIR="/etc/httpd/conf.d"
    MOD_DIR="/etc/httpd/conf.modules.d"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    SSL_CONF_DIR="/etc/apache2/sites-enabled"
    MOD_DIR="/etc/apache2/mods-enabled"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione HTTPS"

# Funzione per verificare la configurazione HTTPS
check_https_redirect() {
    echo "Controllo configurazione reindirizzamento HTTPS..."
    
    local rewrite_enabled=false
    local https_redirect=false
    
    # Verifica se mod_rewrite è caricato
    if $APACHE_CMD -M 2>/dev/null | grep -q "rewrite_module"; then
        echo -e "${GREEN}✓ Modulo mod_rewrite caricato${NC}"
        rewrite_enabled=true
    else
        echo -e "${RED}✗ Modulo mod_rewrite non caricato${NC}"
        issues_found+=("no_rewrite_module")
    fi
    
    # Verifica se mod_ssl è caricato
    if $APACHE_CMD -M 2>/dev/null | grep -q "ssl_module"; then
        echo -e "${GREEN}✓ Modulo SSL caricato${NC}"
    else
        echo -e "${RED}✗ Modulo SSL non caricato${NC}"
        issues_found+=("no_ssl_module")
    fi
    
    # Verifica RewriteEngine e regole HTTPS
    if [ -f "$APACHE_CONF" ]; then
        if grep -q "RewriteEngine On" "$APACHE_CONF"; then
            echo -e "${GREEN}✓ RewriteEngine è attivo${NC}"
            
            # Verifica regole di reindirizzamento HTTPS
            if grep -q "RewriteCond.*HTTPS.*off" "$APACHE_CONF" && \
               grep -q "RewriteRule.*https://%{HTTP_HOST}%{REQUEST_URI}" "$APACHE_CONF"; then
                echo -e "${GREEN}✓ Reindirizzamento HTTPS configurato${NC}"
                https_redirect=true
            else
                echo -e "${RED}✗ Reindirizzamento HTTPS non configurato correttamente${NC}"
                issues_found+=("no_https_redirect")
            fi
        else
            echo -e "${RED}✗ RewriteEngine non attivo${NC}"
            issues_found+=("rewrite_engine_off")
        fi
    else
        echo -e "${RED}✗ File di configurazione Apache non trovato${NC}"
        issues_found+=("no_apache_conf")
        return 1
    fi
    
    # Verifica configurazione SSL
    if [ ! -f "$SSL_CONF_DIR/ssl.conf" ]; then
        echo -e "${RED}✗ Configurazione SSL non trovata${NC}"
        issues_found+=("no_ssl_conf")
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_https_redirect

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione HTTPS.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_7.9
        backup_dir="/root/https_redirect_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$APACHE_CONF" "$backup_dir/"
        
        # Abilita mod_rewrite se necessario
        if [ "$SYSTEM_TYPE" = "debian" ]; then
            a2enmod rewrite
            a2enmod ssl
        elif [ "$SYSTEM_TYPE" = "redhat" ]; then
            if [ ! -f "$MOD_DIR/00-rewrite.conf" ]; then
                echo "LoadModule rewrite_module modules/mod_rewrite.so" > "$MOD_DIR/00-rewrite.conf"
            fi
        fi
        
        echo -e "\n${YELLOW}Configurazione reindirizzamento HTTPS...${NC}"
        
        # Aggiungi o aggiorna la configurazione HTTPS
        if ! grep -q "RewriteEngine On" "$APACHE_CONF"; then
            echo "" >> "$APACHE_CONF"
            echo "# Enable URL rewriting" >> "$APACHE_CONF"
            echo "RewriteEngine On" >> "$APACHE_CONF"
        fi
        
        # Aggiungi regole di reindirizzamento HTTPS se non presenti
        if ! grep -q "RewriteCond.*HTTPS.*off" "$APACHE_CONF"; then
            echo "" >> "$APACHE_CONF"
            echo "# Redirect all HTTP traffic to HTTPS" >> "$APACHE_CONF"
            echo "RewriteCond %{HTTPS} off" >> "$APACHE_CONF"
            echo "RewriteRule ^(.*)$ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]" >> "$APACHE_CONF"
        fi
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_CMD -t; then
            echo -e "${GREEN}✓ Configurazione Apache valida${NC}"
            
            # Riavvia Apache
            echo -e "\n${YELLOW}Riavvio Apache...${NC}"
            systemctl restart $APACHE_CMD
            
            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                if check_https_redirect; then
                    echo -e "\n${GREEN}✓ Reindirizzamento HTTPS configurato correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$APACHE_CONF")" "$APACHE_CONF"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione HTTPS è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione Apache: $APACHE_CONF"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza HTTPS:${NC}"
echo -e "${BLUE}- Tutto il traffico web deve essere cifrato via HTTPS${NC}"
echo -e "${BLUE}- Il reindirizzamento 301 indica ai client di utilizzare sempre HTTPS${NC}"
echo -e "${BLUE}- Verificare che tutti i virtual host supportino HTTPS${NC}"
echo -e "${BLUE}- Considerare l'implementazione di HSTS per maggiore sicurezza${NC}"

# Test reindirizzamento se possibile
if command_exists curl; then
    print_section "Test Reindirizzamento HTTPS"
    echo -e "${YELLOW}Test reindirizzamento HTTP a HTTPS...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    if curl -I -L -s http://localhost 2>/dev/null | grep -q "301 Moved Permanently"; then
        echo -e "${GREEN}✓ Reindirizzamento HTTP a HTTPS funzionante${NC}"
        echo -e "\n${BLUE}Dettagli reindirizzamento:${NC}"
        curl -I -L http://localhost 2>/dev/null | grep -E "HTTP|Location"
    else
        echo -e "${RED}✗ Reindirizzamento non funzionante o non verificabile${NC}"
    fi
fi
