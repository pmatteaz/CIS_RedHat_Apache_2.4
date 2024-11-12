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

print_section "CIS Control 7.4 - Verifica Disabilitazione TLSv1.0 e TLSv1.1"

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
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/mods-enabled"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
    if [ ! -f "$SSL_CONF_FILE" ]; then
        SSL_CONF_FILE="/etc/apache2/mods-available/ssl.conf"
    fi
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Protocolli SSL/TLS"

# Funzione per verificare la configurazione dei protocolli SSL/TLS
check_tls_protocols() {
    local has_ssl_protocol=false
    local protocols_secure=false
    
    echo "Controllo configurazione protocolli SSL/TLS..."
    
    # Verifica esistenza file di configurazione SSL
    if [ ! -f "$SSL_CONF_FILE" ]; then
        echo -e "${RED}✗ File di configurazione SSL non trovato: $SSL_CONF_FILE${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    # Cerca direttiva SSLProtocol
    if grep -q "^[[:space:]]*SSLProtocol" "$SSL_CONF_FILE"; then
        has_ssl_protocol=true
        echo -e "${GREEN}✓ Direttiva SSLProtocol trovata${NC}"
        
        # Verifica contenuto SSLProtocol
        local protocol_line=$(grep "^[[:space:]]*SSLProtocol" "$SSL_CONF_FILE")
        echo -e "${BLUE}Configurazione attuale: ${NC}$protocol_line"
        
        # Verifica presenza di protocolli non sicuri
        if echo "$protocol_line" | grep -qE "TLSv1\.0|TLSv1\.1|SSLv2|SSLv3|[^.]TLSv1[^.]"; then
            echo -e "${RED}✗ Trovati protocolli non sicuri nella configurazione${NC}"
            issues_found+=("insecure_protocols")
        elif echo "$protocol_line" | grep -qE " all"; then
            echo -e "${RED}✗ Configurazione 'all' potrebbe includere protocolli non sicuri${NC}"
            issues_found+=("all_protocols")
        else
            if echo "$protocol_line" | grep -qE "TLSv1\.2|TLSv1\.3"; then
                protocols_secure=true
                echo -e "${GREEN}✓ Configurazione protocolli sicura${NC}"
            else
                echo -e "${RED}✗ Nessun protocollo sicuro abilitato${NC}"
                issues_found+=("no_secure_protocols")
            fi
        fi
    else
        echo -e "${RED}✗ Direttiva SSLProtocol non trovata${NC}"
        issues_found+=("no_ssl_protocol")
    fi
    
    # Verifica OpenSSL supporta TLS 1.2 e 1.3
    if command_exists openssl; then
        echo -e "\n${BLUE}Versione OpenSSL:${NC}"
        openssl version
        
        # Verifica supporto TLS 1.2/1.3
        if openssl s_client -help 2>&1 | grep -q "tls1_2"; then
            echo -e "${GREEN}✓ OpenSSL supporta TLS 1.2${NC}"
        else
            echo -e "${RED}✗ OpenSSL potrebbe non supportare TLS 1.2${NC}"
            issues_found+=("openssl_no_tls12")
        fi
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_tls_protocols

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella configurazione dei protocolli SSL/TLS.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/ssl_protocol_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp "$SSL_CONF_FILE" "$backup_dir/"
        
        echo -e "\n${YELLOW}Aggiornamento configurazione protocolli SSL/TLS...${NC}"
        
        # Cerca la linea SSLProtocol esistente
        if grep -q "^[[:space:]]*SSLProtocol" "$SSL_CONF_FILE"; then
            # Sostituisci la linea esistente
            sed -i 's/^[[:space:]]*SSLProtocol.*/SSLProtocol -all +TLSv1.2 +TLSv1.3/' "$SSL_CONF_FILE"
        else
            # Aggiungi la nuova configurazione
            echo "SSLProtocol -all +TLSv1.2 +TLSv1.3" >> "$SSL_CONF_FILE"
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
                if check_tls_protocols; then
                    echo -e "\n${GREEN}✓ Protocolli SSL/TLS configurati correttamente${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nella configurazione finale dei protocolli${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            cp "$backup_dir/$(basename "$SSL_CONF_FILE")" "$SSL_CONF_FILE"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ I protocolli SSL/TLS sono configurati correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza dei protocolli SSL/TLS:${NC}"
echo -e "${BLUE}- TLS 1.0 e 1.1 sono considerati obsoleti e non sicuri${NC}"
echo -e "${BLUE}- Si raccomanda l'uso esclusivo di TLS 1.2 e TLS 1.3${NC}"
echo -e "${BLUE}- La configurazione consigliata è: SSLProtocol -all +TLSv1.2 +TLSv1.3${NC}"
echo -e "${BLUE}- Verificare la compatibilità con i client prima di disabilitare i protocolli${NC}"

# Test connessione SSL se possibile
if command_exists openssl && command_exists curl; then
    print_section "Test Connessione SSL"
    echo -e "${YELLOW}Tentativo di connessione SSL al server locale...${NC}"
    
    # Attendi che Apache sia completamente riavviato
    sleep 2
    
    if curl -k -v https://localhost/ 2>&1 | grep -q "TLSv1.2\|TLSv1.3"; then
        echo -e "${GREEN}✓ Connessione stabilita con protocollo sicuro${NC}"
        echo -e "\n${BLUE}Dettagli protocollo:${NC}"
        curl -k -v https://localhost/ 2>&1 | grep "SSL connection using"
    else
        echo -e "${RED}✗ Impossibile stabilire una connessione SSL sicura${NC}"
    fi
fi
