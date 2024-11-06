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

print_section "Verifica CIS 5.15: Specifica degli IP di Ascolto"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
    PORTS_CONFIG="$APACHE_CONFIG_DIR/conf/ports.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
    PORTS_CONFIG="$APACHE_CONFIG_DIR/ports.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione Listen"

# Funzione per ottenere gli IP locali
get_local_ips() {
    ip addr | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d/ -f1
}

# Funzione per verificare la configurazione Listen
check_listen_config() {
    local config_file="$1"
    local found_listen=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca direttive Listen
    while read -r line; do
        if [[ "$line" =~ ^Listen ]]; then
            found_listen=true
            # Verifica se Listen specifica un IP
            if [[ "$line" =~ ^Listen[[:space:]]+[0-9]+$ ]]; then
                correct_config=false
                issues+="Trovata direttiva Listen senza IP specificato: $line\n"
            fi
        fi
    done < "$config_file"
    
    if ! $found_listen; then
        echo -e "${RED}✗ Nessuna direttiva Listen trovata${NC}"
        issues_found+=("no_listen_config")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione Listen non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_listen")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione Listen corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
for config_file in "$MAIN_CONFIG" "$PORTS_CONFIG"; do
    if [ -f "$config_file" ]; then
        check_listen_config "$config_file"
    fi
done

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione degli IP di ascolto.${NC}"
    echo -e "${YELLOW}IP locali disponibili:${NC}"
    get_local_ips
    
    echo -e "\n${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.15
        backup_dir="/root/apache_listen_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for config_file in "$MAIN_CONFIG" "$PORTS_CONFIG"; do
            if [ -f "$config_file" ]; then
                cp -p "$config_file" "$backup_dir/"
            fi
        done
        
        # Richiedi all'utente di specificare l'IP da usare
        echo -e "\n${YELLOW}IP disponibili:${NC}"
        get_local_ips
        echo -e "${YELLOW}Inserisci l'IP da utilizzare per l'ascolto:${NC}"
        read -r selected_ip
        
        # Verifica che l'IP sia valido
        if ! [[ "$selected_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo -e "${RED}IP non valido${NC}"
            exit 1
        fi
        
        # Modifica la configurazione Listen
        echo -e "\n${YELLOW}Aggiornamento configurazione Listen...${NC}"
        
        # Determina il file da modificare (preferisci ports.conf se esiste)
        config_to_modify="$MAIN_CONFIG"
        [ -f "$PORTS_CONFIG" ] && config_to_modify="$PORTS_CONFIG"
        
        # Sostituisci o aggiungi le direttive Listen
        if grep -q "^Listen" "$config_to_modify"; then
            # Sostituisci tutte le direttive Listen esistenti
            sed -i "/^Listen/c\Listen $selected_ip:80" "$config_to_modify"
            # Se SSL è abilitato, aggiungi anche la porta 443
            if grep -q "SSL" "$config_to_modify"; then
                echo "Listen $selected_ip:443" >> "$config_to_modify"
            fi
        else
            # Aggiungi nuove direttive Listen
            echo "Listen $selected_ip:80" >> "$config_to_modify"
            if grep -q "SSL" "$config_to_modify"; then
                echo "Listen $selected_ip:443" >> "$config_to_modify"
            fi
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
                
                # Test pratici
                echo -e "\n${YELLOW}Esecuzione test di ascolto...${NC}"
                
                # Verifica che Apache stia ascoltando sull'IP specificato
                if command_exists netstat; then
                    listening_ips=$(netstat -tlpn | grep apache | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                elif command_exists ss; then
                    listening_ips=$(ss -tlpn | grep apache | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
                fi
                
                if echo "$listening_ips" | grep -q "$selected_ip"; then
                    echo -e "${GREEN}✓ Apache sta ascoltando correttamente su $selected_ip${NC}"
                    
                    # Test di connessione
                    if command_exists curl; then
                        response=$(curl -s -o /dev/null -w "%{http_code}" "http://$selected_ip")
                        if [ "$response" = "200" ] || [ "$response" = "403" ]; then
                            echo -e "${GREEN}✓ Server raggiungibile su $selected_ip${NC}"
                        else
                            echo -e "${RED}✗ Server non raggiungibile su $selected_ip (HTTP $response)${NC}"
                        fi
                    fi
                else
                    echo -e "${RED}✗ Apache non sta ascoltando su $selected_ip${NC}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina dal backup
            for config_file in "$MAIN_CONFIG" "$PORTS_CONFIG"; do
                if [ -f "$backup_dir/$(basename "$config_file")" ]; then
                    cp -p "$backup_dir/$(basename "$config_file")" "$config_file"
                fi
            done
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ La configurazione degli IP di ascolto è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione controllati:"
[ -f "$MAIN_CONFIG" ] && echo "   - $MAIN_CONFIG"
[ -f "$PORTS_CONFIG" ] && echo "   - $PORTS_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta configurazione degli IP di ascolto garantisce che:${NC}"
echo -e "${BLUE}- Apache ascolti solo sugli IP specificati${NC}"
echo -e "${BLUE}- Si riduca la superficie di attacco${NC}"
echo -e "${BLUE}- Si migliori il controllo dell'accesso al server${NC}"
echo -e "${BLUE}- Si implementi una configurazione più sicura e specifica${NC}"
