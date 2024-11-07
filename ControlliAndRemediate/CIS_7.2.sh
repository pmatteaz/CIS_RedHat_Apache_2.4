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

print_section "CIS Control 7.2 - Verifica Certificato SSL Valido"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    SSL_CONF_DIR="/etc/httpd/conf.d"
    CERT_DIR="/etc/pki/tls/certs"
    PRIVATE_KEY_DIR="/etc/pki/tls/private"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/sites-enabled"
    CERT_DIR="/etc/ssl/certs"
    PRIVATE_KEY_DIR="/etc/ssl/private"
    SSL_CONF_FILE="$SSL_CONF_DIR/default-ssl.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Certificati SSL"

# Funzione per verificare la configurazione SSL
check_ssl_certificate() {
    local cert_file=""
    local key_file=""
    local chain_file=""
    
    echo "Controllo configurazione certificati SSL..."
    
    # Cerca i percorsi dei certificati nel file di configurazione SSL
    if [ -f "$SSL_CONF_FILE" ]; then
        cert_file=$(grep -E "^[[:space:]]*SSLCertificateFile" "$SSL_CONF_FILE" | awk '{print $2}')
        key_file=$(grep -E "^[[:space:]]*SSLCertificateKeyFile" "$SSL_CONF_FILE" | awk '{print $2}')
        chain_file=$(grep -E "^[[:space:]]*SSLCertificateChainFile" "$SSL_CONF_FILE" | awk '{print $2}')
    else
        echo -e "${RED}✗ File di configurazione SSL non trovato${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Verifica esistenza e validità del certificato
    if [ -n "$cert_file" ] && [ -f "$cert_file" ]; then
        echo -e "${GREEN}✓ File certificato trovato: $cert_file${NC}"
        
        # Verifica validità certificato
        cert_info=$(openssl x509 -in "$cert_file" -text -noout 2>/dev/null)
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Certificato valido${NC}"
            
            # Verifica data di scadenza
            expiry_date=$(echo "$cert_info" | grep "Not After" | cut -d: -f2-)
            current_date=$(date)
            echo -e "${BLUE}Data di scadenza: $expiry_date${NC}"
            
            # Confronto date usando date -d
            if [ "$(date -d "$expiry_date" +%s)" -lt "$(date -d "$current_date" +%s)" ]; then
                echo -e "${RED}✗ Certificato scaduto${NC}"
                issues_found+=("expired_cert")
            fi
        else
            echo -e "${RED}✗ Certificato non valido${NC}"
            issues_found+=("invalid_cert")
        fi
    else
        echo -e "${RED}✗ File certificato non trovato${NC}"
        issues_found+=("no_cert_file")
    fi
    
    # Verifica chiave privata
    if [ -n "$key_file" ] && [ -f "$key_file" ]; then
        echo -e "${GREEN}✓ File chiave privata trovato: $key_file${NC}"
        
        # Verifica permessi chiave privata
        key_perms=$(stat -c "%a" "$key_file")
        if [ "$key_perms" != "600" ]; then
            echo -e "${RED}✗ Permessi chiave privata non sicuri: $key_perms${NC}"
            issues_found+=("insecure_key_perms")
        fi
    else
        echo -e "${RED}✗ File chiave privata non trovato${NC}"
        issues_found+=("no_key_file")
    fi
    
    # Verifica chain file se presente
    if [ -n "$chain_file" ]; then
        if [ -f "$chain_file" ]; then
            echo -e "${GREEN}✓ Chain file trovato: $chain_file${NC}"
        else
            echo -e "${YELLOW}! Chain file configurato ma non trovato: $chain_file${NC}"
            issues_found+=("no_chain_file")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_ssl_certificate

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione dei certificati SSL.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/ssl_cert_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        [ -f "$SSL_CONF_FILE" ] && cp "$SSL_CONF_FILE" "$backup_dir/"
        
        # Genera nuova coppia di chiavi e CSR
        echo -e "\n${YELLOW}Generazione nuova coppia di chiavi e CSR...${NC}"
        
        # Definisci i percorsi dei nuovi file
        NEW_KEY="$PRIVATE_KEY_DIR/server.key"
        NEW_CSR="$CERT_DIR/server.csr"
        NEW_CERT="$CERT_DIR/server.crt"
        
        # Genera chiave privata e CSR
        openssl req -new -newkey rsa:2048 -nodes \
            -keyout "$NEW_KEY" \
            -out "$NEW_CSR" \
            -subj "/C=XX/ST=State/L=City/O=Organization/CN=$(hostname)"
        
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}✓ Chiave privata e CSR generati con successo${NC}"
            
            # Imposta permessi corretti
            chmod 600 "$NEW_KEY"
            chown root:root "$NEW_KEY"
            
            # Per scopi di test, genera un certificato self-signed
            echo -e "\n${YELLOW}Generazione certificato self-signed per test...${NC}"
            openssl x509 -req -days 365 -in "$NEW_CSR" \
                -signkey "$NEW_KEY" \
                -out "$NEW_CERT"
            
            # Aggiorna la configurazione SSL
            if [ -f "$SSL_CONF_FILE" ]; then
                echo -e "\n${YELLOW}Aggiornamento configurazione SSL...${NC}"
                sed -i "s|^SSLCertificateFile.*|SSLCertificateFile $NEW_CERT|" "$SSL_CONF_FILE"
                sed -i "s|^SSLCertificateKeyFile.*|SSLCertificateKeyFile $NEW_KEY|" "$SSL_CONF_FILE"
            else
                echo -e "\n${YELLOW}Creazione nuova configurazione SSL...${NC}"
                cat > "$SSL_CONF_FILE" << EOL
SSLCertificateFile $NEW_CERT
SSLCertificateKeyFile $NEW_KEY
EOL
            fi
            
            # Verifica configurazione Apache
            if $APACHE_CMD -t; then
                echo -e "${GREEN}✓ Configurazione Apache valida${NC}"
                
                # Riavvia Apache
                echo -e "\n${YELLOW}Riavvio Apache...${NC}"
                systemctl restart $APACHE_CMD
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                    echo -e "\n${YELLOW}IMPORTANTE: Il certificato generato è self-signed e solo per test.${NC}"
                    echo -e "${YELLOW}Si consiglia di sostituirlo con un certificato valido da una CA attendibile.${NC}"
                else
                    echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
                fi
            else
                echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
                echo -e "${YELLOW}Ripristino del backup...${NC}"
                cp "$backup_dir"/* "$(dirname "$SSL_CONF_FILE")/"
                systemctl restart $APACHE_CMD
            fi
        else
            echo -e "${RED}✗ Errore nella generazione della chiave e CSR${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione dei certificati SSL è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory certificati: $CERT_DIR"
echo "2. Directory chiavi private: $PRIVATE_KEY_DIR"
echo "3. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla configurazione dei certificati:${NC}"
echo -e "${BLUE}- Assicurarsi che i certificati provengano da una CA attendibile${NC}"
echo -e "${BLUE}- Monitorare le date di scadenza dei certificati${NC}"
echo -e "${BLUE}- Mantenere le chiavi private protette e con permessi corretti${NC}"
echo -e "${BLUE}- Verificare regolarmente la validità della configurazione SSL${NC}"

# Mostra informazioni certificato se presente
if [ -f "$NEW_CERT" ]; then
    echo -e "\n${BLUE}Informazioni certificato corrente:${NC}"
    openssl x509 -in "$NEW_CERT" -noout -dates -subject
fi
