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

print_section "CIS Control 7.3 - Verifica Protezione Chiave Privata del Server"

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
    PRIVATE_KEY_DIR="/etc/pki/tls/private"
    SSL_CONF_FILE="$SSL_CONF_DIR/ssl.conf"
elif [ -f /etc/debian_version ]; then
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    SSL_CONF_DIR="/etc/apache2/sites-enabled"
    PRIVATE_KEY_DIR="/etc/ssl/private"
    SSL_CONF_FILE="$SSL_CONF_DIR/default-ssl.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Chiave Privata"

# Funzione per verificare la protezione della chiave privata
check_private_key() {
    local key_file=""
    
    echo "Controllo configurazione chiave privata..."
    
    # Cerca il percorso della chiave privata nel file di configurazione SSL
    if [ -f "$SSL_CONF_FILE" ]; then
        key_file=$(grep -E "^[[:space:]]*SSLCertificateKeyFile" "$SSL_CONF_FILE" | awk '{print $2}')
        
        if [ -z "$key_file" ]; then
            echo -e "${RED}✗ Nessuna chiave privata configurata in $SSL_CONF_FILE${NC}"
            issues_found+=("no_key_configured")
            return 1
        fi
    else
        echo -e "${RED}✗ File di configurazione SSL non trovato${NC}"
        issues_found+=("no_ssl_conf")
        return 1
    fi
    
    echo -e "${BLUE}Chiave privata configurata: $key_file${NC}"
    
    # Verifica esistenza della chiave
    if [ ! -f "$key_file" ]; then
        echo -e "${RED}✗ File chiave privata non trovato${NC}"
        issues_found+=("key_file_missing")
        return 1
    fi
    
    # Verifica permessi
    local perms=$(stat -c "%a" "$key_file")
    if [ "$perms" != "400" ]; then
        echo -e "${RED}✗ Permessi chiave privata non corretti (attuali: $perms, richiesti: 400)${NC}"
        issues_found+=("wrong_permissions")
    else
        echo -e "${GREEN}✓ Permessi chiave privata corretti${NC}"
    fi
    
    # Verifica proprietario
    local owner=$(stat -c "%U:%G" "$key_file")
    if [ "$owner" != "root:root" ]; then
        echo -e "${RED}✗ Proprietario chiave privata non corretto (attuale: $owner, richiesto: root:root)${NC}"
        issues_found+=("wrong_owner")
    else
        echo -e "${GREEN}✓ Proprietario chiave privata corretto${NC}"
    fi
    
    # Verifica tipo file e contenuto
    if ! openssl rsa -in "$key_file" -check -noout &>/dev/null; then
        echo -e "${RED}✗ Il file non sembra essere una chiave privata RSA valida${NC}"
        issues_found+=("invalid_key")
    else
        echo -e "${GREEN}✓ Chiave privata RSA valida${NC}"
    fi
    
    # Verifica directory contenente la chiave
    local key_dir=$(dirname "$key_file")
    local dir_perms=$(stat -c "%a" "$key_dir")
    if [ "$dir_perms" != "700" ] && [ "$dir_perms" != "755" ]; then
        echo -e "${RED}✗ Permessi directory della chiave non sicuri (attuali: $dir_perms)${NC}"
        issues_found+=("wrong_dir_permissions")
    else
        echo -e "${GREEN}✓ Permessi directory della chiave corretti${NC}"
    fi
    
    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    fi
    return 1
}

# Esegui la verifica
check_private_key

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nella protezione della chiave privata.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup delle configurazioni
        timestamp=$(date +%Y%m%d_%H%M%S)_7.3
        backup_dir="/root/ssl_key_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        # Trova il percorso della chiave privata
        key_file=$(grep -E "^[[:space:]]*SSLCertificateKeyFile" "$SSL_CONF_FILE" | awk '{print $2}')
        
        if [ -n "$key_file" ]; then
            echo "Creazione backup in $backup_dir..."
            if [ -f "$key_file" ]; then
                cp "$key_file" "$backup_dir/"
            fi
            
            # Correggi permessi e proprietario della chiave
            echo -e "\n${YELLOW}Correzione permessi e proprietario della chiave...${NC}"
            chmod 0400 "$key_file"
            chown root:root "$key_file"
            
            # Correggi permessi directory
            #key_dir=$(dirname "$key_file")
            #chmod 700 "$key_dir"
            #chown root:root "$key_dir"
            
            # Verifica se la chiave è valida
            #if ! openssl rsa -in "$key_file" -check -noout &>/dev/null; then
            #    echo -e "${RED}✗ La chiave esistente non è valida. Potrebbe essere necessario generarne una nuova.${NC}"
            #    echo -e "${YELLOW}Si consiglia di eseguire lo script di remediation del punto 7.2 per generare una nuova chiave.${NC}"
            #fi
            
            # Verifica configurazione Apache
            echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
            if $APACHE_CMD -t; then
                echo -e "${GREEN}✓ Configurazione Apache valida${NC}"
                
                # Riavvia Apache
                echo -e "\n${YELLOW}Riavvio Apache...${NC}"
                systemctl restart $APACHE_CMD
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                else
                    echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
                fi
            else
                echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
                echo -e "${YELLOW}Ripristino del backup...${NC}"
                cp "$backup_dir"/* "$(dirname "$key_file")/"
                systemctl restart $APACHE_CMD
            fi
        else
            echo -e "${RED}✗ Impossibile trovare la configurazione della chiave privata${NC}"
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La chiave privata è protetta correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. Directory chiavi private: $PRIVATE_KEY_DIR"
echo "2. File configurazione SSL: $SSL_CONF_FILE"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Note sulla sicurezza delle chiavi private:${NC}"
echo -e "${BLUE}- Le chiavi private devono avere permessi 0400 (lettura/scrittura solo per root)${NC}"
echo -e "${BLUE}- Il proprietario deve essere root:root${NC}"
echo -e "${BLUE}- La directory contenente le chiavi deve essere protetta${NC}"
echo -e "${BLUE}- Backup sicuri devono essere mantenuti in luogo sicuro${NC}"

# Mostra stato finale se è stata eseguita la remediation
if [ ${#issues_found[@]} -gt 0 ] && [[ "$risposta" =~ ^[Ss]$ ]]; then
    print_section "Stato Finale"
    check_private_key
fi
