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

print_section "Verifica CIS 5.8: Disabilitazione del Metodo HTTP TRACE"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

print_section "Verifica Configurazione TraceEnable"

# Funzione per verificare la configurazione TraceEnable
check_trace_config() {
    local config_file="$1"
    local found_trace=false
    local correct_config=true
    local issues=""
    
    echo "Controllo configurazione in $config_file..."
    
    # Cerca direttiva TraceEnable
    if grep -q "^[[:space:]]*TraceEnable" "$config_file"; then
        found_trace=true
        
        # Verifica che sia impostato su Off
        if ! grep -q "^[[:space:]]*TraceEnable[[:space:]]*Off" "$config_file"; then
            correct_config=false
            issues+="TraceEnable non è impostato su Off\n"
        fi
    else
        found_trace=false
        issues+="Direttiva TraceEnable non trovata\n"
    fi
    
    if ! $found_trace; then
        echo -e "${RED}✗ Configurazione TraceEnable non trovata${NC}"
        issues_found+=("no_traceenable")
        return 1
    elif ! $correct_config; then
        echo -e "${RED}✗ Configurazione TraceEnable non corretta:${NC}"
        echo -e "${RED}${issues}${NC}"
        issues_found+=("incorrect_config")
        return 1
    else
        echo -e "${GREEN}✓ Configurazione TraceEnable corretta${NC}"
        return 0
    fi
}

# Verifica la configurazione in tutti i file pertinenti
find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -exec grep -l "TraceEnable" {} \; | while read -r config_file; do
    check_trace_config "$config_file"
done

# Se non è stata trovata nessuna configurazione, considera anche questo un problema
if [ ${#issues_found[@]} -eq 0 ] && ! grep -r "TraceEnable" "$APACHE_CONFIG_DIR" >/dev/null 2>&1; then
    issues_found+=("no_traceenable")
fi

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati problemi con la configurazione del metodo TRACE.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup del file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.8
        backup_dir="/root/apache_trace_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
        
        # Aggiungi o modifica la configurazione TraceEnable
        echo -e "\n${YELLOW}Configurazione TraceEnable...${NC}"
        
        if grep -q "^[[:space:]]*TraceEnable" "$MAIN_CONFIG"; then
            # Modifica la configurazione esistente
            sed -i 's/^[[:space:]]*TraceEnable.*/TraceEnable Off/' "$MAIN_CONFIG"
        else
            # Aggiungi la nuova configurazione
            echo -e "\nTraceEnable Off" >> "$MAIN_CONFIG"
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
                
                # Verifica la presenza della configurazione
                if grep -iq "^TraceEnable Off" "$MAIN_CONFIG"; then
                    echo -e "${GREEN}✓ TraceEnable Off configurato correttamente${NC}"
                    
                    # Test pratico del metodo TRACE
                    echo -e "\n${YELLOW}Esecuzione test del metodo TRACE...${NC}"
                    
                    if command_exists curl; then
                        response=$(curl -X TRACE -s -o /dev/null -w "%{http_code}" http://localhost/)
                        if [ "$response" = "403" ] || [ "$response" = "405" ]; then
                            echo -e "${GREEN}✓ Metodo TRACE correttamente bloccato (HTTP $response)${NC}"
                        else
                            echo -e "${RED}✗ Metodo TRACE non bloccato correttamente (HTTP $response)${NC}"
                        fi
                        
                        # Test aggiuntivo con header personalizzato per verificare il cross-site tracing
                        response=$(curl -X TRACE -H "X-Test: test" -s -i http://localhost/ | grep "X-Test")
                        if [ -z "$response" ]; then
                            echo -e "${GREEN}✓ Cross-Site Tracing (XST) non possibile${NC}"
                        else
                            echo -e "${RED}✗ Possibile vulnerabilità Cross-Site Tracing (XST)${NC}"
                        fi
                    else
                        echo -e "${YELLOW}! curl non installato, impossibile eseguire i test pratici${NC}"
                    fi
                    
                else
                    echo -e "${RED}✗ TraceEnable Off non trovato dopo la remediation${NC}"
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
    echo -e "\n${GREEN}✓ La configurazione del metodo TRACE è corretta${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione: $MAIN_CONFIG"
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La disabilitazione del metodo TRACE garantisce che:${NC}"
echo -e "${BLUE}- Si prevenga il Cross-Site Tracing (XST)${NC}"
echo -e "${BLUE}- Si riduca la superficie di attacco${NC}"
echo -e "${BLUE}- Non si espongano informazioni sensibili negli header HTTP${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server web${NC}"
