#!/bin/bash
# Mettere apposto la verifica "/etc/httpd/conf.d/protocol-security.conf"
# disabilita solo in protocol-security.conf da mettere apposto il controllo
# Capire se basta mettere la direttiva sotto protocol-security.conf
# La verifica finale deve verificare la redirezione al momento è sbagliata 

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

print_section "Verifica CIS 5.9: Disabilitazione Vecchie Versioni HTTP"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CMD="httpd"
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CMD="apache2"
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione HTTP Protocol"

# Funzione per verificare la configurazione del protocollo
check_protocol_config() {
    local config_file="$1"
    local found_rewrite=false
    local found_condition=false
    local found_rule=false

    echo "Controllo configurazione in $config_file..."

    # Verifica RewriteEngine
    if grep -q "^[[:space:]]*RewriteEngine[[:space:]]*On" "$config_file"; then
        found_rewrite=true
        echo -e "${GREEN}✓ RewriteEngine On trovato${NC}"
    else
        echo -e "${RED}✗ RewriteEngine On non trovato${NC}"
        issues_found+=("no_rewrite_engine")
    fi

    # Verifica RewriteCond per HTTP/1.1
    if egrep -q '(RewriteCond.*THE_REQUEST.*HTTP/1\\.1)' "$config_file"; then
        found_condition=true
        echo -e "${GREEN}✓ RewriteCond per HTTP/1.1 trovato${NC}"
    else
        echo -e "${RED}✗ RewriteCond per HTTP/1.1 non trovato${NC}"
        issues_found+=("no_rewrite_cond")
    fi

    # Verifica RewriteRule per bloccare le richieste
    if grep -q "RewriteRule.*\\[F\\]" "$config_file"; then
        found_rule=true
        echo -e "${GREEN}✓ RewriteRule per bloccare le richieste trovato${NC}"
    else
        echo -e "${RED}✗ RewriteRule per bloccare le richieste non trovato${NC}"
        issues_found+=("no_rewrite_rule")
    fi

    return $((found_rewrite && found_condition && found_rule))
}

# Verifica la configurazione in tutti i file pertinenti
found_protocol_config=false
while IFS= read -r -d '' config_file; do
    if grep -q "RewriteEngine" "$config_file" || grep -q "THE_REQUEST" "$config_file"; then
        if check_protocol_config "$config_file"; then
            found_protocol_config=true
        fi
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

# Se non è stata trovata nessuna configurazione, aggiungila alla lista dei problemi
if ! $found_protocol_config; then
    issues_found+=("no_protocol_config")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione del protocollo HTTP.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_protocol_backup_$timestamp"
        mkdir -p "$backup_dir"

        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"

        # Verifica se mod_rewrite è abilitato
        echo -e "\n${YELLOW}Verifica modulo rewrite...${NC}"
        if ! $APACHE_CMD -M 2>/dev/null | grep -q "rewrite_module" && \
           ! apache2ctl -M 2>/dev/null | grep -q "rewrite_module"; then
            echo "Abilitazione modulo rewrite..."
            if [ -f /etc/debian_version ]; then
                a2enmod rewrite
            else
                # Per sistemi RedHat, il modulo dovrebbe essere già disponibile
                echo "LoadModule rewrite_module modules/mod_rewrite.so" >> "$MAIN_CONFIG"
            fi
        fi

        # Aggiungi la configurazione per il protocollo HTTP
        echo -e "\n${YELLOW}Aggiunta configurazione protocollo HTTP...${NC}"

        # Crea un file di configurazione dedicato per le regole di rewrite
        PROTOCOL_CONF="$APACHE_CONFIG_DIR/conf.d/protocol-security.conf"
        if [ -f /etc/debian_version ]; then
            PROTOCOL_CONF="$APACHE_CONFIG_DIR/conf-available/protocol-security.conf"
        fi
# Creo il file con la configurazione per la rewrite 
cat <<EOF >"$PROTOCOL_CONF"
REWRITE_CONFIG="RewriteEngine On 
RewriteCond %{THE_REQUEST} !HTTP/1\.1$ 
RewriteRule .* - [F] 

EOF

        # Per Debian/Ubuntu, abilita il file di configurazione
        if [ -f /etc/debian_version ]; then
            a2enconf protocol-security
        fi

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

                # Test pratico delle richieste HTTP
                echo -e "\n${YELLOW}Esecuzione test delle richieste HTTP...${NC}"

                if command_exists curl; then
                    # Test con HTTP/1.0
                    echo -e "Test HTTP/1.0..."
                    response=$(curl -0 -s -o /dev/null -w "%{http_code}" http://localhost/)
                    if [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ HTTP/1.0 correttamente bloccato${NC}"
                    else
                        echo -e "${RED}✗ HTTP/1.0 non bloccato (HTTP $response)${NC}"
                    fi

                    # Test con HTTP/1.1
                    echo -e "Test HTTP/1.1..."
                    response=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/)
                    if [ "$response" = "200" ] || [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ HTTP/1.1 funzionante${NC}"
                    else
                        echo -e "${RED}✗ HTTP/1.1 non funzionante (HTTP $response)${NC}"
                    fi

                    # Test con header personalizzato
                    echo -e "Test richiesta non standard..."
                    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Connection: keep-alive" http://localhost/)
                    if [ "$response" = "200" ] || [ "$response" = "403" ]; then
                        echo -e "${GREEN}✓ Gestione header personalizzati corretta${NC}"
                    else
                        echo -e "${RED}✗ Problemi con header personalizzati (HTTP $response)${NC}"
                    fi

                else
                    echo -e "${YELLOW}! curl non installato, impossibile eseguire i test pratici${NC}"
                fi

            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"

            # Ripristina dal backup
            cp -r "$backup_dir"/* "$APACHE_CONFIG_DIR/"

            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi

    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione del protocollo HTTP è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione principale: $MAIN_CONFIG"
echo "2. File di configurazione protocollo: $PROTOCOL_CONF"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La restrizione delle versioni del protocollo HTTP garantisce che:${NC}"
echo -e "${BLUE}- Solo HTTP/1.1 sia utilizzato${NC}"
echo -e "${BLUE}- Si prevengano potenziali vulnerabilità delle vecchie versioni${NC}"
echo -e "${BLUE}- Si migliori la sicurezza e le prestazioni del server${NC}"
echo -e "${BLUE}- Si mantenga la conformità con gli standard moderni${NC}"
